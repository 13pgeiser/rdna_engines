#!/bin/bash
set -euo pipefail

# FastFlowLM -- NPU (AMD Ryzen AI XDNA2) inference runtime.
#
# Unlike hipfire (HIP/GPU) and llama.cpp (Vulkan/GPU), FLM computes on the NPU
# (/dev/accel), not the GPU. This is a separate process, so it can run alongside
# the others on different ports -- but it is NOT concurrent GPU+NPU of the same
# model: the model runs on the NPU. See the AMD XDNA driver + AMD XRT stack docs.
#
# Flow (mirrors FastFlowLM/Dockerfile + the install flow; OpenFlowLM-Next is an
# open fork of FastFlowLM and factors the same steps differently):
#   1. Build the "builder" image (installs the XRT/Boost build stack, builds the
#      flm binary with the vendored prebuilt NPU engine libs).
#   2. Stage the install tree out of the builder and build the "runtime" image
#      from it (installs the flm binary + engine libs + model list + xclbins).
#   3. Pull the model into the data dir.
#   4. Serve the OpenAI-compatible API with the NPU passed through.

FLM_DIR="FastFlowLM"
IMAGE_BUILDER="fastflowlm:builder"
IMAGE_RUNTIME="fastflowlm:runtime"

# Shared helpers (DEFAULT_PORT, select_model, preflights) -- sourced before the
# PORT default is read so `set -u` does not trip on the unset DEFAULT_PORT.
. "$(dirname "$0")/common.sh"

PORT="${PORT:-${DEFAULT_PORT}}" # same as hipfire / llama.cpp -- run FLM alone on it
NPU_CACHE="./npu-cache"         # NPU runtime cache

# Models are FLM's own Q4NX format, pulled through the flm CLI into $FLM_MODEL_PATH
# (/root/.config/flm inside the runtime image; the catalog resolves the model
# files as $FLM_MODEL_PATH/models/<Name>).
DATA_DIR="/models/fastflowlm"

# --- Model selection menu ----------------------------------------------------
# Each choice is "label|flm-tag"; the tag is the "<family>:<size>" registry key
# the runtime model_list.json knows (e.g. qwen3.6-moe:35b-a3b). Most of the
# supported FastFlowLM models are listed; add entries for more.
CHOICES=(
  # flagship / reasoning
  "qwen3.6-35b-a3b|qwen3.6-moe:35b-a3b"
  "gpt-oss-20b|gpt-oss:20b"
  # gemma
  "gemma4-it-12b|gemma4-it:12b"
  # nemotron (reasoning / speculative)
  "nemotron3.5-bolt-dflash-e4b|nemotron3.5-bolt-dflash:e4b"
)
MENU_TITLE="FastFlowLM model selection (runs on the AMD Ryzen AI XDNA2 NPU):"
MODEL_DEFAULT_INDEX=1 # qwen3.6-moe:35b-a3b
# Preflight: only supported GPUs (FastFlowLM runs on gfx1152 only).
require_gpu gfx1152

select_model "$MODEL_DEFAULT_INDEX" "${1:-}" "${FLM_MODEL:-}"
mkdir -p "$DATA_DIR"

# Context length per model tag: the model's max context (RoPE max, per the
# FastFlowLM docs), not the engine's low default_context_length (1k-32k).
declare -A MODEL_CTX=(
  ["qwen3.6-moe:35b-a3b"]=262144
  ["gpt-oss:20b"]=131072
  ["gemma4-it:12b"]=131072
  ["nemotron3.5-bolt-dflash:e4b"]=32768
)

# Preflight: FLM needs the AMD XDNA NPU. Without it the run fails inside anyway.
require_accel_device

# 0. Clone FastFlowLM if not present (mirrors the hipfire / llama.cpp clones),
#    then initialise git submodules (third_party/tokenizers-cpp is needed to configure).
if [ ! -d "$FLM_DIR" ]; then
  echo "Cloning $FLM_DIR ..."
  git clone --recurse-submodules https://github.com/ROCm/FastFlowLM.git "$FLM_DIR"
fi
if [ -d "$FLM_DIR/.git" ]; then
  (cd "$FLM_DIR" && git submodule update --init --recursive >/dev/null 2>&1)
