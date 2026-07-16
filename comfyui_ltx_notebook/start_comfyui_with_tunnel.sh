#!/bin/bash
set -Eeuo pipefail

# Unified ComfyUI launcher for AMD Instinct and AMD Radeon GPUs.
#
# Hardware routing:
#   - gfx942: AMD Instinct MI300X
#             Use the cluster built-in reverse proxy.
#
#   - Other architectures:
#             Use radeon-tunnel.
#
# Manual override:
#   COMFY_HARDWARE=instinct ./start_comfyui_with_tunnel.sh
#   COMFY_HARDWARE=radeon  ./start_comfyui_with_tunnel.sh

export PATH=/opt/venv/bin:/opt/rocm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin


# =============================================================================
# Configuration
# =============================================================================

COMFY_PORT="${COMFY_PORT:-8188}"
COMFY_DIR="${COMFY_DIR:-/comfyui_workspace/ComfyUI}"
COMFY_READY_TIMEOUT="${COMFY_READY_TIMEOUT:-120}"

# auto | instinct | radeon
COMFY_HARDWARE="${COMFY_HARDWARE:-auto}"

TUNNEL_BIN="${TUNNEL_BIN:-/tmp/radeon-tunnel}"
TUNNEL_SERVER="${TUNNEL_SERVER:-http://36.150.116.206:20080}"
TUNNEL_URL_TIMEOUT="${TUNNEL_URL_TIMEOUT:-60}"
TUNNEL_REQUIRED="${TUNNEL_REQUIRED:-1}"

# Keep the existing default for compatibility.
# It can also be overridden through an environment variable.
RADEON_TUNNEL_AUTH="${RADEON_TUNNEL_AUTH:-4de02807e814ca0f0722f97faef8488d}"

COMFY_PID_FILE="/tmp/comfyui.pid"
TUNNEL_PID_FILE="/tmp/tunnel.pid"

COMFY_LOG="/tmp/comfyui.log"
TUNNEL_LOG="/tmp/tunnel.log"

COMFY_PID=""
TUNNEL_PID=""
GCN_ARCH_NAME=""
HARDWARE_TYPE=""


# =============================================================================
# Logging helpers
# =============================================================================

log() {
  echo "$*"
}


print_public_url() {
  local public_url="$1"

  echo ""
  echo "========================================"

  if [[ -n "${public_url}" ]]; then
    echo "GREEN Public URL: ${public_url}"
  else
    echo "[warn] Public URL is unavailable."
  fi

  echo "========================================"
}


# =============================================================================
# Hardware detection
# =============================================================================

detect_gpu_arch() {
  python3 - <<'PY'
import sys

try:
    import torch

    if not torch.cuda.is_available():
        raise RuntimeError("No ROCm/CUDA device is available")

    properties = torch.cuda.get_device_properties(0)
    arch_name = getattr(properties, "gcnArchName", "")

    if not arch_name:
        raise RuntimeError(
            "torch.cuda device property gcnArchName is unavailable"
        )

    print(arch_name)

except Exception as error:
    print(
        f"[error] Failed to detect GPU architecture: {error}",
        file=sys.stderr,
    )
    sys.exit(1)
PY
}


detect_hardware_type() {
  case "${COMFY_HARDWARE}" in
    instinct)
      HARDWARE_TYPE="instinct"
      GCN_ARCH_NAME="manual-override"
      ;;

    radeon)
      HARDWARE_TYPE="radeon"
      GCN_ARCH_NAME="manual-override"
      ;;

    auto)
      log "[detect] detecting AMD GPU architecture..."

      GCN_ARCH_NAME="$(detect_gpu_arch)"

      if [[ "${GCN_ARCH_NAME}" == *"gfx942"* ]]; then
        HARDWARE_TYPE="instinct"
      else
        HARDWARE_TYPE="radeon"
      fi
      ;;

    *)
      log "[error] Invalid COMFY_HARDWARE value: ${COMFY_HARDWARE}"
      log "[error] Supported values: auto, instinct, radeon"
      exit 1
      ;;
  esac

  log "[detect] GPU architecture: ${GCN_ARCH_NAME}"
  log "[detect] hardware type: ${HARDWARE_TYPE}"
}


# =============================================================================
# Safe process cleanup
# =============================================================================

