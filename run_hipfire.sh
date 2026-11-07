#!/bin/bash
set -euo pipefail

HIPFIRE_DIR="hipfire"
DOCKERFILE="$HIPFIRE_DIR/Containerfile"
IMAGE_NAME="local/hipfire:full"
MODEL_NAME="qwen3.6:35b-a3b"
MODELS_DIR="/models/hipfire"

# 1. Clone hipfire if not present
if [ ! -d "$HIPFIRE_DIR" ]; then
  git clone https://github.com/warpfront/hipfire.git
fi

# 2. Build the image locally from the clone
docker build -f "$DOCKERFILE" --target full -t "$IMAGE_NAME" "$HIPFIRE_DIR"

# 3. Pull the model into the mounted models dir (idempotent; skips already-verified files)
mkdir -p "$MODELS_DIR"
docker run --rm --name hipfire-pull \
  -v "$MODELS_DIR":/home/hipfire/.hipfire/models \
  "$IMAGE_NAME" \
  pull --yes "$MODEL_NAME"

# 4. Run the serve (GPU passthrough + loopback API on 9931)
docker rm -f hipfire_server
docker run --rm \
  --network host \
  --name hipfire_server \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add "$(getent group render | cut -d: -f3)" \
  --group-add "$(getent group video | cut -d: -f3)" \
  --security-opt seccomp=unconfined \
  -v "$MODELS_DIR":/home/hipfire/.hipfire/models \
  -p 9931:9931 \
  "$IMAGE_NAME" \
  serve \
  "$MODEL_NAME" \
  0.0.0.0:9931 \
  --max-seq 262144
