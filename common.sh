#!/bin/bash
# common.sh -- shared model-selection menu for run_*.sh launchers.
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

# select_model <default_index> <arg1> <override_tag>
# Resolves the model and sets global MODEL_TAG to the value (after the |) of the
# CHOICES entry it selects. An empty override means "no explicit tag given".
select_model() {
  local default_index="$1"
  local arg="${2:-}"
  local override="${3:-}"
  local n="${#CHOICES[@]}"

  # An explicit override tag (e.g. OFLM_MODEL=... on the command line) wins outright.
  if [ -n "$override" ]; then
    MODEL_TAG="$override"
    echo "Selected model: $MODEL_TAG"
    return 0
  fi

  local choice
  # Prefer a valid numeric first argument; otherwise prompt (if interactive).
  if [[ "$arg" =~ ^[0-9]+$ ]] && [ "$arg" -ge 1 ] && [ "$arg" -le "$n" ]; then
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

  # Reject anything still invalid; fall back to the default index.
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then
    echo "Invalid choice '$choice'; using default" >&2
    choice="$default_index"
  fi

  MODEL_TAG="${CHOICES[$((choice - 1))]#*|}"
  echo "Selected model: $MODEL_TAG"
}

# --- llama.cpp shared helpers ------------------------------------------------
# Used by run_llama_vulkan.sh and run_llama_rocm.sh. Each launcher sets the
# globals these read before calling them (see the per-backend section of the
# launcher scripts):
#   LLAMA_CPP_DIR, DOCKERFILE, IMAGE_NAME -> build_llama_server
#   MODEL_DIR, MODEL_URLS                 -> download_model <name>
#   SERVER_NAME, EXTRA_RUN_ARGS, PORT, MODEL_PATH -> run_llama_server

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
  docker build -f "$DOCKERFILE" --target server -t "$IMAGE_NAME" "$LLAMA_CPP_DIR"
}

# download_model <name>
# Download a GGUF model via MODEL_URLS if it is not already present.
download_model() {
  local name="$1"
  local path="$MODEL_DIR/$name"
  if [ ! -f "$path" ]; then
    mkdir -p "$(dirname "$path")"
    if [ -z "${MODEL_URLS[$name]:-}" ]; then
      echo "ERROR: no download URL for '$name' in MODEL_URLS." >&2
      exit 1
    fi
    echo "Downloading $name ..."
    wget -O "$path" "${MODEL_URLS[$name]}"
  fi
}

# run_llama_server
# Run the backend server with the GPU passed through. EXTRA_RUN_ARGS holds the
# per-backend device flags (e.g. --device /dev/dri).
run_llama_server() {
  docker rm -f "$SERVER_NAME" 2>/dev/null || true
  docker run --rm --name "$SERVER_NAME" \
    "${EXTRA_RUN_ARGS[@]}" \
    -v /models:/models \
    -p "$PORT:$PORT" \
    "$IMAGE_NAME" \
    --model "$MODEL_PATH" \
    --host 0.0.0.0 \
    --port "$PORT" \
    --reasoning-effort medium
}
