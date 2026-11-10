#!/bin/bash
set -euo pipefail

# radiance server (C++ + HIP, AMD RDNA)
RADIANCE_DIR="radiance"
IMAGE_NAME="radiance:latest"
MODELS_DIR="/models/rad"

# --- Model selection menu ----------------------------------------------------
# Same mechanism as run_openflowlm.sh / run_llama_*.sh (see common.sh); each
# engine keeps its own CHOICES. Here the value is the .rad filename; MODEL_URLS
# maps that name to the HuggingFace download so it can be fetched on demand.
# Ornith and Gemma-4-12B are hosted by the "keptn" org; the rest by StillDeadcode.
CHOICES=(
  "qwen3.8-27b|qwen3.8-27b-mxfp4.rad"
  "qwen3.6-35b|qwen3.6-35b-a3b-fp8.rad"
  "ornith-1.5-35b|ornith-1.5-35b-a3b-fp8.rad"
  "minicpm5-2b|minicpm5-2b-fp8.rad"
  "gemma4-12b|gemma4-12b-i8g.rad"
)
MENU_TITLE="radiance model selection (runs on the AMD Radeon GPU via HIP):"
MODEL_DEFAULT_INDEX=2 # qwen3.6-35b-a3b-fp8
# label -> download URL, keyed by .rad filename; add entries for extra models.
declare -A MODEL_URLS=(
  ["qwen3.8-27b-mxfp4.rad"]="https://huggingface.co/StillDeadcode/qwen3.8-27b-mxfp4/resolve/main/qwen3.8-27b-mxfp4.rad"
  ["qwen3.6-35b-a3b-fp8.rad"]="https://huggingface.co/StillDeadcode/qwen3.6-35b-a3b-fp8/resolve/main/qwen3.6-35b-a3b-fp8.rad"
  ["ornith-1.5-35b-a3b-fp8.rad"]="https://huggingface.co/keptn/ornith-1.5-35b-a3b-fp8/resolve/main/ornith-1.5-35b-a3b-fp8.rad"
  ["minicpm5-2b-fp8.rad"]="https://huggingface.co/StillDeadcode/minicpm5-2b-fp8/resolve/main/minicpm5-2b-fp8.rad"
  ["gemma4-12b-i8g.rad"]="https://huggingface.co/keptn/gemma4-12b-i8g/resolve/main/gemma4-12b-i8g.rad"
)
# Shared interactive menu mechanism (see common.sh); resolves MODEL_TAG from CHOICES.
. "$(dirname "$0")/common.sh"

# Preflight: only supported GPUs (radiance runs on both).
require_gpu gfx1152 gfx1201

# Per-engine build/run flags (defaults match radiance's qwen3.6-35b-a3b.yaml compose).
GPU_TARGETS="${GPU_TARGETS:-gfx1152;gfx1201}"
# radiance's default of 256 sequences cannot fit a 32 GiB card: the linear/conv state
# alone is ~290 MiB a sequence for qwen3.8-27b (74 GiB at 256) against a ~10.5 GiB
# vram_kv budget, so startup dies with "vram_kv does not fit its fixed costs". 1
# sequence (single user) keeps the fixed cost near 0.3 GiB; raise MAX_NUM_SEQS for
# concurrent requests (~290 MiB VRAM + ~1.5 GiB pinned host RAM each).
MAX_NUM_SEQS="${MAX_NUM_SEQS:-1}"

select_model "$MODEL_DEFAULT_INDEX" "${1:-}" "${RADIANCE_MODEL:-}"
MODEL_NAME="$MODEL_TAG"

# 1. Clone radiance if not present
if [ ! -d "$RADIANCE_DIR" ]; then
  echo "Cloning $RADIANCE_DIR ..."
  git clone https://codeberg.org/StillDeadcode/radiance.git "$RADIANCE_DIR"
fi

# 2. Build the image locally from the clone. The context is the working tree (the
#    repo's .dockerignore drops build/, .git, *.rad, so this is as clean as a
#    `git archive`); GPU_TARGETS selects the RDNA kernel families to compile.
#    --load puts the result in the local image store (tagged via -t).
#    TEST_EXCLUDE skips the host test suite: radiance's CI asserts RDNA defaults
#    that this hardware isn't, so every update adds a failing test; the build
#    only needs the host-tests marker, which an empty run still writes.
docker buildx build --progress=plain \
  --load \
  --build-arg GPU_TARGETS="$GPU_TARGETS" \
  --build-arg TEST_EXCLUDE=".*" \
  -t "$IMAGE_NAME" \
  "$RADIANCE_DIR"

# 3. Download the model if it is not present yet (fetch on demand via MODEL_URLS)
MODEL_DIR="$MODELS_DIR"
download_model "$MODEL_NAME"

# 4. Run the server (GPU passthrough + OpenAI-compatible API on $PORT)
PORT="${PORT:-9931}"
docker rm -f radiance_server 2>/dev/null || true
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
  --max-model-len 262144 \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --kv-cache-dtype fp8
