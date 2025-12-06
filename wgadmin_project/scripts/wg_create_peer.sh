#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/log.txt}"
log() { echo "$(date +'%Y-%m-%d %H:%M:%S%z') [wg_create_peer] $*" >> "$LOG_FILE"; }

WG_CONFIG_PATH="${WG_CONFIG_PATH:-/etc/wireguard/wg1.conf}"
WG_INTERFACE="${WG_INTERFACE:-wg0}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
CLIENT_DIR="${WG_CLIENT_CONFIG_DIR:-/etc/wireguard/client}"
PUBLIC_CONF_DIR="${WG_PUBLIC_CONF_DIR:-/var/www/wireguard/conf}"
QR_DIR="${WG_QR_DIR:-/var/www/wireguard/qr}"
SERVER_WG_IPV4_PREFIX="${SERVER_WG_IPV4_PREFIX:-10.0.0.}"
ENDPOINT_PORT="${WG_ENDPOINT_PORT:-51830}"
DNS="${WG_DNS:-1.1.1.1}"

NAME=""
ALLOWED_IPS="0.0.0.0/0"

usage() {
  cat <<EOF
Usage: $0 --name <client-name> [--allowed-ips <ips>]
Environment:
  WG_CONFIG_PATH      Path to wg1.conf (default /etc/wireguard/wg1.conf)
  WG_CLIENT_CONFIG_DIR  Path to store client configs (default /etc/wireguard/client)
  WG_PUBLIC_CONF_DIR    Public conf export dir (default /var/www/wireguard/conf)
  WG_QR_DIR             QR output dir (default /var/www/wireguard/qr)
  WG_ENDPOINT_PORT      WireGuard endpoint port (default 51830)
  WG_DNS                DNS value in generated config (default 1.1.1.1)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)
      NAME="$2"; shift 2;;
    --allowed-ips)
      ALLOWED_IPS="$2"; shift 2;;
    -h|--help)
      usage; exit 0;;
    *)
      echo "Unknown argument: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$NAME" ]]; then
  echo '{"status":"error","message":"--name is required"}'
  log "error: missing --name"
  exit 1
fi
log "start name=${NAME} allowed_ips=${ALLOWED_IPS} config=${WG_CONFIG_PATH}"

mkdir -p "$CLIENT_DIR" "$PUBLIC_CONF_DIR" "$QR_DIR"

if [[ -f "${WG_DIR}/${NAME}_privatekey" ]]; then
  echo "{\"status\":\"error\",\"message\":\"name already exists\"}"
  log "error: name ${NAME} already exists"
  exit 1
fi

SERVER_PUBLIC_KEY=$(wg show "$WG_INTERFACE" public-key 2>/dev/null || true)
if [[ -z "$SERVER_PUBLIC_KEY" ]]; then
  echo "{\"status\":\"error\",\"message\":\"cannot read server public key\"}"
  log "error: cannot read server public key for ${WG_INTERFACE}"
  exit 1
fi

CLIENT_PRIVATE_KEY=$(wg genkey)
CLIENT_PUBLIC_KEY=$(printf "%s" "$CLIENT_PRIVATE_KEY" | wg pubkey)

echo "$CLIENT_PRIVATE_KEY" > "${WG_DIR}/${NAME}_privatekey"
echo "$CLIENT_PUBLIC_KEY" > "${WG_DIR}/${NAME}_publickey"

find_available_ip() {
  for i in $(seq 2 254); do
    candidate="${SERVER_WG_IPV4_PREFIX}${i}"
    if ! grep -q "$candidate" "$WG_CONFIG_PATH"; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

CLIENT_IP=$(find_available_ip)
if [[ -z "$CLIENT_IP" ]]; then
  echo '{"status":"error","message":"no available IPs"}'
  log "error: no available IPs"
  exit 1
fi

SERVER_PUBLIC_ENDPOINT=${WG_ENDPOINT:-$(ip -4 addr | awk '/inet .* scope global/ {print $2}' | cut -d/ -f1 | head -1)}

cat <<EOL >> "$WG_CONFIG_PATH"

# Name: ${NAME}
[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${CLIENT_IP}/32
EOL

generate_client_config() {
cat <<EOL
[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${CLIENT_IP}/32
DNS = ${DNS}

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
Endpoint = ${SERVER_PUBLIC_ENDPOINT}:${ENDPOINT_PORT}
AllowedIPs = ${ALLOWED_IPS}
PersistentKeepalive = 20
EOL
}

CLIENT_CONF_PATH="${CLIENT_DIR}/${NAME}.conf"
PUBLIC_CONF_PATH="${PUBLIC_CONF_DIR}/${NAME}.conf"

generate_client_config > "$CLIENT_CONF_PATH"
generate_client_config > "$PUBLIC_CONF_PATH"

if command -v qrencode >/dev/null 2>&1; then
  qrencode -t PNG -o "${QR_DIR}/${NAME}.png" < "$PUBLIC_CONF_PATH"
fi

systemctl restart "wg-quick@${WG_INTERFACE}.service" >/dev/null 2>&1 || true

log "created peer name=${NAME} ip=${CLIENT_IP}/32 allowed_ips=${ALLOWED_IPS} config=${WG_CONFIG_PATH}"
cat <<EOF
{
  "status": "ok",
  "name": "$NAME",
  "public_key": "$CLIENT_PUBLIC_KEY",
  "config_path": "$CLIENT_CONF_PATH",
  "public_config_path": "$PUBLIC_CONF_PATH",
  "qr_path": "${QR_DIR}/${NAME}.png",
  "allowed_ips": "$ALLOWED_IPS",
  "address": "${CLIENT_IP}/32"
}
EOF
