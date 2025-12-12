#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/log.txt}"
log() { echo "$(date +'%Y-%m-%d %H:%M:%S%z') [wg_delete_peer] $*" >> "$LOG_FILE"; }
SUDO_BIN="${SUDO_BIN:-sudo}"
RUN_AS_ROOT="${RUN_AS_ROOT:-false}"
TEMP_DIR="${TEMP_DIR:-${SCRIPT_DIR}/temp}"
WG_GROUP="${WG_GROUP:-wgadmin}"
if [[ "$EUID" -eq 0 ]]; then
  RUN_AS_ROOT=true
fi

WG_CONFIG_PATH="${WG_CONFIG_PATH:-/etc/wireguard/wg0.conf}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
CLIENT_DIR="${WG_CLIENT_CONFIG_DIR:-/etc/wireguard/client}"
PUBLIC_CONF_DIR="${WG_PUBLIC_CONF_DIR:-/var/www/wireguard/conf}"
QR_DIR="${WG_QR_DIR:-/var/www/wireguard/qr}"

IDENTIFIER=""

usage() {
  echo "Usage: $0 --id <name-or-public-key>"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
log "start delete id=${IDENTIFIER} config=${WG_CONFIG_PATH}"

mkdir -p "$TEMP_DIR"
tmp=$(mktemp -p "$TEMP_DIR" || mktemp)
python3 - "$IDENTIFIER" "$WG_CONFIG_PATH" "$tmp" <<'PY'
import pathlib
import re
import sys

identifier, source_path, tmp_path = sys.argv[1:]
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
        while j < len(lines):
            next_line = lines[j]
            next_stripped = next_line.strip()
            if re.match(r"#?\s*\[Peer\]", next_stripped, re.IGNORECASE):
                break
            # stop if this is a comment directly before the next peer header
            if next_stripped.startswith("#"):
                if j + 1 < len(lines) and re.match(r"#?\s*\[Peer\]", lines[j + 1].strip(), re.IGNORECASE):
                    break
            block.append(next_line)
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
            # also skip preceding comments/blank lines directly above this block
            while out and (out[-1].strip().startswith("#") or out[-1].strip() == ""):
                out.pop()
            i = j
            out.append("")
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

rm -f "${CLIENT_DIR}/${IDENTIFIER}.conf" "${PUBLIC_CONF_DIR}/${IDENTIFIER}.conf" \
  "${WG_DIR}/${IDENTIFIER}_privatekey" "${WG_DIR}/${IDENTIFIER}_publickey" \
  "${QR_DIR}/${IDENTIFIER}.png"

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

log "deleted id=${IDENTIFIER}"

cat <<EOF
{
  "status": "ok",
  "id": "$IDENTIFIER"
}
EOF