stop_process_from_pidfile() {
  local pid_file="$1"
  local expected_command="$2"
  local process_name="$3"

  if [[ ! -f "${pid_file}" ]]; then
    return 0
  fi

  local pid=""
  local command_line=""

  pid="$(cat "${pid_file}" 2>/dev/null || true)"

  if [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
    log "[cleanup] removing invalid PID file: ${pid_file}"
    rm -f "${pid_file}"
    return 0
  fi

  if ! kill -0 "${pid}" 2>/dev/null; then
    log "[cleanup] removing stale PID file: ${pid_file}"
    rm -f "${pid_file}"
    return 0
  fi

  command_line="$(
    tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true
  )"

  if [[ "${command_line}" != *"${expected_command}"* ]]; then
    log "[cleanup] PID ${pid} is not the recorded ${process_name}."
    log "[cleanup] Leaving that process unchanged."
    log "[cleanup] Command: ${command_line:-unknown}"

    rm -f "${pid_file}"
    return 0
  fi

  log "[cleanup] stopping previous ${process_name} PID ${pid}"

  kill "${pid}" 2>/dev/null || true

  for _ in $(seq 1 10); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      break
    fi

    sleep 1
  done

  if kill -0 "${pid}" 2>/dev/null; then
    log "[cleanup] force stopping previous ${process_name} PID ${pid}"
    kill -9 "${pid}" 2>/dev/null || true
  fi

  rm -f "${pid_file}"
}


stop_previous_processes() {
  log "[cleanup] checking previous ComfyUI and tunnel processes..."

  stop_process_from_pidfile \
    "${COMFY_PID_FILE}" \
    "main.py --listen 0.0.0.0 --port ${COMFY_PORT}" \
    "ComfyUI"

  stop_process_from_pidfile \
    "${TUNNEL_PID_FILE}" \
    "radeon-tunnel expose ${COMFY_PORT}" \
    "Radeon tunnel"
}


cleanup() {
  local exit_code=$?

  trap - EXIT INT TERM

  if [[ -n "${TUNNEL_PID}" ]] &&
     kill -0 "${TUNNEL_PID}" 2>/dev/null; then

    log "[cleanup] stopping Radeon tunnel PID ${TUNNEL_PID}"
    kill "${TUNNEL_PID}" >/dev/null 2>&1 || true
  fi

  if [[ -n "${COMFY_PID}" ]] &&
     kill -0 "${COMFY_PID}" 2>/dev/null; then

    log "[cleanup] stopping ComfyUI PID ${COMFY_PID}"
    kill "${COMFY_PID}" >/dev/null 2>&1 || true
  fi

  rm -f "${COMFY_PID_FILE}" "${TUNNEL_PID_FILE}"

  exit "${exit_code}"
}


# =============================================================================
# ComfyUI startup
# =============================================================================

start_comfyui() {
  if [[ ! -d "${COMFY_DIR}" ]]; then
    log "[error] ComfyUI directory does not exist:"
    log "[error] ${COMFY_DIR}"
    exit 1
  fi

  log "[start] launching ComfyUI on 0.0.0.0:${COMFY_PORT}"

  cd "${COMFY_DIR}"

  unset DEFAULT_WORKFLOW || true
  rm -f "${COMFY_LOG}"

  nohup python3 main.py \
    --listen 0.0.0.0 \
    --port "${COMFY_PORT}" \
    > "${COMFY_LOG}" 2>&1 &

  COMFY_PID=$!

  echo "${COMFY_PID}" > "${COMFY_PID_FILE}"

  log "[start] ComfyUI PID: ${COMFY_PID}"
}


wait_for_comfyui() {
  log "[start] waiting for ComfyUI to become ready..."

  local ready=0

  for ((i = 1; i <= COMFY_READY_TIMEOUT; i++)); do
    sleep 1

    if ! kill -0 "${COMFY_PID}" 2>/dev/null; then
      log "[error] ComfyUI exited before becoming ready."
      log "[error] Last ComfyUI log lines:"

      tail -n 80 "${COMFY_LOG}" || true
      exit 1
    fi

    if curl \
      -sS \
      -o /dev/null \
      --max-time 2 \
      "http://127.0.0.1:${COMFY_PORT}/" \
      2>/dev/null; then

      ready=1
      break
    fi
  done

  if [[ "${ready}" != "1" ]]; then
    log "[error] ComfyUI did not become ready within ${COMFY_READY_TIMEOUT}s."
    log "[error] Last ComfyUI log lines:"

    tail -n 80 "${COMFY_LOG}" || true
    exit 1
  fi

  log "[start] ComfyUI is ready."
}


