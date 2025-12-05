#!/usr/bin/env bash
set -euo pipefail

WG_CONFIG_PATH="${WG_CONFIG_PATH:-/etc/wireguard/wg1.conf}"
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
  exit 1
fi

tmp=$(mktemp)
python - "$IDENTIFIER" "$WG_CONFIG_PATH" "$tmp" <<'PY'
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
        if identifier in block_text or (normalized_name and identifier == normalized_name):
            i = j
            continue
        out.extend(block)
        i = j
        continue
    out.append(line)
    i += 1

pathlib.Path(tmp_path).write_text("\n".join(out) + "\n")
PY
mv "$tmp" "$WG_CONFIG_PATH"

rm -f "${CLIENT_DIR}/${IDENTIFIER}.conf" "${PUBLIC_CONF_DIR}/${IDENTIFIER}.conf" \
  "${WG_DIR}/${IDENTIFIER}_privatekey" "${WG_DIR}/${IDENTIFIER}_publickey" \
  "${QR_DIR}/${IDENTIFIER}.png"

systemctl restart "wg-quick@${WG_INTERFACE:-wg0}.service" >/dev/null 2>&1 || true

cat <<EOF
{
  "status": "ok",
  "id": "$IDENTIFIER"
}
EOF
