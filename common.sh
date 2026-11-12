#!/bin/bash
# common.sh -- shared helpers (model-selection menu, preflight checks) for
# run_*.sh launchers.
#
# Each launcher defines its own CHOICES array ("label|value" pairs) and calls
# select_model to resolve which one. The selection mechanism is identical across
# engines; only the choices (and how a value maps to files/serve command) differ
# per engine, so each script keeps its own list here:
#
#   # in run_<engine>.sh:
#     CHOICES=( "label|value" ... )
#     MODEL_DEFAULT_INDEX=1
#     . "$(dirname "$0")/common.sh"
#     MENU_TITLE="..."            # optional, per-engine header
#     select_model "$MODEL_DEFAULT_INDEX" "${1:-}" "${OFLM_MODEL:-}"
#     # -> MODEL_TAG (the value after the |) is set
#
# Priority for the chosen model: override tag > numeric first arg > interactive
# prompt (when attached to a terminal) > default index.

# Shared helpers also provided here (see their doc comments below): die,
# DEFAULT_PORT, stop_server, require_free_port, and the deploy_llama flow used by
# the llama.cpp launchers.

# select_model <default_index> <arg1> <override_tag>
# Resolves the model and sets global MODEL_TAG to the value (after the |) of the
# CHOICES entry it selects. An empty override means "no explicit tag given".
# A provided value (first argument or interactive selection) must be a valid entry
# number (1..n); an invalid value stops with an error. The default index is used
# when no value is given at all in a non-interactive session, or when the user
# just presses Enter at the interactive prompt.
select_model() {
  local default_index="$1"
  local arg="${2:-}"
  local override="${3:-}"
  local n="${#CHOICES[@]}"

  # An explicit override tag (e.g. OFLM_MODEL=... on the command line) wins outright,
  # but must match one of the current CHOICES entries.
  if [ -n "$override" ]; then
    local entry tag found=""
    for entry in "${CHOICES[@]}"; do
      tag="${entry#*|}"
      if [ "$tag" = "$override" ]; then
        found="$tag"
        break
      fi
    done
    if [ -z "$found" ]; then
      local valid="" e
      for e in "${CHOICES[@]}"; do
        valid+="${e#*|}, "
      done
      valid="${valid%, }"
      die "unknown model override '$override' (valid: $valid)."
    fi
    MODEL_TAG="$override"
    echo "Selected model: $MODEL_TAG"
    return 0
  fi

  local choice
  # A numeric first argument is taken as-is (validated below); without one, prompt
  # if interactive. With no value at all and no terminal, use the default index.
  if [ -n "$arg" ]; then
    choice="$arg"
  elif [ -t 0 ]; then
    echo "${MENU_TITLE:-Model selection}"
    for idx in "${!CHOICES[@]}"; do
      printf "  %d) %s\n" "$((idx + 1))" "${CHOICES[idx]%|*}"
    done
    read -rp "Choose a model [1-$n] (default $default_index): " choice
    choice="${choice:-$default_index}"
  else
    choice="$default_index"
  fi

  # An invalid value (non-numeric or out of range) stops instead of selecting a
  # default.
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then
    die "invalid model selection '$choice' (expected 1-$n)."
  fi

  MODEL_TAG="${CHOICES[$((choice - 1))]#*|}"
  echo "Selected model: $MODEL_TAG"
}

# run_interactive <cmd> [args...]
# docker run -it needs a TTY. In a non-interactive session (CI, ssh without a
# pty) there is no TTY, so allocate a pseudo-TTY with `script` to satisfy it. A
# real interactive terminal already has one and is used as-is.
run_interactive() {
  if [ -t 0 ] && [ -t 1 ]; then
    "$@"
  else
    local extra=("${@:2}")
    script -qec "$1 ${extra[*]}" /dev/null
  fi
}

# die <message>...
# Print each argument as an ERROR line to stderr and exit 1. Shared error exit
# for preflights and validation, so launchers do not repeat the wording.
die() {
  local msg
  for msg in "$@"; do
    echo "ERROR: $msg" >&2
  done
  exit 1
}

# DEFAULT_PORT -- shared by every engine; override with the PORT env var.
DEFAULT_PORT="${DEFAULT_PORT:-9931}"

# stop_server <name>
# Remove a stale server container before a new one is started (idempotent).
stop_server() {
  docker rm -f "$1" >/dev/null 2>&1 || true
}

