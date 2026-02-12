#!/usr/bin/env bash
# Collects WireGuard traffic statistics and calls Django management command
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/log.txt}"
log() { echo "$(date +'%Y-%m-%d %H:%M:%S%z') [wg_collect_stats] $*" >> "$LOG_FILE"; }

WG_INTERFACE="${WG_INTERFACE:-wg0}"
DJANGO_PROJECT_DIR="${DJANGO_PROJECT_DIR:-$(dirname "$SCRIPT_DIR")}"
VENV_PYTHON="${VENV_PYTHON:-${DJANGO_PROJECT_DIR}/../venv/bin/python}"
TMP_FILE="/tmp/wg_stats_dump_$$.txt"

cleanup() {
    rm -f "$TMP_FILE"
}
trap cleanup EXIT

log "Starting stats collection for interface $WG_INTERFACE"

# Get WireGuard dump
if ! wg show "$WG_INTERFACE" dump > "$TMP_FILE" 2>/dev/null; then
    log "error: failed to get wg dump for $WG_INTERFACE"
    echo '{"status":"error","message":"failed to get wg dump"}'
    exit 1
fi

# Check if we have any peers (file should have more than 1 line - header + peers)
line_count=$(wc -l < "$TMP_FILE")
if [ "$line_count" -le 1 ]; then
    log "warning: no peers found in wg dump"
    echo '{"status":"ok","message":"no peers found","count":0}'
    exit 0
fi

# Call Django management command
cd "$DJANGO_PROJECT_DIR"

# Try to find Python interpreter
if [ -x "$VENV_PYTHON" ]; then
    PYTHON="$VENV_PYTHON"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON="python3"
elif command -v python >/dev/null 2>&1; then
    PYTHON="python"
else
    log "error: python interpreter not found"
    echo '{"status":"error","message":"python not found"}'
    exit 1
fi

if ! output=$("$PYTHON" manage.py collect_traffic_stats "$TMP_FILE" 2>&1); then
    log "error: Django command failed: $output"
    echo "{\"status\":\"error\",\"message\":\"django command failed\"}"
    exit 1
fi

log "Stats collection completed successfully"
echo '{"status":"ok"}'
