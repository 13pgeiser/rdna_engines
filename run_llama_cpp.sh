#!/bin/bash
set -euo pipefail

# llama.cpp Vulkan server launcher
LLAMA_CPP_DIR="llama.cpp"
DOCKERFILE="$LLAMA_CPP_DIR/.devops/vulkan.Dockerfile"
IMAGE_NAME="local/llama.cpp:server-vulkan"
MODEL_NAME="Ornith-1.5-35B-Q4_K_M.gguf"
MODEL_PATH="/models/gguf/$MODEL_NAME"
MODEL_URL="https://huggingface.co/ornith-ai/Ornith-1.5-35B-A3B-GGUF/resolve/main/Ornith-1.5-35B-Q4_K_M.gguf?download=true"

# 1. Clone llama.cpp if not present
if [ ! -d "$LLAMA_CPP_DIR" ]; then
  git clone https://github.com/ggml-org/llama.cpp.git
fi

# 2. Build the Vulkan server image from the local clone
docker build -f "$DOCKERFILE" --target server -t "$IMAGE_NAME" "$LLAMA_CPP_DIR"

# 3. Download the model if it is not present yet
if [ ! -f "$MODEL_PATH" ]; then
  mkdir -p "$(dirname "$MODEL_PATH")"
  echo "Downloading $MODEL_NAME ..."
  wget -O "$MODEL_PATH" "$MODEL_URL"
fi

# 4. Run the Vulkan server
docker run --rm --name llama-vulkan-server \
  --device /dev/dri:/dev/dri \
  -v /models:/models \
  -p 9931:9931 \
  "$IMAGE_NAME" \
  --model "$MODEL_PATH" \
  --host 0.0.0.0 \
  --port 9931
