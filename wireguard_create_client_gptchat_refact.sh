#!/usr/bin/env bash
# Wrapper script kept for compatibility. Produces JSON output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/scripts/wg_create_peer.sh"

if [[ ! -x "$TARGET" ]]; then
  echo "{\"status\":\"error\",\"message\":\"wg_create_peer.sh not found at $TARGET\"}"
  exit 1
fi

exec "$TARGET" "$@"
