#!/bin/bash
set -euo pipefail

# OpenFlowLM -- NPU (AMD Ryzen AI XDNA2) inference runtime.
#
# Unlike hipfire (HIP/GPU) and llama.cpp (Vulkan/GPU), OFLM computes on the NPU
# (/dev/accel), not the GPU. This is a separate process, so it can run alongside
# the others on different ports -- but it is NOT concurrent GPU+NPU of the same
# model: the model runs on the NPU. See docs/linux-getting-started.md.
#
# Flow (mirrors OpenFlowLM-Next/build_in_docker.sh + Dockerfile + compose.yaml):
#   1. Build the "builder" image (installs XRT/Boost, builds the mlir-aie
#      toolchain, exports the NPU kernels) and package a .deb.
#   2. Build the "runtime" image from that .deb (installs the oflm binary +
#      libxrt-npu2 runtime).
#   3. Pull the model into the data dir.
#   4. Serve the OpenAI-compatible API with the NPU passed through.
#
# The builder image (step 1) compiles the mlir-aie/Peano toolchain and all NPU
# kernels; this is the expensive step (tens of minutes, first run only, cached
# by docker). The runtime image is quick.

OFLM_DIR="OpenFlowLM-Next"
IMAGE_BUILD="openflowlm-build:ubuntu26"
IMAGE_RUNTIME="openflowlm:runtime"

OFLM_HF_OWNER="${OFLM_HF_OWNER:-Atomic-Germ}"        # both Atomic-Germ/ and FastFlowLM/ host the model

PORT="${PORT:-9931}"                                  # same as hipfire / llama.cpp -- run OFLM alone on it
DEB_BUILT="$OFLM_DIR/.oflm-deb-built"   # outside build/ so clean-build keeps it

# Models are OFLM's own Q4NX format (not GGUF), so they live in /models/openflowlm
# rather than /models/gguf. This is mounted at the runtime image's OFLM_MODEL_PATH
# (/root/.config/oflm), where the registry overlay + xclbin symlinks also live.
DATA_DIR="/models/openflowlm"
NPU_CACHE="./npu-cache"    # NPU runtime cache

# --- Model selection menu ----------------------------------------------------
# Each choice is "label|oflm-tag"; the tag is the registry key (family:size) the
# runtime model_list.json knows. ornith is shape-identical to qwen3.6-35b-a3b, so
# it installs at runtime with `oflm add`, which links the matching family kernels
# instead of shipping its own xclbins (see oflm-add README).
OFLM_CHOICES=(
  "qwen3.6-35b-a3b|qwen3.6-moe:35b-a3b"
  "ornith1.5-35b-a3b|ornith-1.5:35b-a3b"
  "phi4-mini-it:4b|phi4-mini-it:4b"
  "nanbeige4.1:3b|nanbeige4.1:3b"
  "gemma4-it:e4b|gemma4-it:e4b"
  "gemma4-it:12b|gemma4-it:12b"
  "gpt-oss:20b|gpt-oss:20b"
)
MODEL_DEFAULT_INDEX=1   # qwen3.6-35b-a3b

# Resolve the selection: explicit OFLM_MODEL wins; else a numeric first arg
# (./run_openflowlm.sh 2); else prompt when attached to a terminal; else default.
# Each choice is "label|oflm-tag"; the tag (after the |) is the registry key.
choice="${1:-}"
if [ -n "${OFLM_MODEL:-}" ]; then
  MODEL_TAG="$OFLM_MODEL"
