#!/bin/bash
set -euo pipefail

# llama.cpp Vulkan server launcher
LLAMA_CPP_DIR="llama.cpp"
DOCKERFILE="$LLAMA_CPP_DIR/.devops/vulkan.Dockerfile"
IMAGE_NAME="local/llama.cpp:server-vulkan"
MODEL_DIR="/models/gguf"

# --- Model selection menu ----------------------------------------------------
# Same mechanism as run_openflowlm.sh (see common.sh); each engine keeps its own
# CHOICES. Here the value is the GGUF filename; MODEL_URLS maps that name to the
# HuggingFace download so it can be fetched on demand.
CHOICES=(
  "ornith1.5-35b-a3b|Ornith-1.5-35B-Q4_K_M.gguf"
  "qwen3.8-27b|Qwen3.8-27B-UD-Q4_K_M.gguf"
  "ornith1.5-9b|Ornith-1.5-9B-Q4_K_M.gguf"
  "gemma4-12b-it|gemma-4-12b-it-Q4_K_M.gguf"
  "gemma4-26b-a4b|gemma-4-26B-A4B-it-UD-Q4_K_M.gguf"
  "gpt-oss-20b|gpt-oss-20b-Q4_K_M.gguf"
  "qwen3-coder-30b|Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
)
MENU_TITLE="llama.cpp model selection (runs on the AMD Radeon GPU via Vulkan):"
MODEL_DEFAULT_INDEX=1   # ornith-1.5-35B-A3B-GGUF
# label -> download URL, keyed by GGUF filename; add entries for extra models.
declare -A MODEL_URLS=(
  ["Ornith-1.5-35B-Q4_K_M.gguf"]="https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-GGUF/resolve/main/Ornith-1.5-35B-Q4_K_M.gguf?download=true"
  ["Qwen3.8-27B-UD-Q4_K_M.gguf"]="https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-Q4_K_M.gguf?download=true"
  ["Ornith-1.5-9B-Q4_K_M.gguf"]="https://huggingface.co/ornith-ai/Ornith-1.5-9B-GGUF/resolve/main/Ornith-1.5-9B-Q4_K_M.gguf?download=true"
  ["gemma-4-12b-it-Q4_K_M.gguf"]="https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q4_K_M.gguf?download=true"
  ["gemma-4-26B-A4B-it-UD-Q4_K_M.gguf"]="https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf?download=true"
  ["gpt-oss-20b-Q4_K_M.gguf"]="https://huggingface.co/unsloth/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-Q4_K_M.gguf?download=true"
  ["Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"]="https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf?download=true"
)
# Shared interactive menu mechanism (see common.sh); resolves MODEL_TAG from CHOICES.
. "$(dirname "$0")/common.sh"

select_model "$MODEL_DEFAULT_INDEX" "${1:-}" "${LLAMA_MODEL:-}"
MODEL_NAME="$MODEL_TAG"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"

# 2. Build the Vulkan server image from the local clone
docker build -f "$DOCKERFILE" --target server -t "$IMAGE_NAME" "$LLAMA_CPP_DIR"

# 3. Download the model if it is not present yet (fetch on demand via MODEL_URLS)
if [ ! -f "$MODEL_PATH" ]; then
  mkdir -p "$(dirname "$MODEL_PATH")"
  if [ -z "${MODEL_URLS[$MODEL_NAME]:-}" ]; then
    echo "ERROR: no download URL for '$MODEL_NAME' in MODEL_URLS." >&2
    exit 1
  fi
  echo "Downloading $MODEL_NAME ..."
  wget -O "$MODEL_PATH" "${MODEL_URLS[$MODEL_NAME]}"
fi

# 4. Run the Vulkan server (PORT default 9931, shared with hipfire/OFLM -- run alone on it)
PORT="${PORT:-9931}"
docker run --rm --name llama-vulkan-server \
  --device /dev/dri:/dev/dri \
  -v /models:/models \
  -p "$PORT:$PORT" \
  "$IMAGE_NAME" \
  --model "$MODEL_PATH" \
  --host 0.0.0.0 \
  --port "$PORT" \
  --reasoning-effort medium
