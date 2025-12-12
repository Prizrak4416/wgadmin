#!/usr/bin/env bash
#
# wg_first_start.sh - Initial provisioning script for WireGuard Admin on Debian 12/13
#
# This script prepares the system for running the Django WireGuard Admin application.
# It should be run ONCE on a fresh Debian 12 or Debian 13 server with root privileges.
#
# Usage: sudo ./wg_first_start.sh [--user USERNAME] [--interface wg1]
#
# Prerequisites:
#   - Debian 12/13 fresh install
#   - Root or sudo access
#   - Internet connectivity for package installation
#
set -euo pipefail

# ============================================================================
# CONFIGURATION - Can be overridden via environment variables or CLI args
# ============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly LOG_FILE="${LOG_FILE:-/var/log/wgadmin_setup.log}"

# Defaults - can be overridden via CLI or environment
WG_USER="${WG_USER:-prizrak}"
WG_GROUP="${WG_GROUP:-wgadmin}"
WG_INTERFACE="${WG_INTERFACE:-wg1}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
WG_CLIENT_CONFIG_DIR="${WG_CLIENT_CONFIG_DIR:-/etc/wireguard/client}"
WG_PUBLIC_CONF_DIR="${WG_PUBLIC_CONF_DIR:-/var/www/wireguard/conf}"
WG_QR_DIR="${WG_QR_DIR:-/var/www/wireguard/qr}"
WG_ENDPOINT_PORT="${WG_ENDPOINT_PORT:-51830}"
# External interface used for NAT; auto-detected later if not set
WG_PUBLIC_INTERFACE="${WG_PUBLIC_INTERFACE:-}"

# Derived paths
WG_CONFIG_PATH="${WG_DIR}/${WG_INTERFACE}.conf"
SUDOERS_FILE="/etc/sudoers.d/wgadmin"
TEMP_DIR="${SCRIPT_DIR}/temp"

# ============================================================================
# LOGGING
# ============================================================================
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date +'%Y-%m-%d %H:%M:%S%z')"
    echo "${timestamp} [wg_first_start] [${level}] ${msg}" | tee -a "$LOG_FILE"
}

log_info()  { log "INFO" "$@"; }
log_warn()  { log "WARN" "$@"; }
log_error() { log "ERROR" "$@"; }

die() {
    log_error "$@"
    exit 1
}

# ============================================================================
# HELPERS
# ============================================================================
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
    --user USERNAME     User that runs the Django application (default: prizrak)
    --interface NAME    WireGuard interface name (default: wg1)
    --public-interface  External interface for NAT (auto-detected if omitted)
    --help              Show this help message

Environment variables:
    WG_USER             Same as --user
    WG_GROUP            System group for WireGuard access (default: wgadmin)
    WG_INTERFACE        Same as --interface
    WG_PUBLIC_INTERFACE External interface for NAT (auto-detected if not set)
    WG_DIR              WireGuard configuration directory (default: /etc/wireguard)
    WG_ENDPOINT_PORT    WireGuard listen port (default: 51830)

Example:
    sudo $0 --user www-data --interface wg1
EOF
}

check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root. Use: sudo $0"
    fi
}

check_debian() {
    if [[ ! -f /etc/debian_version ]]; then
        die "This script is designed for Debian/Ubuntu systems."
    fi
    local version major_version
    version=$(cat /etc/debian_version)
    major_version="${version%%.*}"
    log_info "Detected Debian version: ${version}"
    case "${major_version}" in
        12|13) ;;
        *) log_warn "Tested on Debian 12/13. You are running: ${version}" ;;
    esac
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

detect_public_interface() {
    local iface=""

    # Preferred: interface with default route
    iface=$(ip -4 route list default 2>/dev/null | awk 'NR==1 {print $5}')

    # Fallback: interface used to reach a well-known address
    if [[ -z "${iface}" ]]; then
        iface=$(ip route get 8.8.8.8 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}')
    fi

    # Final fallback: first UP non-loopback interface
    if [[ -z "${iface}" ]]; then
        iface=$(ip -o link show up 2>/dev/null | awk -F': ' '$2 !~ /^lo$/ {print $2; exit}')
    fi

    echo "${iface}"
}