# require_free_port <port>
# Fail early (instead of deep inside docker at bind time) if the API port is taken.
require_free_port() {
  local port="$1"
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    die "invalid port '$port'."
  fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
    die "port $port is already in use -- set PORT=... to run on another port."
  fi
}

# require_accel_device
# FastFlowLM / OpenFlowLM compute on the AMD XDNA NPU (/dev/accel), not the GPU.
# Without the device the run fails inside the runtime anyway, so bail out early.
require_accel_device() {
  if [ ! -e /dev/accel/accel0 ]; then
    die "no NPU device /dev/accel/accel0." \
      "FastFlowLM and OpenFlowLM run on the AMD Ryzen AI XDNA2 NPU. Requires the amdxdna driver" \
      "+ AMD XRT stack (libxrt-npu2) before this can run."
  fi
}

# require_gpu <arch>...
# Preflight: identify the host GPU from its PCI device id and bail out unless
# it matches one of the given RDNA architectures. Only two GPUs are supported
# by any engine in this repo; any other hardware stops here even if an engine
# might support it:
#   0x1114 -> gfx1152   (FastFlowLM / OpenFlowLM only)
#   0x7551 -> gfx1201   (all GPU engines)
require_gpu() {
  local path="/sys/class/drm/card0/device/device"
  local id arch
  if [ ! -r "$path" ]; then
    die "cannot read $path -- no accessible AMD GPU?"
  fi
  id="$(cat "$path")"
  case "$id" in
  0x1114) arch="gfx1152" ;;
  0x7551) arch="gfx1201" ;;
  *) arch="unknown ($id)" ;;
  esac

  local supported
  for supported in "$@"; do
    if [ "$arch" = "$supported" ]; then
      echo "GPU: $arch"
      return 0
    fi
  done
  die "GPU '$arch' is not supported by this engine (need: $*)."
}

# --- llama.cpp shared helpers ------------------------------------------------
# Used by run_llama_vulkan.sh and run_llama_rocm.sh. Both backends serve the
# same GGUF models, so the model menu itself (CHOICES, MODEL_URLS, default) is
# shared via select_llama_model; each launcher only sets the backend-specific
# globals these read before calling them (see the per-backend section of the
# launcher scripts):
#   LLAMA_CPP_DIR, DOCKERFILE, IMAGE_NAME -> build_llama_server
#   MODEL_DIR                             -> download_model <name>
#   SERVER_NAME, EXTRA_RUN_ARGS, PORT, MODEL_PATH -> run_llama_server

# select_llama_model <backend> [arg1]
# Shared menu for the two llama.cpp launchers: sets the globals select_model /
# download_model expect (backend only customizes MENU_TITLE), then resolves
# MODEL_TAG like select_model does.
select_llama_model() {
  local backend="$1"
  CHOICES=(
    "qwen3.8-27b|Qwen3.8-27B-UD-Q4_K_M.gguf"
    "ornith1.5-35b-a3b|Ornith-1.5-35B-Q4_K_M.gguf"
    "ornith1.5-9b|Ornith-1.5-9B-Q4_K_M.gguf"
    "gemma4-12b-it|gemma-4-12b-it-Q4_K_M.gguf"
    "gemma4-26b-a4b|gemma-4-26B-A4B-it-UD-Q4_K_M.gguf"
    "gpt-oss-20b|gpt-oss-20b-Q4_K_M.gguf"
    "qwen3-coder-30b|Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
    "qwen3.6-35b-a3b-ud|Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
    "flint|flint-UD-Q4_K_XL.gguf"
    "flint-q8|flint-Q8_0.gguf"
  )
  MENU_TITLE="llama.cpp model selection (runs on the AMD GPU via $backend):"
  # Global (not local): download_model runs after this function returns.
  declare -gA MODEL_URLS=(
    ["Ornith-1.5-35B-Q4_K_M.gguf"]="https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-GGUF/resolve/main/Ornith-1.5-35B-Q4_K_M.gguf?download=true"
    ["Qwen3.8-27B-UD-Q4_K_M.gguf"]="https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-Q4_K_M.gguf?download=true"
    ["Ornith-1.5-9B-Q4_K_M.gguf"]="https://huggingface.co/ornith-ai/Ornith-1.5-9B-GGUF/resolve/main/Ornith-1.5-9B-Q4_K_M.gguf?download=true"
    ["gemma-4-12b-it-Q4_K_M.gguf"]="https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q4_K_M.gguf?download=true"
    ["gemma-4-26B-A4B-it-UD-Q4_K_M.gguf"]="https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf?download=true"
    ["gpt-oss-20b-Q4_K_M.gguf"]="https://huggingface.co/unsloth/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-Q4_K_M.gguf?download=true"
    ["Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"]="https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf?download=true"
    ["Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"]="https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf?download=true"
    ["flint-UD-Q4_K_XL.gguf"]="https://huggingface.co/unsloth/flint-GGUF/resolve/main/flint-UD-Q4_K_XL.gguf?download=true"
    ["flint-Q8_0.gguf"]="https://huggingface.co/unsloth/flint-GGUF/resolve/main/flint-Q8_0.gguf?download=true"
  )
  select_model 1 "${2:-}" "${LLAMA_MODEL:-}" # 1 = qwen3.8-27b
}

