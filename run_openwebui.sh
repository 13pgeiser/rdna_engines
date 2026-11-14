#!/bin/bash
set -euo pipefail

# Open WebUI -- the web frontend + OpenAI-compatible proxy for local LLM backends.
#
# Open WebUI ships no local inference of its own: it serves the frontend and
# proxies OpenAI-compatible requests (/v1/chat/completions, /v1/models, ...) to
# an upstream OpenAI-compatible backend that is already running on this host
# (llama.cpp via run_llama_*.sh, hipfire via run_hipfire.sh, radiance via
# run_radiance.sh). The backend holds the AMD GPU; the webui container itself
# only needs to reach it over the docker bridge.
#
# Flow (mirrors the other engines: clone -> build -> run):
#   1. Clone open-webui if not present.
#   2. Build the webui image locally from the clone (frontend + backend build;
#      USE_SLIM=true swaps in the slim requirements and drops the extras).
#   3. Run the webui container, pointing OPENAI_API_BASE_URL at the backend.
#   4. Serve the Open WebUI frontend + the proxied OpenAI-compatible API.

OPENWEBUI_DIR="open-webui"
IMAGE_NAME="local/open-webui:latest"
OPENWEBUI_PORT="${OPENWEBUI_PORT:-3001}" # host port for the webui UI + proxied /v1 API

. "$(dirname "$0")/common.sh"

PORT="${PORT:-${DEFAULT_PORT}}" # backend API port (llama.cpp / hipfire / radiance)

# Upstream OpenAI-compatible backend the webui proxies to; defaults to the
# shared API port. Override with OPENAI_API_BASE_URL to point elsewhere.
OPENAI_API_BASE_URL="${OPENAI_API_BASE_URL:-http://host.docker.internal:${PORT}/v1}"
OPENAI_API_KEY="${OPENAI_API_KEY:-sk-no-key-needed}"
WEBUI_AUTH="${WEBUI_AUTH:-false}" # local single-user box: no login wall

# Preflight: Open WebUI is a proxy frontend -- the actual inference still needs
# an AMD GPU, which the backend launchers enforce via require_gpu (gfx1152 / gfx1201).
require_gpu gfx1152 gfx1201

# 1. Clone open-webui if not present.
if [ ! -d "$OPENWEBUI_DIR" ]; then
  echo "Cloning $OPENWEBUI_DIR ..."
  git clone https://github.com/open-webui/open-webui.git "$OPENWEBUI_DIR"
fi

# 2. Build the image locally from the clone. Multi-stage build (node frontend +
#    python backend); USE_SLIM=true uses the slim requirements and drops the
#    git/build/pandoc/ffmpeg extras.
docker build --progress=plain \
  --build-arg "USE_SLIM=${OPENWEBUI_SLIM:-false}" \
  -f "$OPENWEBUI_DIR/Dockerfile" \
  -t "$IMAGE_NAME" \
  "$OPENWEBUI_DIR"

# 3. Run the webui container.
docker volume create --name open-webui_data >/dev/null 2>&1 || true
stop_server open-webui
require_free_port "${OPENWEBUI_PORT}"
# DAEMON=1 -> detached, managed by Docker's restart policy (survives host reboot);
# default keeps the original foreground/self-removing behavior.
if [ "${DAEMON:-0}" = "1" ]; then
  RUN_MODE=(--restart unless-stopped -d)
else
  RUN_MODE=(--rm)
fi
docker run \
  --name open-webui \
  "${RUN_MODE[@]}" \
  --init \
  --add-host host.docker.internal:host-gateway \
  -e OPENAI_API_BASE_URL="$OPENAI_API_BASE_URL" \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  -e WEBUI_AUTH="$WEBUI_AUTH" \
  -e PORT=8080 \
  -v open-webui_data:/app/backend/data \
  -p "${OPENWEBUI_PORT}:8080" \
  "$IMAGE_NAME"
echo "Open WebUI: http://127.0.0.1:${OPENWEBUI_PORT}/"
echo "OpenAI-compatible API: http://127.0.0.1:${OPENWEBUI_PORT}/v1"
if [ "${DAEMON:-0}" = "1" ]; then
  echo "Detached as open-webui (restart=unless-stopped); follow logs with: docker logs -f open-webui"
fi