set_public_interface() {
    if [[ -n "${WG_PUBLIC_INTERFACE}" ]]; then
        log_info "Using provided public interface: ${WG_PUBLIC_INTERFACE}"
        return
    fi

    local detected_iface
    detected_iface="$(detect_public_interface)"

    if [[ -n "${detected_iface}" ]]; then
        WG_PUBLIC_INTERFACE="${detected_iface}"
        log_info "Auto-detected public interface: ${WG_PUBLIC_INTERFACE}"
    else
        WG_PUBLIC_INTERFACE="eth0"
        log_warn "Could not auto-detect public interface. Defaulting to eth0; update ${WG_CONFIG_PATH} if needed."
    fi
}

# ============================================================================
# PARSE CLI ARGUMENTS
# ============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --user)
                WG_USER="$2"
                shift 2
                ;;
            --interface)
                WG_INTERFACE="$2"
                WG_CONFIG_PATH="${WG_DIR}/${WG_INTERFACE}.conf"
                shift 2
                ;;
            --public-interface)
                WG_PUBLIC_INTERFACE="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1. Use --help for usage."
                ;;
        esac
    done
}

# ============================================================================
# PACKAGE INSTALLATION
# ============================================================================
install_packages() {
    log_info "Updating package lists..."
    apt-get update -qq

    local packages=(
        wireguard
        wireguard-tools
        qrencode
        python3
        python3-pip
        python3-venv
        nginx
        git
        curl
        iptables
    )

    log_info "Installing required packages: ${packages[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${packages[@]}"

    log_info "Packages installed successfully."
}

# ============================================================================
# SYSTEM USER AND GROUP SETUP
# ============================================================================
setup_user_and_group() {
    log_info "Setting up group: ${WG_GROUP}"
    if ! getent group "${WG_GROUP}" >/dev/null 2>&1; then
        groupadd -r "${WG_GROUP}"
        log_info "Created system group: ${WG_GROUP}"
    else
        log_info "Group ${WG_GROUP} already exists."
    fi

    # Verify user exists
    if ! id "${WG_USER}" >/dev/null 2>&1; then
        die "User ${WG_USER} does not exist. Please create it first or specify a different user with --user"
    fi

    log_info "Adding user ${WG_USER} to group ${WG_GROUP}"
    usermod -aG "${WG_GROUP}" "${WG_USER}"
    log_info "User ${WG_USER} added to group ${WG_GROUP}. Re-login required for group membership to take effect."
}

# ============================================================================
# DIRECTORY STRUCTURE
# ============================================================================
setup_directories() {
    log_info "Creating directory structure..."

    local dirs=(
        "${WG_DIR}"
        "${WG_CLIENT_CONFIG_DIR}"
        "${WG_PUBLIC_CONF_DIR}"
        "${WG_QR_DIR}"
        "${TEMP_DIR}"
    )

    for dir in "${dirs[@]}"; do
        if [[ ! -d "${dir}" ]]; then
            mkdir -p "${dir}"
            log_info "Created directory: ${dir}"
        fi
    done

    # Create WireGuard config if it doesn't exist
    if [[ ! -f "${WG_CONFIG_PATH}" ]]; then
        log_info "Creating initial WireGuard config: ${WG_CONFIG_PATH}"
        
        # Generate server keys
        local server_private_key server_public_key
        server_private_key=$(wg genkey)
        server_public_key=$(echo "${server_private_key}" | wg pubkey)
        
        # Get server IP
        local server_ip
        server_ip=$(ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)
        
        cat > "${WG_CONFIG_PATH}" <<EOF
# WireGuard Server Configuration
# Generated by wg_first_start.sh on $(date +'%Y-%m-%d %H:%M:%S')

[Interface]
PrivateKey = ${server_private_key}
Address = 10.0.0.1/24
ListenPort = ${WG_ENDPOINT_PORT}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WG_PUBLIC_INTERFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WG_PUBLIC_INTERFACE} -j MASQUERADE

# Server Public Key: ${server_public_key}
# Endpoint: ${server_ip}:${WG_ENDPOINT_PORT}
EOF
        log_info "Generated WireGuard server configuration with new keys."
        log_warn "IMPORTANT: Verify PostUp/PostDown use the correct public interface (${WG_PUBLIC_INTERFACE})"
    else
        log_info "WireGuard config already exists: ${WG_CONFIG_PATH}"
    fi
}

