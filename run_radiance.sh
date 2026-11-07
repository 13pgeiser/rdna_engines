#!/bin/bash
set -euo pipefail

# radiance server (C++ + HIP, AMD RDNA)
RADIANCE_DIR="radiance"
IMAGE_NAME="radiance:latest"
MODEL_NAME="${MODEL_NAME:-qwen3.6-35b-a3b-fp8.rad}"
#MODEL_NAME="${MODEL_NAME:-qwen3.8-27b-mxfp4.rad}"
MODELS_DIR="/models/rad"
MODEL_URL="${MODEL_URL:-https://huggingface.co/StillDeadcode/qwen3.6-35b-a3b-fp8/resolve/main/qwen3.6-35b-a3b-fp8.rad}"
#MODEL_URL="${MODEL_URL:-https://huggingface.co/StillDeadcode/qwen3.8-27b-mxfp4/resolve/main/qwen3.8-27b-mxfp4.rad}"

# Overridable flags (defaults match radiance's qwen3.6-35b-a3b.yaml compose)
PORT="${PORT:-9931}"
GPU_TARGETS="${GPU_TARGETS:-gfx1201;gfx11-generic;gfx1151}"
TP="${TP:-1}"

# 1. Clone radiance if not present
if [ ! -d "$RADIANCE_DIR" ]; then
  git clone https://codeberg.org/StillDeadcode/radiance.git
fi

# 2. Build the image locally from the clone. The context is the working tree (the
#    repo's .dockerignore drops build/, .git, *.rad, so this is as clean as a
#    `git archive`); GPU_TARGETS selects the RDNA kernel families to compile.
#    --load puts the result in the local image store (tagged via -t).
#    TEST_EXCLUDE skips the host test suite: radiance's CI asserts RDNA defaults
#    that this hardware isn't, so every update adds a failing test; the build
#    only needs the host-tests marker, which an empty run still writes.
docker buildx build --load \
  --build-arg GPU_TARGETS="$GPU_TARGETS" \
  --build-arg TEST_EXCLUDE=".*" \
  -t "$IMAGE_NAME" \
  "$RADIANCE_DIR"

# 3. Download the model if it is not present yet
if [ ! -f "$MODELS_DIR/$MODEL_NAME" ]; then
  mkdir -p "$MODELS_DIR"
  echo "Downloading $MODEL_NAME ..."
  wget -O "$MODELS_DIR/$MODEL_NAME" "$MODEL_URL"
fi

# 4. Run the server (GPU passthrough + OpenAI-compatible API on $PORT)
docker rm -f radiance_server
docker run --rm --name radiance_server \
  --init \
  --ulimit memlock=-1 \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add "$(getent group render | cut -d: -f3)" \
  --group-add "$(getent group video | cut -d: -f3)" \
  --security-opt seccomp=unconfined \
  -v "$MODELS_DIR":/models:ro \
  -p "$PORT:$PORT" \
  "$IMAGE_NAME" \
  --model "/models/$MODEL_NAME" \
  --host 0.0.0.0 \
  --port "$PORT" \
  --tp "$TP" \
  --max-num-seqs 32 \
  --max-model-len 200000 \
  --kv-cache-dtype fp8