# =============================================================================
# AMD Instinct proxy
# =============================================================================

start_instinct_proxy() {
  log "[proxy] using the Instinct cluster built-in reverse proxy"

  local public_url=""

  public_url="${COMFY_PUBLIC_URL:-${ONECLICK_APP_URL:-}}"

  if [[ -n "${public_url}" ]]; then
    print_public_url "${public_url}"
  else
    print_public_url ""

    log "[warn] COMFY_PUBLIC_URL and ONECLICK_APP_URL are not set."
    log "[warn] Open this instance's App URL for port ${COMFY_PORT}"
    log "[warn] from the cluster console."
  fi
}


# =============================================================================
# AMD Radeon tunnel
# =============================================================================

start_radeon_tunnel() {
  export RADEON_TUNNEL_AUTH

  log "[tunnel] downloading radeon-tunnel client from ${TUNNEL_SERVER}"

  curl \
    --noproxy '*' \
    -fsSL \
    "${TUNNEL_SERVER}/client" \
    -o "${TUNNEL_BIN}"

  chmod +x "${TUNNEL_BIN}"

  # Remove stale tunnel state.
  rm -rf "${HOME:-/root}/.radeon"
  rm -f "${TUNNEL_LOG}"

  log "[tunnel] starting radeon-tunnel expose ${COMFY_PORT}"

  nohup "${TUNNEL_BIN}" expose "${COMFY_PORT}" \
    > "${TUNNEL_LOG}" 2>&1 &

  TUNNEL_PID=$!

  echo "${TUNNEL_PID}" > "${TUNNEL_PID_FILE}"

  log "[tunnel] Tunnel PID: ${TUNNEL_PID}"
  log "[tunnel] waiting for public URL..."

  local public_url=""

  for ((i = 1; i <= TUNNEL_URL_TIMEOUT; i++)); do
    sleep 1

    if ! kill -0 "${TUNNEL_PID}" 2>/dev/null; then
      log "[error] Radeon tunnel exited before returning a public URL."
      log "[error] Last tunnel log lines:"

      tail -n 80 "${TUNNEL_LOG}" || true
      break
    fi

    public_url="$(
      grep -Eo \
        'https?://[^[:space:]]+' \
        "${TUNNEL_LOG}" \
        2>/dev/null |
        head -1 ||
        true
    )"

    if [[ -n "${public_url}" ]]; then
      break
    fi
  done

  if [[ -n "${public_url}" ]]; then
    print_public_url "${public_url}"
    return 0
  fi

  log "[warn] Tunnel URL was not found within ${TUNNEL_URL_TIMEOUT}s."
  log "[warn] Last tunnel log lines:"

  tail -n 40 "${TUNNEL_LOG}" || true

  if [[ "${TUNNEL_REQUIRED}" == "1" ]]; then
    log "[error] TUNNEL_REQUIRED=1, so the launcher will exit."
    exit 2
  fi

  log "[warn] Continuing because TUNNEL_REQUIRED=${TUNNEL_REQUIRED}."
}


# =============================================================================
# Main
# =============================================================================

main() {
  trap cleanup EXIT INT TERM

  log "[launcher] unified ComfyUI launcher started"

  detect_hardware_type
  stop_previous_processes
  start_comfyui
  wait_for_comfyui

  case "${HARDWARE_TYPE}" in
    instinct)
      start_instinct_proxy
      ;;

    radeon)
      start_radeon_tunnel
      ;;
  esac

  echo ""
  log "[start] ComfyUI is running."
  log "[start] Hardware type: ${HARDWARE_TYPE}"
  log "[start] GPU architecture: ${GCN_ARCH_NAME}"
  log "[start] ComfyUI PID: ${COMFY_PID}"
  log "[start] ComfyUI logs: ${COMFY_LOG}"

  if [[ -n "${TUNNEL_PID}" ]]; then
    log "[start] Tunnel PID: ${TUNNEL_PID}"
    log "[start] Tunnel logs: ${TUNNEL_LOG}"
  fi

  # Keep the Notebook cell and ComfyUI server running.
  wait "${COMFY_PID}"
}


main "$@"
