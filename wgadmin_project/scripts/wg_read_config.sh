#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/log.txt}"
log() { echo "$(date +'%Y-%m-%d %H:%M:%S%z') [wg_read_config] $*" >> "$LOG_FILE"; }

WG_CONFIG_PATH="${WG_CONFIG_PATH:-/etc/wireguard/wg0.conf}"

if [[ ! -f "$WG_CONFIG_PATH" ]]; then
  echo '{"status":"error","message":"config not found"}'
  log "error: config not found at ${WG_CONFIG_PATH}"
  exit 1
fi

# Проверяем, что есть python3
if ! command -v python3 >/dev/null 2>&1; then
  echo '{"status":"error","message":"python3 not found"}'
  log "error: python3 not found"
  exit 1
fi

log "read config ${WG_CONFIG_PATH}"
printf '{"status":"ok","config":'
python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()), end="")' < "$WG_CONFIG_PATH"
printf "}\n"
