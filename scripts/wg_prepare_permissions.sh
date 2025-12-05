#!/usr/bin/env bash
# Prepare WireGuard permissions and directories.
# Creates a group, adds a user, ensures directories exist, and sets safe perms.
set -euo pipefail

WG_GROUP="${WG_GROUP:-wgadmin}"
WG_USER="${WG_USER:-$(whoami)}"
WG_CONFIG_PATH="${WG_CONFIG_PATH:-/etc/wireguard/wg0.conf}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
WG_CLIENT_CONFIG_DIR="${WG_CLIENT_CONFIG_DIR:-/etc/wireguard/client}"
WG_PUBLIC_CONF_DIR="${WG_PUBLIC_CONF_DIR:-/var/www/wireguard/conf}"
WG_QR_DIR="${WG_QR_DIR:-/var/www/wireguard/qr}"

echo "[*] Using group: ${WG_GROUP}"
if ! getent group "$WG_GROUP" >/dev/null; then
  echo "[*] Creating group $WG_GROUP"
  sudo groupadd -r "$WG_GROUP"
fi

echo "[*] Adding user ${WG_USER} to ${WG_GROUP}"
sudo usermod -aG "$WG_GROUP" "$WG_USER"

echo "[*] Ensuring directories exist"
sudo mkdir -p "$WG_DIR" "$WG_CLIENT_CONFIG_DIR" "$WG_PUBLIC_CONF_DIR" "$WG_QR_DIR"

if [[ ! -f "$WG_CONFIG_PATH" ]]; then
  echo "[*] Creating empty config file at $WG_CONFIG_PATH"
  sudo touch "$WG_CONFIG_PATH"
fi

echo "[*] Setting ownership to group ${WG_GROUP}"
sudo chgrp "$WG_GROUP" "$WG_DIR" "$WG_CONFIG_PATH"
sudo chgrp -R "$WG_GROUP" "$WG_CLIENT_CONFIG_DIR" "$WG_PUBLIC_CONF_DIR" "$WG_QR_DIR"

echo "[*] Setting permissions (directories 750, files 660)"
sudo chmod 750 "$WG_DIR"
sudo chmod 660 "$WG_CONFIG_PATH"
sudo find "$WG_CLIENT_CONFIG_DIR" -type d -exec chmod 770 {} +
sudo find "$WG_CLIENT_CONFIG_DIR" -type f -exec chmod 660 {} + || true
sudo find "$WG_PUBLIC_CONF_DIR" -type d -exec chmod 770 {} +
sudo find "$WG_PUBLIC_CONF_DIR" -type f -exec chmod 660 {} + || true
sudo find "$WG_QR_DIR" -type d -exec chmod 770 {} +
sudo find "$WG_QR_DIR" -type f -exec chmod 660 {} + || true

cat <<EOF
Done.
- Group: $WG_GROUP
- User: $WG_USER (re-login required to apply group membership)
- Config: $WG_CONFIG_PATH
- Client dir: $WG_CLIENT_CONFIG_DIR
- Public conf dir: $WG_PUBLIC_CONF_DIR
- QR dir: $WG_QR_DIR
EOF
