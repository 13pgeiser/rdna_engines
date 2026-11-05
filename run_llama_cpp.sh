#!/bin/bash

docker run --rm --name llama-vulkan-server --device /dev/dri:/dev/dri -v /models:/models -p 9931:9931 ghcr.io/ggml-org/llama.cpp:server-vulkan --model /models/gguf/Ornith-1.5-35B-Q4_K_M.gguf --host 0.0.0.0 --port 9931

