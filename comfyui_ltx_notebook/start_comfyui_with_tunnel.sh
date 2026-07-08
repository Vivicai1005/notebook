#!/bin/bash
set -e

# SCRIPT_VERSION="2026-07-08-v1-radeon-tunnel"

export PATH=/opt/venv/bin:/opt/rocm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export COMFY_PORT=${COMFY_PORT:-8188}
export RADEON_TUNNEL_AUTH=${RADEON_TUNNEL_AUTH:-4de02807e814ca0f0722f97faef8488d}
export TUNNEL_URL_TIMEOUT=${TUNNEL_URL_TIMEOUT:-60}
export TUNNEL_REQUIRED=${TUNNEL_REQUIRED:-1}

TUNNEL_BIN=/tmp/radeon-tunnel
TUNNEL_SERVER=http://36.150.116.206:20080

# Kill any prior instances
pkill -f 'python3 main.py --listen 0.0.0.0 --port 8188' || true
pkill -f 'radeon-tunnel expose' || true

# Start ComfyUI in background
echo "[start] launching ComfyUI on 0.0.0.0:${COMFY_PORT}"
# echo "[start] script version: ${SCRIPT_VERSION}"
cd /comfyui_workspace/ComfyUI
unset DEFAULT_WORKFLOW
nohup python3 main.py --listen 0.0.0.0 --port "${COMFY_PORT}" > /tmp/comfyui.log 2>&1 &
COMFY_PID=$!
echo $COMFY_PID > /tmp/comfyui.pid
sleep 3

# Download latest radeon-tunnel client
echo "[tunnel] downloading radeon-tunnel client from ${TUNNEL_SERVER}"
curl --noproxy '*' -fsSL "${TUNNEL_SERVER}/client" -o "${TUNNEL_BIN}"
chmod +x "${TUNNEL_BIN}"

# Clean up old tunnel state
rm -rf ~/.radeon

# Start radeon-tunnel in background
echo "[tunnel] starting radeon-tunnel expose ${COMFY_PORT}"
rm -f /tmp/tunnel.log
nohup "${TUNNEL_BIN}" expose "${COMFY_PORT}" > /tmp/tunnel.log 2>&1 &
TUNNEL_PID=$!
echo $TUNNEL_PID > /tmp/tunnel.pid

# Wait for public URL to appear in tunnel log
echo "[tunnel] waiting for public URL..."
PUBLIC_URL=""
for i in $(seq 1 "$TUNNEL_URL_TIMEOUT"); do
  sleep 1
  PUBLIC_URL=$(grep -Eo 'https?://[a-zA-Z0-9.:-]+' /tmp/tunnel.log 2>/dev/null | head -1)
  if [ -n "$PUBLIC_URL" ]; then
    break
  fi
done

if [ -n "$PUBLIC_URL" ]; then
  echo ""
  echo "========================================"
  echo "GREEN Public URL: $PUBLIC_URL"
  echo "========================================"
else
  echo "[warn] Tunnel started but URL not found in ${TUNNEL_URL_TIMEOUT}s."
  echo "[warn] Last tunnel log lines:"
  tail -n 40 /tmp/tunnel.log || true
  if [ "$TUNNEL_REQUIRED" = "1" ]; then
    echo "[error] TUNNEL_REQUIRED=1 and no public URL was obtained. Exiting."
    kill "$TUNNEL_PID" >/dev/null 2>&1 || true
    kill "$COMFY_PID" >/dev/null 2>&1 || true
    exit 2
  else
    echo "[warn] Continuing because TUNNEL_REQUIRED=${TUNNEL_REQUIRED}."
  fi
fi

echo "[start] ComfyUI is running on http://127.0.0.1:${COMFY_PORT}"
echo "[start] Tunnel PID: $TUNNEL_PID"
echo "[start] ComfyUI PID: $COMFY_PID"
echo "[start] Logs: /tmp/comfyui.log (ComfyUI), /tmp/tunnel.log (Tunnel)"

wait $COMFY_PID