# clone_llama_cpp <dir>
# Clone llama.cpp if the directory is not present.
clone_llama_cpp() {
  local dir="$1"
  if [ ! -d "$dir" ]; then
    echo "Cloning $dir ..."
    git clone https://github.com/ggml-org/llama.cpp.git "$dir"
  fi
}

# build_llama_server
# Build the backend server image (target server) from the local llama.cpp clone.
build_llama_server() {
  docker build --progress=plain -f "$DOCKERFILE" --target server -t "$IMAGE_NAME" "$LLAMA_CPP_DIR"
}

# download_model <name>
# Download a GGUF model via MODEL_URLS if it is not already present.
download_model() {
  local name="$1"
  local path="$MODEL_DIR/$name"
  if [ ! -f "$path" ]; then
    mkdir -p "$(dirname "$path")"
    if [ -z "${MODEL_URLS[$name]:-}" ]; then
      die "no download URL for '$name' in MODEL_URLS."
    fi
    echo "Downloading $name ..."
    wget -O "$path" "${MODEL_URLS[$name]}"
  fi
}

# run_llama_server
# Run the backend server with the GPU passed through. EXTRA_RUN_ARGS holds the
# per-backend device flags (e.g. --device /dev/dri).
# --parallel: single user, 1 slot; llama.cpp's default (auto) is 4 slots with a
# unified KV pool, splitting the card across sequences that never exist here.
run_llama_server() {
  stop_server "$SERVER_NAME"
  require_free_port "${PORT:-${DEFAULT_PORT}}"
  local port="${PORT:-${DEFAULT_PORT}}"
  docker run --rm --name "$SERVER_NAME" \
    "${EXTRA_RUN_ARGS[@]}" \
    -v /models:/models \
    -p "${port}:${port}" \
    "$IMAGE_NAME" \
    --model "$MODEL_PATH" \
    --host 0.0.0.0 \
    --port "$port" \
    --parallel "${LLAMA_PARALLEL:-1}" \
    --reasoning-effort "${LLAMA_REASONING_EFFORT:-medium}" \
    -fa "${LLAMA_FA:-on}" -ctk "${LLAMA_CTK:-q8_0}" -ctv "${LLAMA_CTV:-q8_0}" \
    --batch-size "${LLAMA_BATCH_SIZE:-2048}" --ubatch-size "${LLAMA_UBATCH_SIZE:-512}"
  echo "OpenAI-compatible API: http://127.0.0.1:${port}/v1"
}

# deploy_llama
# Shared clone -> build -> download -> serve flow for the two llama.cpp launchers
# (see the per-backend section of the launcher scripts). The caller resolves the
# model first and has set the backend-specific globals these helpers read:
#   LLAMA_CPP_DIR, DOCKERFILE, IMAGE_NAME -> build_llama_server
#   MODEL_DIR                             -> download_model <name>
#   SERVER_NAME, EXTRA_RUN_ARGS, PORT, MODEL_PATH -> run_llama_server
deploy_llama() {
  # 1. Clone llama.cpp if not present
  clone_llama_cpp "$LLAMA_CPP_DIR"
  # 2. Build the backend server image from the local llama.cpp clone
  build_llama_server
  # 3. Download the model if it is not present yet (fetch on demand via MODEL_URLS)
  download_model "$MODEL_NAME"
  # 4. Run the backend server (PORT default 9931, shared with hipfire/OFLM -- run alone on it)
  run_llama_server
}
