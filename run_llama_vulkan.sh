#!/bin/bash
set -euo pipefail

# llama.cpp Vulkan server launcher
LLAMA_CPP_DIR="llama.cpp"

# Shared helpers + the (backend-agnostic) model menu (see common.sh);
# select_llama_model sets the menu globals and resolves MODEL_TAG.
. "$(dirname "$0")/common.sh"

# Preflight: only supported GPUs (Vulkan runs on both).
require_gpu gfx1152 gfx1201

# Per-backend build/run inputs consumed by the common.sh helpers.
DOCKERFILE="$LLAMA_CPP_DIR/.devops/vulkan.Dockerfile"
IMAGE_NAME="local/llama.cpp:server-vulkan"
MODEL_DIR="/models/gguf"
SERVER_NAME="llama-vulkan-server"
# llama.cpp serves over Vulkan through /dev/dri.
EXTRA_RUN_ARGS=(--device /dev/dri:/dev/dri)

select_llama_model Vulkan "${1:-}"
MODEL_NAME="$MODEL_TAG"
MODEL_PATH="$MODEL_DIR/$MODEL_NAME"

deploy_llama