# ============================================================================
# PERMISSIONS
# ============================================================================
setup_permissions() {
    log_info "Setting ownership and permissions..."

    # WireGuard main directory - root owns, wgadmin group can read
    chown root:"${WG_GROUP}" "${WG_DIR}"
    chmod 750 "${WG_DIR}"

    # WireGuard main config - sensitive, group readable
    chown root:"${WG_GROUP}" "${WG_CONFIG_PATH}"
    chmod 640 "${WG_CONFIG_PATH}"

    # Client config directory - group writable for creating configs
    chown root:"${WG_GROUP}" "${WG_CLIENT_CONFIG_DIR}"
    chmod 770 "${WG_CLIENT_CONFIG_DIR}"
    find "${WG_CLIENT_CONFIG_DIR}" -type f -exec chmod 660 {} + 2>/dev/null || true
    find "${WG_CLIENT_CONFIG_DIR}" -type f -exec chown root:"${WG_GROUP}" {} + 2>/dev/null || true

    # Public conf directory - for downloadable configs
    chown -R root:"${WG_GROUP}" "${WG_PUBLIC_CONF_DIR}"
    chmod 770 "${WG_PUBLIC_CONF_DIR}"
    find "${WG_PUBLIC_CONF_DIR}" -type f -exec chmod 660 {} + 2>/dev/null || true

    # QR directory
    chown -R root:"${WG_GROUP}" "${WG_QR_DIR}"
    chmod 770 "${WG_QR_DIR}"
    find "${WG_QR_DIR}" -type f -exec chmod 660 {} + 2>/dev/null || true

    # Temp directory
    chown root:"${WG_GROUP}" "${TEMP_DIR}"
    chmod 770 "${TEMP_DIR}"

    # Scripts directory permissions
    if [[ -d "${SCRIPT_DIR}" ]]; then
        chown root:"${WG_GROUP}" "${SCRIPT_DIR}"
        chmod 750 "${SCRIPT_DIR}"
        
        # Individual scripts - executable by group
        for script in "${SCRIPT_DIR}"/*.sh; do
            if [[ -f "${script}" ]]; then
                chown root:"${WG_GROUP}" "${script}"
                chmod 750 "${script}"
            fi
        done
    fi

    log_info "Permissions configured successfully."
}

# ============================================================================
# SUDOERS CONFIGURATION
# ============================================================================
setup_sudoers() {
    log_info "Configuring sudoers for passwordless WireGuard management..."

    # Backup existing sudoers if present
    if [[ -f "${SUDOERS_FILE}" ]]; then
        cp "${SUDOERS_FILE}" "${SUDOERS_FILE}.bak.$(date +%s)"
        log_info "Backed up existing sudoers file."
    fi

    # Create new sudoers file
    cat > "${SUDOERS_FILE}" <<EOF
# Sudoers rules for WireGuard Admin
# Generated by wg_first_start.sh on $(date +'%Y-%m-%d %H:%M:%S')
# DO NOT EDIT MANUALLY - changes may be overwritten

# Allow wgadmin group to restart WireGuard service
%${WG_GROUP} ALL=(root) NOPASSWD: /bin/systemctl restart wg-quick@${WG_INTERFACE}.service
%${WG_GROUP} ALL=(root) NOPASSWD: /bin/systemctl start wg-quick@${WG_INTERFACE}.service
%${WG_GROUP} ALL=(root) NOPASSWD: /bin/systemctl stop wg-quick@${WG_INTERFACE}.service
%${WG_GROUP} ALL=(root) NOPASSWD: /bin/systemctl status wg-quick@${WG_INTERFACE}.service

# Allow reading WireGuard interface status
%${WG_GROUP} ALL=(root) NOPASSWD: /usr/bin/wg show ${WG_INTERFACE} *

# Allow running management scripts
%${WG_GROUP} ALL=(root) NOPASSWD: ${SCRIPT_DIR}/wg_read_config.sh
%${WG_GROUP} ALL=(root) NOPASSWD: ${SCRIPT_DIR}/wg_create_peer.sh *
%${WG_GROUP} ALL=(root) NOPASSWD: ${SCRIPT_DIR}/wg_delete_peer.sh *
%${WG_GROUP} ALL=(root) NOPASSWD: ${SCRIPT_DIR}/wg_toggle_peer.sh *
%${WG_GROUP} ALL=(root) NOPASSWD: ${SCRIPT_DIR}/wg_generate_qr.sh *

# Allow specific mv operations for config updates (temp dir only)
%${WG_GROUP} ALL=(root) NOPASSWD: /bin/mv ${TEMP_DIR}/* ${WG_CONFIG_PATH}
EOF

    # Validate sudoers file syntax
    if ! visudo -cf "${SUDOERS_FILE}"; then
        die "Sudoers file validation failed! Check ${SUDOERS_FILE}"
    fi

    # Set proper permissions on sudoers file
    chmod 440 "${SUDOERS_FILE}"
    chown root:root "${SUDOERS_FILE}"

    log_info "Sudoers configured successfully: ${SUDOERS_FILE}"
}

# ============================================================================
# WIREGUARD SERVICE
# ============================================================================
setup_wireguard_service() {
    log_info "Enabling IP forwarding..."
    
    # Enable IP forwarding permanently
    if ! grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        log_info "Added net.ipv4.ip_forward=1 to /etc/sysctl.conf"
    fi
    
    # Apply immediately
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    log_info "Enabling and starting WireGuard service..."
    systemctl enable "wg-quick@${WG_INTERFACE}.service"
    
    if systemctl is-active --quiet "wg-quick@${WG_INTERFACE}.service"; then
        log_info "WireGuard service is already running."
    else
        systemctl start "wg-quick@${WG_INTERFACE}.service" || {
            log_warn "Could not start WireGuard service. Check config and try: systemctl start wg-quick@${WG_INTERFACE}"
        }
    fi
}

# ============================================================================
# FIREWALL SETUP
# ============================================================================
setup_firewall() {
    log_info "Configuring firewall rules..."
    
    # Check if ufw is installed and active
    if command_exists ufw && ufw status | grep -q "Status: active"; then
        log_info "UFW detected, adding rules..."
        ufw allow "${WG_ENDPOINT_PORT}/udp" comment "WireGuard"
        ufw allow 22/tcp comment "SSH"
        ufw allow 80/tcp comment "HTTP"
        ufw allow 443/tcp comment "HTTPS"
        log_info "UFW rules added."
    else
        log_info "UFW not active. Ensure your firewall allows:"
        log_info "  - UDP ${WG_ENDPOINT_PORT} (WireGuard)"
        log_info "  - TCP 22 (SSH)"
        log_info "  - TCP 80, 443 (HTTP/HTTPS)"
    fi
}

# ============================================================================
# SUMMARY
# ============================================================================
print_summary() {
    local server_ip
    server_ip=$(ip -4 addr show scope global | awk '/inet / {print $2}' | cut -d/ -f1 | head -1)

    cat <<EOF

================================================================================
                     WireGuard Admin Setup Complete
================================================================================

Configuration Summary:
  - User: ${WG_USER}
  - Group: ${WG_GROUP}
  - Interface: ${WG_INTERFACE}
  - Public interface (NAT): ${WG_PUBLIC_INTERFACE}
  - Config file: ${WG_CONFIG_PATH}
  - Client configs: ${WG_CLIENT_CONFIG_DIR}
  - Public configs: ${WG_PUBLIC_CONF_DIR}
  - QR codes: ${WG_QR_DIR}
  - Scripts: ${SCRIPT_DIR}
  - Sudoers: ${SUDOERS_FILE}
  - Log file: ${LOG_FILE}

Server Information:
  - IP: ${server_ip}
  - WireGuard Port: ${WG_ENDPOINT_PORT}/udp

Next Steps:
  1. If user ${WG_USER} was just added to group ${WG_GROUP}, start a new session (log out/in or run: newgrp ${WG_GROUP}).
  2. Deploy the Django application (see README.md for instructions).
  3. Configure nginx as reverse proxy.
  4. Set environment variables for Django (.env file or systemd).
  5. Test WireGuard: wg show ${WG_INTERFACE}

IMPORTANT NOTES:
  - Review and edit ${WG_CONFIG_PATH} if the detected public interface (${WG_PUBLIC_INTERFACE}) is not correct.
  - Ensure firewall allows UDP port ${WG_ENDPOINT_PORT}.
  - The re-login is required for group membership to take effect.

================================================================================
EOF
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    parse_args "$@"

    echo "========================================"
    echo " WireGuard Admin - Initial Setup"
    echo "========================================"
    echo ""

    check_root
    check_debian

    set_public_interface

    log_info "Starting WireGuard Admin setup..."
    log_info "User: ${WG_USER}, Interface: ${WG_INTERFACE}, Public interface: ${WG_PUBLIC_INTERFACE}"

    install_packages
    setup_user_and_group
    setup_directories
    setup_permissions
    setup_sudoers
    setup_wireguard_service
    setup_firewall
    print_summary

    log_info "Setup completed successfully."
}

main "$@"