elif [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#OFLM_CHOICES[@]}" ]; then
  if [ -t 0 ]; then
    echo "OpenFlowLM model selection (runs on the AMD Ryzen AI XDNA2 NPU):"
    for idx in "${!OFLM_CHOICES[@]}"; do
      printf "  %d) %s\n" "$((idx+1))" "${OFLM_CHOICES[idx]%|*}"
    done
    read -rp "Choose a model [1-${#OFLM_CHOICES[@]}] (default $MODEL_DEFAULT_INDEX): " choice
    choice="${choice:-$MODEL_DEFAULT_INDEX}"
  else
    choice="$MODEL_DEFAULT_INDEX"
  fi
  # Reject anything still invalid (bad arg or prompt input); fall back to default.
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#OFLM_CHOICES[@]}" ]; then
    echo "Invalid choice '$choice'; using default qwen3.6-35b-a3b" >&2
    choice="$MODEL_DEFAULT_INDEX"
  fi
fi
MODEL_TAG="${OFLM_CHOICES[$((choice-1))]#*|}"
echo "Selected model: $MODEL_TAG"
mkdir -p "$DATA_DIR"

# build_in_docker.sh runs `docker run -it`, which needs a TTY. In a non-interactive
# session (CI, ssh without a pty) there is no TTY, so allocate a pseudo-TTY with
# `script` to satisfy it. A real interactive terminal already has one and is used as-is.
run_interactive() {
  if [ -t 0 ] && [ -t 1 ]; then
    "$@"
  else
    script -qec "$1 ${@:2}" /dev/null
  fi
}

# Preflight: OFLM needs the AMD XDNA NPU. Without it the run fails inside anyway.
if [ ! -e /dev/accel/accel0 ]; then
  echo "ERROR: no NPU device /dev/accel/accel0." >&2
  echo "OpenFlowLM runs on the Ryzen AI XDNA2 NPU. See docs/linux-getting-started.md for" >&2
  echo "the amdxdna driver + AMD XRT stack (libxrt-npu2) required before this can run." >&2
  exit 1
fi

# 0. Clone OpenFlowLM-Next if not present (mirrors the hipfire / llama.cpp clones),
#    then initialise git submodules (third_party/tokenizers-cpp is needed to configure).
if [ ! -d "$OFLM_DIR" ]; then
  echo "Cloning $OFLM_DIR ..."
  git clone https://github.com/Atomic-Germ/OpenFlowLM-Next.git "$OFLM_DIR"
fi
if [ -d "$OFLM_DIR/.git" ]; then
  ( cd "$OFLM_DIR" && git submodule update --init --recursive >/dev/null 2>&1 || true )
fi

# 1. Build the builder image, export the kernels, and package the .deb.
#    Requires a clean build: a stale host build/CMakeCache.txt (left by a run
#    outside docker) points at the wrong source path and cmake aborts, so wipe
#    build/ first. (Requires the NPU at build time for the BERT embedding kernel
#    sets; the language-model kernels such as qwen36 are compile-only.)
#    build_in_docker.sh uses `docker run -it` (needs a TTY), so run this script
#    in the foreground; backgrounding it fails on that flag.
if [ ! -f "$DEB_BUILT" ] || [ "${OFLM_REBUILD:-0}" = "1" ]; then
  rm -rf "$OFLM_DIR/build"
  echo "Building builder image + packaging .deb (first run is slow: mlir-aie toolchain)..."
  ( cd "$OFLM_DIR" && NPU_CACHE_HOME="$PWD/$NPU_CACHE" run_interactive ./build_in_docker.sh linux-package-deb )
  : > "$DEB_BUILT"
else
  echo "Builder image already packaged; skipping build (set OFLM_REBUILD=1 to force)."
fi

# 2. Build the runtime image from the packaged .deb.
docker build --target runtime -f "$OFLM_DIR/Dockerfile" -t "$IMAGE_RUNTIME" "$OFLM_DIR"

# 3. Install the model into the shared data dir (idempotent).
#    Official models download via the registry `pull`; ornith is shape-identical
#    to qwen3.6-35b-a3b, so `oflm add` links the matching family's kernels rather
#    than rebuilding them (see oflm-add README). `oflm add` exits non-zero when
#    the model is already installed, so only run it if the tag is not registered.
docker rm -f oflm_pull 2>/dev/null || true
if [[ "$MODEL_TAG" == ornith-* ]]; then
  if docker run --rm -v "$DATA_DIR":/root/.config/oflm openflowlm:runtime \
       list --filter installed 2>/dev/null | grep -qwF "$MODEL_TAG"; then
    echo "Model already installed: $MODEL_TAG"
  else
    docker run --rm --name oflm_pull \
      -e OFLM_HF_OWNER="$OFLM_HF_OWNER" \
      -v "$DATA_DIR":/root/.config/oflm \
      "$IMAGE_RUNTIME" \
      add "Atomic-Germ/Ornith-1.5-35B-A3B-NPU2" \
          --family qwen3.6-moe \
          --tag "$MODEL_TAG" \
          --xclbin-from Qwen3.6-35B-A3B-NPU2
  fi
else
  docker run --rm --name oflm_pull \
    -e OFLM_HF_OWNER="$OFLM_HF_OWNER" \
    -v "$DATA_DIR":/root/.config/oflm \
    "$IMAGE_RUNTIME" \
    pull "$MODEL_TAG"
fi

# 4. Serve the OpenAI-compatible API on $PORT with the NPU passed through.
docker rm -f oflm_server 2>/dev/null || true
docker run --rm --name oflm_server --init \
  --cap-add=IPC_LOCK \
  --ulimit memlock=-1:-1 \
  --device /dev/accel/accel0 \
  --security-opt seccomp=unconfined \
  -e OFLM_HF_OWNER="$OFLM_HF_OWNER" \
   -v "$DATA_DIR":/root/.config/oflm \
   -v "$PWD/$NPU_CACHE":/root/.npu/cache \
  -p "$PORT:$PORT" \
  "$IMAGE_RUNTIME" \
  serve "$MODEL_TAG" --host 0.0.0.0 --port "$PORT"
