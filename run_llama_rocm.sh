#!/bin/bash
set -euo pipefail

# llama.cpp ROCm server launcher
LLAMA_CPP_DIR="llama.cpp"

# --- Model selection menu ----------------------------------------------------
# Same mechanism as run_openflowlm.sh (see common.sh); the value is the GGUF
# filename; MODEL_URLS maps that name to the HuggingFace download so it can be
# fetched on demand. Same GGUF models as run_llama_vulkan.sh -- llama.cpp serves
# them regardless of backend.
CHOICES=(
  "ornith1.5-35b-a3b|Ornith-1.5-35B-Q4_K_M.gguf"
  "qwen3.8-27b|Qwen3.8-27B-UD-Q4_K_M.gguf"
  "ornith1.5-9b|Ornith-1.5-9B-Q4_K_M.gguf"
  "gemma4-12b-it|gemma-4-12b-it-Q4_K_M.gguf"
  "gemma4-26b-a4b|gemma-4-26B-A4B-it-UD-Q4_K_M.gguf"
  "gpt-oss-20b|gpt-oss-20b-Q4_K_M.gguf"
  "qwen3-coder-30b|Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"
  "qwen3.6-35b-a3b-ud|Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
)
MENU_TITLE="llama.cpp model selection (runs on the AMD GPU via ROCm):"
MODEL_DEFAULT_INDEX=1 # ornith-1.5-35B-A3B-GGUF
# label -> download URL, keyed by GGUF filename; add entries for extra models.
declare -A MODEL_URLS=(
  ["Ornith-1.5-35B-Q4_K_M.gguf"]="https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-GGUF/resolve/main/Ornith-1.5-35B-Q4_K_M.gguf?download=true"
  ["Qwen3.8-27B-UD-Q4_K_M.gguf"]="https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-Q4_K_M.gguf?download=true"
  ["Ornith-1.5-9B-Q4_K_M.gguf"]="https://huggingface.co/ornith-ai/Ornith-1.5-9B-GGUF/resolve/main/Ornith-1.5-9B-Q4_K_M.gguf?download=true"
  ["gemma-4-12b-it-Q4_K_M.gguf"]="https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q4_K_M.gguf?download=true"
  ["gemma-4-26B-A4B-it-UD-Q4_K_M.gguf"]="https://huggingface.co/unsloth/gemma-4-26B-A4B-it-GGUF/resolve/main/gemma-4-26B-A4B-it-UD-Q4_K_M.gguf?download=true"
  ["gpt-oss-20b-Q4_K_M.gguf"]="https://huggingface.co/unsloth/gpt-oss-20b-GGUF/resolve/main/gpt-oss-20b-Q4_K_M.gguf?download=true"
  ["Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf"]="https://huggingface.co/unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/resolve/main/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf?download=true"
  ["Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"]="https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf?download=true"
)
# Shared interactive menu mechanism (see common.sh); resolves MODEL_TAG from CHOICES.
. "$(dirname "$0")/common.sh"

# Per-backend build/run inputs consumed by the common.sh helpers.
DOCKERFILE="$LLAMA_CPP_DIR/.devops/rocm.Dockerfile"
IMAGE_NAME="local/llama.cpp:server-rocm"
MODEL_DIR="/models/gguf"
SERVER_NAME="llama-rocm-server"
# llama.cpp serves over ROCm through /dev/dri.
EXTRA_RUN_ARGS=(--device /dev/dri:/dev/dri)

select_model "$MODEL_DEFAULT_INDEX" "${1:-}" "${LLAMA_MODEL:-}"
MODEL_NAME="$MODEL_TAG"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"

# 1. Clone llama.cpp if not present
clone_llama_cpp "$LLAMA_CPP_DIR"

# 2. Build the ROCm server image from the local clone
build_llama_server

# 3. Download the model if it is not present yet (fetch on demand via MODEL_URLS)
download_model "$MODEL_NAME"

# 4. Run the ROCm server (PORT default 9931, shared with hipfire/OFLM -- run alone on it)
PORT="${PORT:-9931}"
run_llama_server
