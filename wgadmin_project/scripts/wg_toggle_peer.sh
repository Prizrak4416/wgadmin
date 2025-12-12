#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/log.txt}"
log() { echo "$(date +'%Y-%m-%d %H:%M:%S%z') [wg_toggle_peer] $*" >> "$LOG_FILE"; }
SUDO_BIN="${SUDO_BIN:-sudo}"
RUN_AS_ROOT="${RUN_AS_ROOT:-false}"
TEMP_DIR="${TEMP_DIR:-${SCRIPT_DIR}/temp}"
WG_GROUP="${WG_GROUP:-wgadmin}"
if [[ "$EUID" -eq 0 ]]; then
  RUN_AS_ROOT=true
fi

WG_CONFIG_PATH="${WG_CONFIG_PATH:-/etc/wireguard/wg0.conf}"

IDENTIFIER=""
MODE="enable"

usage() {
  echo "Usage: $0 (--enable|--disable) --id <identifier>"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable)
      MODE="enable"; shift;;
    --disable)
      MODE="disable"; shift;;
    --id)
      IDENTIFIER="$2"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown argument: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$IDENTIFIER" ]]; then
  echo '{"status":"error","message":"--id required"}'
  log "error: missing --id"
  exit 1
fi
log "start toggle id=${IDENTIFIER} mode=${MODE} config=${WG_CONFIG_PATH}"

mkdir -p "$TEMP_DIR"
tmp=$(mktemp -p "$TEMP_DIR" || mktemp)
python3 - "$IDENTIFIER" "$WG_CONFIG_PATH" "$tmp" "$MODE" <<'PY'
import pathlib
import re
import sys

identifier, source_path, tmp_path, mode = sys.argv[1:]
enable = mode == "enable"
src = pathlib.Path(source_path)
lines = src.read_text().splitlines()
out = []
i = 0
while i < len(lines):
    line = lines[i]
    stripped = line.strip()
    is_peer_header = re.match(r"#?\s*\[Peer\]", stripped, re.IGNORECASE)
    if is_peer_header:
        block = [line]
        j = i + 1
        while j < len(lines) and not re.match(r"#?\s*\[Peer\]", lines[j].strip(), re.IGNORECASE):
            block.append(lines[j])
            j += 1
        block_text = "\n".join(block)
        comment_name = ""
        k = i - 1
        while k >= 0 and lines[k].strip().startswith("#"):
            comment_name = lines[k].strip().lstrip("#").strip()
            break
        normalized_name = comment_name.replace("Name:", "").strip()
        # extract public key for exact match
        m_pk = re.search(r"PublicKey\s*=\s*([A-Za-z0-9+/=]+)", block_text)
        block_pk = m_pk.group(1) if m_pk else ""
        match = False
        if normalized_name and identifier == normalized_name:
            match = True
        elif identifier == block_pk:
            match = True
        if match:
            new_block = []
            for ln in block:
                if enable:
                    # Uncomment config lines; keep user comments intact
                    if re.match(r"^\s*#\s*(\[Peer\]|PublicKey|AllowedIPs|Endpoint|PersistentKeepalive|PresharedKey)", ln):
                        new_block.append(re.sub(r"^\s*#\s*", "", ln))
                    else:
                        new_block.append(ln)
                else:
                    stripped = ln.lstrip()
                    if stripped.startswith("#"):
                        # leave existing comments untouched
                        new_block.append(ln)
                    elif re.match(r"^\[Peer\]|^PublicKey|^AllowedIPs|^Endpoint|^PersistentKeepalive|^PresharedKey", stripped):
                        new_block.append("# " + ln)
                    else:
                        new_block.append(ln)
            out.extend(new_block)
            i = j
            continue
        out.extend(block)
        i = j
        continue
    out.append(line)
    i += 1

pathlib.Path(tmp_path).write_text("\n".join(out) + "\n")
PY
if $RUN_AS_ROOT; then
  sudo mv "$tmp" "$WG_CONFIG_PATH"
elif $SUDO_BIN -n true >/dev/null 2>&1; then
  $SUDO_BIN mv "$tmp" "$WG_CONFIG_PATH"
else
  sudo mv "$tmp" "$WG_CONFIG_PATH"
fi

if [[ ! -f "$WG_CONFIG_PATH" ]]; then
  echo '{"status":"error","message":"failed to update config"}'
  log "error: failed to replace config"
  exit 1
fi
# restore permissions
if $RUN_AS_ROOT; then
  chown root:${WG_GROUP} "$WG_CONFIG_PATH" || true
  chmod 660 "$WG_CONFIG_PATH" || true
elif $SUDO_BIN -n true >/dev/null 2>&1; then
  $SUDO_BIN chown root:${WG_GROUP} "$WG_CONFIG_PATH" || true
  $SUDO_BIN chmod 660 "$WG_CONFIG_PATH" || true
fi

if $RUN_AS_ROOT; then
  systemctl restart "wg-quick@${WG_INTERFACE:-wg0}.service" >/dev/null 2>&1 || true
elif $SUDO_BIN -n true >/dev/null 2>&1; then
  $SUDO_BIN systemctl restart "wg-quick@${WG_INTERFACE:-wg0}.service" >/dev/null 2>&1 || true
else
  systemctl restart "wg-quick@${WG_INTERFACE:-wg0}.service" >/dev/null 2>&1 || true
fi

log "toggled id=${IDENTIFIER} mode=${MODE}"

cat <<EOF
{
  "status": "ok",
  "id": "$IDENTIFIER",
  "mode": "$MODE"
}
EOF
