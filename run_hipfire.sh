#!/bin/bash
set -euo pipefail

HIPFIRE_DIR="hipfire"

# --- Model selection menu ----------------------------------------------------
# Same mechanism as run_openflowlm.sh / run_llama_*.sh (see common.sh); each
# engine keeps its own CHOICES. The value after the | is the hipfire model tag
# passed to `hipfire serve`.
CHOICES=(
  "qwen3.8:27b-mq4-xts|qwen3.8:27b-mq4-xts"
  "qwen3.6:35b-a3b|qwen3.6:35b-a3b"
  "ornith-1.5:35b-a3b|ornith-1.5:35b-a3b"
)
MENU_TITLE="hipfire model selection (runs on the AMD Radeon GPU via ROCm):"
MODEL_DEFAULT_INDEX=1 # qwen3.6:35b-a3b
# Shared interactive menu mechanism (see common.sh); resolves MODEL_TAG from CHOICES.
. "$(dirname "$0")/common.sh"

# Preflight: only supported GPUs (hipfire runs on both).
require_gpu gfx1152 gfx1201

# Per-engine inputs.
DOCKERFILE="$HIPFIRE_DIR/Containerfile"
IMAGE_NAME="local/hipfire:full"
MODELS_DIR="/models/hipfire"
SERVER_NAME="hipfire_server"
PORT="${PORT:-9931}" # same as llama.cpp -- run alone on it

select_model "$MODEL_DEFAULT_INDEX" "${1:-}" "${HIPFIRE_MODEL:-}"
MODEL_NAME="$MODEL_TAG"

# 1. Clone hipfire if not present
if [ ! -d "$HIPFIRE_DIR" ]; then
  echo "Cloning $HIPFIRE_DIR ..."
  git clone https://github.com/warpfront/hipfire.git "$HIPFIRE_DIR"
fi

# 2. Build the image locally from the clone (full carries hipcc; gfx1152 is
#    JIT-only and compiles its kernels at serve time, so the runtime target
#    cannot be used here).
docker build --progress=plain -f "$DOCKERFILE" --target full -t "$IMAGE_NAME" "$HIPFIRE_DIR"

# 3. Pull the model into the mounted models dir (idempotent; skips already-verified files)
mkdir -p "$MODELS_DIR"
docker run --rm --name hipfire-pull \
  -v "$MODELS_DIR":/home/hipfire/.hipfire/models \
  "$IMAGE_NAME" \
  pull --yes "$MODEL_NAME"

# 4. Run the serve (GPU passthrough + loopback API on $PORT).
#    Kernels compile once into these dirs on the first run (slow on gfx1152);
#    the named volumes persist the compiled kernels so later starts reuse them.
#    Named (not bind) volumes so the container's uid 1000 owns the writes even
#    though this host user is not 1000. Wipe with: docker volume rm ...-compiled ...-runtime
docker volume create --name "${SERVER_NAME}-kcache-compiled" >/dev/null 2>&1 || true
docker volume create --name "${SERVER_NAME}-kcache-runtime" >/dev/null 2>&1 || true
docker rm -f "$SERVER_NAME" >/dev/null 2>&1 || true
docker run --rm --name "$SERVER_NAME" \
  --network host \
  --device /dev/kfd \
  --device /dev/dri \
  --group-add "$(getent group render | cut -d: -f3)" \
  --group-add "$(getent group video | cut -d: -f3)" \
  --security-opt seccomp=unconfined \
  -v "$MODELS_DIR":/home/hipfire/.hipfire/models \
  -v "${SERVER_NAME}-kcache-compiled":/home/hipfire/.hipfire/bin/kernels/compiled \
  -v "${SERVER_NAME}-kcache-runtime":/var/cache/hipfire \
  "$IMAGE_NAME" \
  serve \
  "$MODEL_NAME" \
  "0.0.0.0:$PORT" \
  --max-seq 262144 \
  --idle-timeout 0
