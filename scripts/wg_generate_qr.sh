#!/usr/bin/env bash
set -euo pipefail

WG_CLIENT_CONFIG_DIR="${WG_CLIENT_CONFIG_DIR:-/etc/wireguard/client}"
WG_PUBLIC_CONF_DIR="${WG_PUBLIC_CONF_DIR:-/var/www/wireguard/conf}"
WG_QR_DIR="${WG_QR_DIR:-/var/www/wireguard/qr}"

IDENTIFIER=""

usage() {
  echo "Usage: $0 --id <identifier>"
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

CONFIG_PATH="${WG_CLIENT_CONFIG_DIR}/${IDENTIFIER}.conf"
if [[ ! -f "$CONFIG_PATH" ]]; then
  CONFIG_PATH="${WG_PUBLIC_CONF_DIR}/${IDENTIFIER}.conf"
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo '{"status":"error","message":"config not found"}'
  exit 1
fi

mkdir -p "$WG_QR_DIR"
QR_PATH="${WG_QR_DIR}/${IDENTIFIER}.png"
if command -v qrencode >/dev/null 2>&1; then
  qrencode -t PNG -o "$QR_PATH" < "$CONFIG_PATH"
else
  echo '{"status":"error","message":"qrencode not installed"}'
  exit 1
fi

ENCODED=$(base64 -w0 "$QR_PATH")
cat <<EOF
{
  "status": "ok",
  "id": "$IDENTIFIER",
  "config_path": "$CONFIG_PATH",
  "qr_path": "$QR_PATH",
  "qr_base64": "data:image/png;base64,${ENCODED}"
}
EOF
