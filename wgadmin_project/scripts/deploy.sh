#!/usr/bin/env bash
#
# deploy.sh - Deploy or update the WireGuard Admin Django application
#
# This script deploys/updates the Django application after the initial setup.
# It can be run by a non-root user who is a member of the wgadmin group.
#
# Usage: ./deploy.sh [--skip-migrate] [--skip-static] [--restart]
#
set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly LOG_FILE="${LOG_FILE:-${SCRIPT_DIR}/deploy.log}"

# Paths - customize these for your setup
VENV_PATH="${VENV_PATH:-${PROJECT_ROOT}/.venv}"
DJANGO_PROJECT="${DJANGO_PROJECT:-${PROJECT_ROOT}}"
REQUIREMENTS_FILE="${REQUIREMENTS_FILE:-${PROJECT_ROOT}/../requirements.txt}"
GUNICORN_SERVICE="${GUNICORN_SERVICE:-wgadmin}"

# Options
SKIP_MIGRATE=false
SKIP_STATIC=false
RESTART_SERVICES=false
UPDATE_DEPS=false

# ============================================================================
# LOGGING
# ============================================================================
log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date +'%Y-%m-%d %H:%M:%S%z')"
    echo "${timestamp} [deploy] [${level}] ${msg}" | tee -a "$LOG_FILE"
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
    --skip-migrate      Skip database migrations
    --skip-static       Skip collectstatic
    --restart           Restart gunicorn and nginx after deployment
    --update-deps       Update Python dependencies from requirements.txt
    --venv PATH         Path to virtual environment (default: ${VENV_PATH})
    --help              Show this help message

Environment variables:
    VENV_PATH           Same as --venv
    DJANGO_PROJECT      Path to Django project directory
    GUNICORN_SERVICE    Systemd service name for gunicorn

Example:
    $0 --restart --update-deps
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skip-migrate)
                SKIP_MIGRATE=true
                shift
                ;;
            --skip-static)
                SKIP_STATIC=true
                shift
                ;;
            --restart)
                RESTART_SERVICES=true
                shift
                ;;
            --update-deps)
                UPDATE_DEPS=true
                shift
                ;;
            --venv)
                VENV_PATH="$2"
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

check_venv() {
    if [[ ! -d "${VENV_PATH}" ]]; then
        log_info "Virtual environment not found, creating: ${VENV_PATH}"
        python3 -m venv "${VENV_PATH}"
        log_info "Virtual environment created."
    fi
}

activate_venv() {
    # shellcheck source=/dev/null
    source "${VENV_PATH}/bin/activate"
    log_info "Activated virtual environment: ${VENV_PATH}"
}

update_dependencies() {
    if [[ "${UPDATE_DEPS}" == "true" ]]; then
        log_info "Updating Python dependencies..."
        if [[ -f "${REQUIREMENTS_FILE}" ]]; then
            pip install --upgrade pip -q
            pip install -r "${REQUIREMENTS_FILE}" -q
            log_info "Dependencies updated from ${REQUIREMENTS_FILE}"
        else
            log_warn "Requirements file not found: ${REQUIREMENTS_FILE}"
        fi
    fi
}

run_migrations() {
    if [[ "${SKIP_MIGRATE}" == "false" ]]; then
        log_info "Running database migrations..."
        cd "${DJANGO_PROJECT}"
        python manage.py migrate --noinput
        log_info "Migrations completed."
    else
        log_info "Skipping migrations (--skip-migrate)"
    fi
}

collect_static() {
    if [[ "${SKIP_STATIC}" == "false" ]]; then
        log_info "Collecting static files..."
        cd "${DJANGO_PROJECT}"
        python manage.py collectstatic --noinput --clear
        log_info "Static files collected."
    else
        log_info "Skipping collectstatic (--skip-static)"
    fi
}

restart_services() {
    if [[ "${RESTART_SERVICES}" == "true" ]]; then
        log_info "Restarting services..."
        
        # Restart gunicorn
        if systemctl is-active --quiet "${GUNICORN_SERVICE}.service" 2>/dev/null; then
            sudo systemctl restart "${GUNICORN_SERVICE}.service"
            log_info "Restarted ${GUNICORN_SERVICE} service."
        elif systemctl list-unit-files | grep -q "${GUNICORN_SERVICE}.service"; then
            sudo systemctl start "${GUNICORN_SERVICE}.service"
            log_info "Started ${GUNICORN_SERVICE} service."
        else
            log_warn "Service ${GUNICORN_SERVICE}.service not found. Skip service restart."
        fi
        
        # Reload nginx
        if systemctl is-active --quiet nginx.service 2>/dev/null; then
            sudo systemctl reload nginx.service
            log_info "Reloaded nginx."
        fi
    else
        log_info "Not restarting services (use --restart to restart)"
    fi
}

check_config() {
    log_info "Running Django configuration check..."
    cd "${DJANGO_PROJECT}"
    python manage.py check --deploy 2>&1 | while read -r line; do
        if [[ "$line" == *"WARNINGS"* ]] || [[ "$line" == *"WARNING"* ]]; then
            log_warn "$line"
        else
            echo "$line"
        fi
    done
    log_info "Configuration check completed."
}

# ============================================================================
# MAIN
# ============================================================================
main() {
    parse_args "$@"

    echo "========================================"
    echo " WireGuard Admin - Deployment"
    echo "========================================"
    echo ""

    log_info "Starting deployment..."
    log_info "Project root: ${DJANGO_PROJECT}"

    check_venv
    activate_venv
    update_dependencies
    run_migrations
    collect_static
    check_config
    restart_services

    log_info "Deployment completed successfully."

    cat <<EOF

================================================================================
Deployment completed!

Actions performed:
  - Virtual environment: ${VENV_PATH}
  - Dependencies: $([ "${UPDATE_DEPS}" == "true" ] && echo "Updated" || echo "Skipped")
  - Migrations: $([ "${SKIP_MIGRATE}" == "false" ] && echo "Applied" || echo "Skipped")
  - Static files: $([ "${SKIP_STATIC}" == "false" ] && echo "Collected" || echo "Skipped")
  - Services: $([ "${RESTART_SERVICES}" == "true" ] && echo "Restarted" || echo "Not restarted")

Log file: ${LOG_FILE}
================================================================================
EOF
}

main "$@"