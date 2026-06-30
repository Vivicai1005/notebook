#!/bin/bash
set -euo pipefail

mkdir -p /run/sshd
ssh-keygen -A
/usr/sbin/sshd -D -e &

# Optional workflow injection.
# If DEFAULT_WORKFLOW points to an existing json file inside the container,
# copy it as the initial default workflow; otherwise start with empty workflows.
WF_DIR=/comfyui_user/default/workflows
rm -rf /comfyui_user
mkdir -p "$WF_DIR"
if [[ -n "${DEFAULT_WORKFLOW:-}" && -f "${DEFAULT_WORKFLOW}" ]]; then
  cp -f "${DEFAULT_WORKFLOW}" "$WF_DIR/"
  echo "[start] default workflow = ${DEFAULT_WORKFLOW}"
else
  echo "[start] no default workflow"
fi

# Optional user-defined startup hook from mounted workspace.
HOOK=/comfyui_workspace/startup_hook.sh
if [[ -f "$HOOK" ]]; then
  bash "$HOOK"
fi

exec python main.py --listen 0.0.0.0 --port 8888 --user-directory /comfyui_user
