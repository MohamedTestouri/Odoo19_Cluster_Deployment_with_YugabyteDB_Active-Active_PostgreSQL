#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Shared utilities for all cluster setup scripts
# Source this file at the top of every script:
#   source "$(dirname "$0")/lib/common.sh"
# =============================================================================

# ── Colors & Formatting ───────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Logging ───────────────────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "${BASH_SOURCE[1]}" .sh)"
LOG_FILE="${LOG_FILE:-/tmp/cluster-setup-${SCRIPT_NAME}.log}"

log_info()    { echo -e "${GREEN}[INFO]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2; }
log_section() { echo -e "\n${BOLD}${BLUE}═══ $* ═══${NC}" | tee -a "$LOG_FILE"; }
log_ok()      { echo -e "${GREEN}[✔]${NC} $*" | tee -a "$LOG_FILE"; }
log_fail()    { echo -e "${RED}[✘]${NC} $*" | tee -a "$LOG_FILE"; }
log_step()    { echo -e "${CYAN}[STEP]${NC} $*" | tee -a "$LOG_FILE"; }

# ── Error Handling ────────────────────────────────────────────────────────────
set -Eeuo pipefail

die() {
    log_error "$*"
    exit 1
}

trap_error() {
    log_error "Script failed at line ${BASH_LINENO[0]}: ${BASH_COMMAND}"
    exit 1
}
trap trap_error ERR

# ── .env Loader ───────────────────────────────────────────────────────────────
load_env() {
    local env_file="${1:-.env}"
    # Look for .env relative to the calling script's directory
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"

    if [[ -f "${script_dir}/${env_file}" ]]; then
        env_file="${script_dir}/${env_file}"
    elif [[ -f "${env_file}" ]]; then
        : # use as-is
    else
        die ".env file not found. Copy .env.example to .env and configure it."
    fi

    log_info "Loading configuration from: ${env_file}"
    # Export all variables, skip comments and blank lines
    set -o allexport
    # shellcheck disable=SC1090
    source "${env_file}"
    set +o allexport
}

# ── Privilege Check ───────────────────────────────────────────────────────────
require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (use sudo)."
    fi
}

require_not_root() {
    if [[ $EUID -eq 0 ]]; then
        die "This script must NOT be run as root."
    fi
}

# ── OS Check ──────────────────────────────────────────────────────────────────
require_ubuntu() {
    if ! grep -qi ubuntu /etc/os-release 2>/dev/null; then
        die "This script requires Ubuntu. Detected: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2)"
    fi
    log_ok "OS check passed: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
}

# ── Package Management ────────────────────────────────────────────────────────
apt_install() {
    log_step "Installing packages: $*"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@" \
        >> "$LOG_FILE" 2>&1 || die "Failed to install: $*"
    log_ok "Installed: $*"
}

apt_update() {
    log_step "Updating apt cache..."
    apt-get update -qq >> "$LOG_FILE" 2>&1
    log_ok "apt cache updated"
}

# ── Service Management ────────────────────────────────────────────────────────
service_enable_start() {
    local svc="$1"
    systemctl daemon-reload >> "$LOG_FILE" 2>&1
    systemctl enable "$svc" >> "$LOG_FILE" 2>&1
    systemctl start "$svc" >> "$LOG_FILE" 2>&1
    systemctl is-active --quiet "$svc" \
        && log_ok "Service '${svc}' is running" \
        || die "Service '${svc}' failed to start"
}

service_restart() {
    local svc="$1"
    systemctl restart "$svc" >> "$LOG_FILE" 2>&1
    systemctl is-active --quiet "$svc" \
        && log_ok "Service '${svc}' restarted" \
        || die "Service '${svc}' failed to restart"
}

service_reload() {
    local svc="$1"
    systemctl reload "$svc" >> "$LOG_FILE" 2>&1 || service_restart "$svc"
    log_ok "Service '${svc}' reloaded"
}

# ── Network Utilities ─────────────────────────────────────────────────────────
wait_for_port() {
    local host="$1" port="$2" retries="${3:-30}" delay="${4:-3}"
    log_step "Waiting for ${host}:${port} to be ready..."
    for ((i=1; i<=retries; i++)); do
        if nc -z -w3 "$host" "$port" 2>/dev/null; then
            log_ok "${host}:${port} is reachable"
            return 0
        fi
        echo -n "." && sleep "$delay"
    done
    die "Timeout waiting for ${host}:${port} after $((retries * delay))s"
}

check_port_open() {
    local host="$1" port="$2"
    nc -z -w3 "$host" "$port" 2>/dev/null && return 0 || return 1
}

# ── String Utilities ──────────────────────────────────────────────────────────
confirm() {
    local msg="${1:-Continue?}"
    read -r -p "${YELLOW}${msg} [y/N]${NC} " response
    [[ "$response" =~ ^[Yy]$ ]] || { log_warn "Aborted by user."; exit 0; }
}

# ── File Utilities ────────────────────────────────────────────────────────────
backup_file() {
    local file="$1"
    if [[ -f "$file" ]]; then
        cp "$file" "${file}.bak.$(date +%Y%m%d_%H%M%S)"
        log_info "Backed up: ${file}"
    fi
}

render_template() {
    # Usage: render_template template_string > output_file
    # Expands all $VARIABLE references from env
    eval "cat <<EOF
$1
EOF"
}

# ── Summary Reporter ──────────────────────────────────────────────────────────
print_summary() {
    local title="$1"; shift
    echo -e "\n${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${GREEN}║  ✔  ${title}${NC}"
    echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
    for line in "$@"; do
        echo -e "  ${CYAN}→${NC} ${line}"
    done
    echo ""
}
