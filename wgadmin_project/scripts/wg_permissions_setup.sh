#!/usr/bin/env bash
#
# wg_permissions_setup.sh - Configure permissions for existing WireGuard installation
#
# Use this script when WireGuard is already installed and configured.
# It only sets up groups, users, permissions, and sudoers for Django admin access.
#
# Usage: sudo ./wg_permissions_setup.sh
#
set -euo pipefail

# ============================================================================
# CONFIGURATION - EDIT THESE VALUES BEFORE RUNNING
# ============================================================================

# User that will run the Django application
WG_USER="www-admin"

# System group for WireGuard access
WG_GROUP="wgadmin"

# WireGuard interface name
WG_INTERFACE="wg0"

# ============================================================================
# PATHS
# ============================================================================

WG_DIR="/etc/wireguard"
WG_CONFIG_PATH="${WG_DIR}/${WG_INTERFACE}.conf"
WG_CLIENT_CONFIG_DIR="/etc/wireguard/client"
WG_PUBLIC_CONF_DIR="/var/www/wireguard/conf"
WG_QR_DIR="/var/www/wireguard/qr"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUDOERS_FILE="/etc/sudoers.d/wgadmin"
TEMP_DIR="${SCRIPT_DIR}/temp"

# ============================================================================
# HELPERS
# ============================================================================

log() { echo "[$(date +'%H:%M:%S')] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

check_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run as root: sudo $0"
}

# ============================================================================
# SETUP FUNCTIONS
# ============================================================================

setup_group() {
    log "Setting up group: ${WG_GROUP}"
    if ! getent group "${WG_GROUP}" >/dev/null 2>&1; then
        groupadd -r "${WG_GROUP}"
        log "Created group: ${WG_GROUP}"
    else
        log "Group ${WG_GROUP} already exists"
    fi

    id "${WG_USER}" >/dev/null 2>&1 || die "User ${WG_USER} does not exist"
    usermod -aG "${WG_GROUP}" "${WG_USER}"
    log "Added ${WG_USER} to ${WG_GROUP}"
}

setup_directories() {
    log "Creating directories..."
    mkdir -p "${WG_CLIENT_CONFIG_DIR}" "${WG_PUBLIC_CONF_DIR}" "${WG_QR_DIR}" "${TEMP_DIR}"
}

setup_permissions() {
    log "Setting permissions..."

    # WireGuard directory
    [[ -d "${WG_DIR}" ]] || die "WireGuard dir not found: ${WG_DIR}"
    chown root:"${WG_GROUP}" "${WG_DIR}"
    chmod 750 "${WG_DIR}"

    # Main config file
    if [[ -f "${WG_CONFIG_PATH}" ]]; then
        chown root:"${WG_GROUP}" "${WG_CONFIG_PATH}"
        chmod 640 "${WG_CONFIG_PATH}"
    else
        log "Warning: ${WG_CONFIG_PATH} not found"
    fi

    # Client directories
    chown root:"${WG_GROUP}" "${WG_CLIENT_CONFIG_DIR}"
    chmod 770 "${WG_CLIENT_CONFIG_DIR}"
    find "${WG_CLIENT_CONFIG_DIR}" -type f -exec chown root:"${WG_GROUP}" {} \; -exec chmod 660 {} \; 2>/dev/null || true

    # Public directories
    chown -R root:"${WG_GROUP}" "${WG_PUBLIC_CONF_DIR}" "${WG_QR_DIR}"
    chmod 770 "${WG_PUBLIC_CONF_DIR}" "${WG_QR_DIR}"
    find "${WG_PUBLIC_CONF_DIR}" -type f -exec chmod 660 {} \; 2>/dev/null || true
    find "${WG_QR_DIR}" -type f -exec chmod 660 {} \; 2>/dev/null || true

    # Temp and scripts
    chown root:"${WG_GROUP}" "${TEMP_DIR}"
    chmod 770 "${TEMP_DIR}"

    if [[ -d "${SCRIPT_DIR}" ]]; then
        chown root:"${WG_GROUP}" "${SCRIPT_DIR}"
        chmod 750 "${SCRIPT_DIR}"
        for script in "${SCRIPT_DIR}"/*.sh; do
            [[ -f "${script}" ]] && chown root:"${WG_GROUP}" "${script}" && chmod 750 "${script}"
        done
    fi

    log "Permissions set"
}

setup_sudoers() {
    log "Configuring sudoers..."

    cat > "${SUDOERS_FILE}" <<EOF
# WireGuard Admin sudoers - $(date +'%Y-%m-%d %H:%M:%S')
%${WG_GROUP} ALL=(root) NOPASSWD: /bin/systemctl restart wg-quick@${WG_INTERFACE}.service
%${WG_GROUP} ALL=(root) NOPASSWD: /bin/systemctl start wg-quick@${WG_INTERFACE}.service
%${WG_GROUP} ALL=(root) NOPASSWD: /bin/systemctl stop wg-quick@${WG_INTERFACE}.service
%${WG_GROUP} ALL=(root) NOPASSWD: /bin/systemctl status wg-quick@${WG_INTERFACE}.service
%${WG_GROUP} ALL=(root) NOPASSWD: /usr/bin/wg show ${WG_INTERFACE} *
%${WG_GROUP} ALL=(root) NOPASSWD: ${SCRIPT_DIR}/wg_read_config.sh
%${WG_GROUP} ALL=(root) NOPASSWD: ${SCRIPT_DIR}/wg_create_peer.sh *
%${WG_GROUP} ALL=(root) NOPASSWD: ${SCRIPT_DIR}/wg_delete_peer.sh *
%${WG_GROUP} ALL=(root) NOPASSWD: ${SCRIPT_DIR}/wg_toggle_peer.sh *
%${WG_GROUP} ALL=(root) NOPASSWD: ${SCRIPT_DIR}/wg_generate_qr.sh *
%${WG_GROUP} ALL=(root) NOPASSWD: /bin/mv ${TEMP_DIR}/* ${WG_CONFIG_PATH}
EOF

    visudo -cf "${SUDOERS_FILE}" || die "Sudoers validation failed"
    chmod 440 "${SUDOERS_FILE}"
    chown root:root "${SUDOERS_FILE}"
    log "Sudoers configured: ${SUDOERS_FILE}"
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    echo "=== WireGuard Permissions Setup ==="
    echo "User: ${WG_USER}, Group: ${WG_GROUP}, Interface: ${WG_INTERFACE}"
    echo ""

    check_root
    setup_group
    setup_directories
    setup_permissions
    setup_sudoers

    echo ""
    echo "=== Done ==="
    echo "Re-login as ${WG_USER} for group membership to take effect."
}

main
