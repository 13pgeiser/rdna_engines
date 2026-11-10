#!/bin/bash
set -euo pipefail

# FastFlowLM -- NPU (AMD Ryzen AI XDNA2) inference runtime.
#
# Unlike hipfire (HIP/GPU) and llama.cpp (Vulkan/GPU), FLM computes on the NPU
# (/dev/accel), not the GPU. This is a separate process, so it can run alongside
# the others on different ports -- but it is NOT concurrent GPU+NPU of the same
# model: the model runs on the NPU. See docs/linux-getting-started.md.
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

PORT="${PORT:-9931}"    # same as hipfire / llama.cpp -- run FLM alone on it
NPU_CACHE="./npu-cache" # NPU runtime cache

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
  "qwen3.8-27b|qwen3.8-mtp:27b"
  "gpt-oss-20b|gpt-oss:20b"
  "deepseek-r1-8b|deepseek-r1:8b"
  "deepseek-r1-0528-8b|deepseek-r1-0528:8b"
  "lfm3-1.7b|lfm3:1.7b"
  # gemma
  "gemma4-it-12b|gemma4-it:12b"
  "gemma4-it-8b|gemma4-it:e4b"
  "gemma4-it-5b|gemma4-it:e2b"
  "gemma4e-flash-8b|gemma4e-flash:e4b"
  "gemma3-4b|gemma3:4b"
  "gemma3-1b|gemma3:1b"
  "medgemma-4b|medgemma:4b"
  # qwen
  "qwen3.5-9b|qwen3.5:9b"
  "qwen3.5-4b|qwen3.5:4b"
  "qwen3.5-2b|qwen3.5:2b"
  "qwen3.5-0.8b|qwen3.5:0.8b"
  "qwen3-8b|qwen3:8b"
  "qwen3-4b|qwen3:4b"
  "qwen3-1.7b|qwen3:1.7b"
  "qwen3-0.6b|qwen3:0.6b"
  "qwen3-thinking-4b|qwen3-tk:4b"
  "qwen3-instruct-4b|qwen3-it:4b"
  "qwen2.5-3b|qwen2.5-it:3b"
  # llama / phi / hunyuan / lfm2
  "llama-3.2-3b|llama3.2:3b"
  "llama-3.2-1b|llama3.2:1b"
  "llama-3.1-8b|llama3.1:8b"
  "phi4-mini-4b|phi4-mini-it:4b"
  "hy-mt2-1.8b|hy-mt2-flash:1.8b"
  "hy-memory-30b-a3b|hy-memory:30b-a3b"
  "nanbeige4.1-3b|nanbeige4.1:3b"
  "lfm2-2.6b|lfm2:2.6b"
  "lfm2-1.2b|lfm2:1.2b"
  "lfm2.5-it-1.2b|lfm2.5-it:1.2b"
  # vision
  "qwen3vl-4b|qwen3vl-it:4b"
  "qwen3vl-flash-4b|qwen3vl-flash:4b"
  # asr / embed
  "whisper-v3-turbo|whisper-v3:turbo"
  "embed-gemma-300m|embed-gemma:300m"
)
MENU_TITLE="FastFlowLM model selection (runs on the AMD Ryzen AI XDNA2 NPU):"
MODEL_DEFAULT_INDEX=1 # qwen3.6-moe:35b-a3b
# Shared interactive menu mechanism (see common.sh); resolves MODEL_TAG from CHOICES.
. "$(dirname "$0")/common.sh"

# Preflight: only supported GPUs (FastFlowLM runs on gfx1152 only).
require_gpu gfx1152

select_model "$MODEL_DEFAULT_INDEX" "${1:-}" "${FLM_MODEL:-}"
mkdir -p "$DATA_DIR"

# Context length per model tag: the model's max context (RoPE max, per the
# FastFlowLM docs), not the engine's low default_context_length (1k-32k). The
# "Flash" variants and hy-mt2-flash have a fixed 1k limit (overrides ignored),
# hy-memory is fixed at 16k; whisper/embed have no chat context, so they keep
# the engine default.
declare -A MODEL_CTX=(
  ["qwen3.6-moe:35b-a3b"]=262144
  ["qwen3.8-mtp:27b"]=262144
  ["gpt-oss:20b"]=131072
  ["deepseek-r1:8b"]=131072
  ["deepseek-r1-0528:8b"]=65536
  ["lfm3:1.7b"]=32768
  ["gemma4-it:12b"]=131072
  ["gemma4-it:e4b"]=131072
  ["gemma4-it:e2b"]=131072
  ["gemma4e-flash:e4b"]=1024
  ["gemma3:4b"]=131072
  ["gemma3:1b"]=32768
  ["medgemma:4b"]=131072
  ["qwen3.5:9b"]=262144
  ["qwen3.5:4b"]=262144
  ["qwen3.5:2b"]=262144
  ["qwen3.5:0.8b"]=262144
  ["qwen3:8b"]=32768
  ["qwen3:4b"]=32768
  ["qwen3:1.7b"]=32768
  ["qwen3:0.6b"]=32768
  ["qwen3-tk:4b"]=262144
  ["qwen3-it:4b"]=262144
  ["qwen2.5-it:3b"]=32768
  ["llama3.2:3b"]=131072
  ["llama3.2:1b"]=131072
  ["llama3.1:8b"]=131072
  ["phi4-mini-it:4b"]=131072
  ["hy-mt2-flash:1.8b"]=1024
  ["hy-memory:30b-a3b"]=16384
  ["nanbeige4.1:3b"]=262144
  ["lfm2:2.6b"]=32768
  ["lfm2:1.2b"]=32768
  ["lfm2.5-it:1.2b"]=32768
  ["qwen3vl-it:4b"]=262144
  ["qwen3vl-flash:4b"]=1024
  ["whisper-v3:turbo"]=448
  ["embed-gemma:300m"]=2048
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
  (cd "$FLM_DIR" && git submodule update --init --recursive >/dev/null 2>&1 || true)
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
docker rm -f flm_server >/dev/null 2>&1 || true
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