fi

# 1. Build the "builder" image (installs the XRT/Boost build stack and builds the
#    flm binary). Cached by docker across runs.
docker build --progress=plain --build-arg BASE_IMAGE=ubuntu:26.04 -t "$IMAGE_BUILDER" "$FLM_DIR"

# 2. Build the "runtime" image from the staged install tree. The builder image
#    compiles and installs into /opt/fastflowlm; stage that tree out of a builder
#    container and package it into a runtime image (flm binary + engine libs +
#    model list + xclbins).
#    First run is slow (compiler toolchain); cached afterwards via the marker.
if [ ! -f "$FLM_DIR/.flm-built" ] || [ "${FLM_REBUILD:-0}" = "1" ]; then
  FLM_STAGE="flm_build_stage"
  FLM_BUILD_CTX="$(mktemp -d)"
  cat >"$FLM_BUILD_CTX/Dockerfile" <<'DOCKER'
FROM fastflowlm:builder
ENV FLM_MODEL_PATH=/root/.config/flm \
    NPU_CACHE_HOME=/root/.npu/cache
WORKDIR /opt/fastflowlm
COPY fastflowlm /opt/fastflowlm/
EXPOSE 52625
ENTRYPOINT ["/opt/fastflowlm/bin/flm"]
CMD ["serve", "--host", "0.0.0.0", "--port", "52625"]
DOCKER
  docker rm -f "$FLM_STAGE" >/dev/null 2>&1 || true
  docker run --name "$FLM_STAGE" \
    -e CMAKE_BUILD_PARALLEL_LEVEL="$(nproc)" \
    -e NPU_CACHE_HOME=/root/.npu/cache \
    -v "$PWD/FastFlowLM:/src" \
    "$IMAGE_BUILDER" \
    bash -eu -c 'cmake -S /src/src -B /src/src/build --preset linux-default -DFLM_USE_HRX=OFF && cmake --build /src/src/build -j"$CMAKE_BUILD_PARALLEL_LEVEL" && cmake --install /src/src/build'
  docker cp "$FLM_STAGE:/opt/fastflowlm" "$FLM_BUILD_CTX"
  docker rm -f "$FLM_STAGE"
  docker build -t "$IMAGE_RUNTIME" "$FLM_BUILD_CTX"
  rm -rf "$FLM_BUILD_CTX"
  touch "$FLM_DIR/.flm-built"
else
  echo "FastFlowLM runtime image already built; skipping build (set FLM_REBUILD=1 to force)."
fi

# 3. Install the model into the shared data dir (idempotent; flm pull re-verifies).
docker rm -f flm_pull >/dev/null 2>&1 || true
docker run --rm --name flm_pull \
  -e FLM_MODEL_PATH=/root/.config/flm \
  -e NPU_CACHE_HOME=/root/.npu/cache \
  -v "$DATA_DIR":/root/.config/flm \
  "$IMAGE_RUNTIME" \
  pull "$MODEL_TAG"

# 4. Serve the OpenAI-compatible API on $PORT with the NPU passed through.
#    --ctx-len defaults to the model's max context; override with FLM_CTX_LEN.
CTX_LEN="${FLM_CTX_LEN:-${MODEL_CTX[$MODEL_TAG]:-32768}}"
stop_server flm_server
require_free_port "$PORT"
docker run --rm --name flm_server --init \
  --cap-add=IPC_LOCK \
  --ulimit memlock=-1:-1 \
  --device /dev/accel/accel0 \
  --security-opt seccomp=unconfined \
  -e FLM_MODEL_PATH=/root/.config/flm \
  -e NPU_CACHE_HOME=/root/.npu/cache \
  -v "$DATA_DIR":/root/.config/flm \
  -v "$PWD/$NPU_CACHE":/root/.npu/cache \
  -p "$PORT:$PORT" \
  "$IMAGE_RUNTIME" \
  serve "$MODEL_TAG" --host 0.0.0.0 --port "$PORT" --ctx-len "$CTX_LEN"
echo "OpenAI-compatible API: http://127.0.0.1:${PORT}/v1"
