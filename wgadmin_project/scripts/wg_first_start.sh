#!/usr/bin/env bash
# Prepare WireGuard permissions, sudoers, and script ownership.
# Run once as an administrator.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/log.txt}"
log() { echo "$(date +'%Y-%m-%d %H:%M:%S%z') [wg_first_start] $*" >> "$LOG_FILE"; }

WG_GROUP="wgadmin"
WG_USER="volma"           # change if another system user runs Django
WG_INTERFACE="wg1"
WG_CONFIG_PATH="/etc/wireguard/${WG_INTERFACE}.conf"
WG_DIR="/etc/wireguard"
WG_CLIENT_CONFIG_DIR="/etc/wireguard/client"
WG_PUBLIC_CONF_DIR="/var/www/wireguard/conf"
WG_QR_DIR="/var/www/wireguard/qr"
SCRIPTS_DIR="${SCRIPT_DIR}"
SUDOERS_FILE="/etc/sudoers.d/wgadmin"
TEMP_DIR="${SCRIPT_DIR}/temp"

echo "[*] Using group: ${WG_GROUP}"
if ! getent group "$WG_GROUP" >/dev/null; then
  echo "[*] Creating group $WG_GROUP"
  sudo groupadd -r "$WG_GROUP"
  log "group created: ${WG_GROUP}"
fi

echo "[*] Adding user ${WG_USER} to ${WG_GROUP}"
sudo usermod -aG "$WG_GROUP" "$WG_USER"
log "user ${WG_USER} added to group ${WG_GROUP}"

echo "[*] Ensuring directories exist"
sudo mkdir -p "$WG_DIR" "$WG_CLIENT_CONFIG_DIR" "$WG_PUBLIC_CONF_DIR" "$WG_QR_DIR"
log "ensured directories ${WG_DIR}, ${WG_CLIENT_CONFIG_DIR}, ${WG_PUBLIC_CONF_DIR}, ${WG_QR_DIR}"

if [[ ! -f "$WG_CONFIG_PATH" ]]; then
  echo "[*] Creating empty config file at $WG_CONFIG_PATH"
  sudo touch "$WG_CONFIG_PATH"
  log "created config file ${WG_CONFIG_PATH}"
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
log "permissions set for config and directories"

echo "[*] Preparing temp dir ${TEMP_DIR}"
mkdir -p "$TEMP_DIR"
sudo chown root:${WG_GROUP} "$TEMP_DIR"
sudo chmod 770 "$TEMP_DIR"
log "temp dir ready at ${TEMP_DIR}"

echo "[*] Setting scripts ownership to root:root and 750"
sudo chown root:${WG_GROUP} "${SCRIPTS_DIR}"/*.sh
sudo chmod 750 "${SCRIPTS_DIR}"/*.sh
sudo chown root:${WG_GROUP} "${SCRIPTS_DIR}/wg_toggle_peer.sh" "${SCRIPTS_DIR}/wg_delete_peer.sh"
sudo chmod 750 "${SCRIPTS_DIR}/wg_toggle_peer.sh" "${SCRIPTS_DIR}/wg_delete_peer.sh"
log "scripts secured in ${SCRIPTS_DIR}"

echo "[*] Updating sudoers in ${SUDOERS_FILE}"
WGCMDS=(
  "/usr/bin/wg show ${WG_INTERFACE} dump"
  "/bin/systemctl restart wg-quick@${WG_INTERFACE}.service"
  "/bin/mv"
  "${SCRIPTS_DIR}/wg_read_config.sh"
  "${SCRIPTS_DIR}/wg_create_peer.sh"
  "${SCRIPTS_DIR}/wg_delete_peer.sh"
  "${SCRIPTS_DIR}/wg_toggle_peer.sh"
  "${SCRIPTS_DIR}/wg_generate_qr.sh"
)

sudo touch "$SUDOERS_FILE"
for CMD in "${WGCMDS[@]}"; do
  LINE="%${WG_GROUP} ALL=(root) NOPASSWD: ${CMD}"
  if ! sudo grep -Fxq "$LINE" "$SUDOERS_FILE"; then
    echo "$LINE" | sudo tee -a "$SUDOERS_FILE" >/dev/null
    log "sudoers added: $LINE"
  fi
done
sudo visudo -cf "$SUDOERS_FILE"

cat <<EOF
Done.
- Group: $WG_GROUP
- User: $WG_USER (re-login required to apply group membership)
- Config: $WG_CONFIG_PATH
- Scripts dir: $SCRIPTS_DIR
- Sudoers file: $SUDOERS_FILE
EOF
