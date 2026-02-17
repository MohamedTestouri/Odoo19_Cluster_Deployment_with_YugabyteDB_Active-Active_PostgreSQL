#!/usr/bin/env bash
# =============================================================================
# 00-preflight.sh — Pre-flight checks for all nodes
# Run this FIRST on every node to verify the environment is ready.
# Usage: sudo bash 00-preflight.sh [--node-type=odoo|yugabyte|haproxy|redis|nfs]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env

LOG_FILE="/tmp/cluster-setup-preflight.log"

# ── Parse arguments ───────────────────────────────────────────────────────────
NODE_TYPE="${1/--node-type=/}"
NODE_TYPE="${NODE_TYPE:-all}"

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0

check_pass() { log_ok "$1";  ((PASS_COUNT++)); }
check_fail() { log_fail "$1"; ((FAIL_COUNT++)); }
check_warn() { log_warn "$1"; ((WARN_COUNT++)); }

# ── Checks ────────────────────────────────────────────────────────────────────
log_section "PRE-FLIGHT CHECKS (node-type: ${NODE_TYPE})"

# OS version
log_step "Checking OS..."
OS_NAME=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
if grep -qi "ubuntu 22\|ubuntu 24" /etc/os-release; then
    check_pass "OS: ${OS_NAME}"
else
    check_warn "OS: ${OS_NAME} — Ubuntu 22.04 or 24.04 recommended"
fi

# Root privileges
log_step "Checking privileges..."
if [[ $EUID -eq 0 ]]; then
    check_pass "Running as root"
else
    check_fail "Must run as root (use sudo)"
fi

# Architecture
log_step "Checking CPU architecture..."
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    check_pass "Architecture: ${ARCH}"
else
    check_fail "Architecture ${ARCH} not supported (requires x86_64)"
fi

# CPU count
log_step "Checking CPU..."
CPU_COUNT=$(nproc)
MIN_CPU=4
if [[ $CPU_COUNT -ge $MIN_CPU ]]; then
    check_pass "CPU cores: ${CPU_COUNT}"
else
    check_warn "CPU cores: ${CPU_COUNT} (minimum recommended: ${MIN_CPU})"
fi

# RAM
log_step "Checking RAM..."
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
case "$NODE_TYPE" in
    yugabyte) MIN_RAM=32 ;;
    odoo)     MIN_RAM=16 ;;
    *)        MIN_RAM=8  ;;
esac
if [[ $TOTAL_RAM_GB -ge $MIN_RAM ]]; then
    check_pass "RAM: ${TOTAL_RAM_GB}GB (minimum for ${NODE_TYPE}: ${MIN_RAM}GB)"
else
    check_warn "RAM: ${TOTAL_RAM_GB}GB — recommended minimum for ${NODE_TYPE}: ${MIN_RAM}GB"
fi

# Disk space
log_step "Checking disk space..."
FREE_GB=$(df -BG / | awk 'NR==2 {gsub("G",""); print $4}')
MIN_DISK=50
if [[ $FREE_GB -ge $MIN_DISK ]]; then
    check_pass "Free disk: ${FREE_GB}GB"
else
    check_fail "Free disk: ${FREE_GB}GB — minimum required: ${MIN_DISK}GB"
fi

# Hostname resolution
log_step "Checking hostname resolution..."
for pair in \
    "${YB_NODE1_HOST}:${YB_NODE1_IP}" \
    "${YB_NODE2_HOST}:${YB_NODE2_IP}" \
    "${YB_NODE3_HOST}:${YB_NODE3_IP}" \
    "${ODOO_NODE1_HOST}:${ODOO_NODE1_IP}" \
    "${ODOO_NODE2_HOST}:${ODOO_NODE2_IP}" \
    "${REDIS_HOST}:${REDIS_IP}" \
    "${NFS_SERVER_HOST}:${NFS_SERVER_IP}"; do
    host="${pair%%:*}"
    expected_ip="${pair##*:}"
    resolved=$(getent hosts "$host" 2>/dev/null | awk '{print $1}')
    if [[ "$resolved" == "$expected_ip" ]]; then
        check_pass "DNS/hosts: ${host} → ${resolved}"
    else
        check_warn "DNS/hosts: ${host} resolved to '${resolved}' (expected ${expected_ip}) — check /etc/hosts"
    fi
done

# NTP / time sync
log_step "Checking time sync..."
if systemctl is-active --quiet chrony || systemctl is-active --quiet ntp; then
    check_pass "Time sync service is running"
else
    check_warn "No time sync service detected (chrony/ntp) — required for YugabyteDB"
fi

# Check time offset
if command -v chronyc &>/dev/null; then
    OFFSET=$(chronyc tracking 2>/dev/null | grep "System time" | awk '{print $4}')
    check_pass "Chrony time offset: ${OFFSET}s"
fi

# Firewall
log_step "Checking firewall..."
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    check_warn "UFW is active — ensure required ports are open (scripts will configure this)"
else
    check_pass "UFW not active — scripts will enable and configure it"
fi

# Required tools
log_step "Checking required tools..."
for tool in curl wget git nc python3 pip3 openssl; do
    if command -v "$tool" &>/dev/null; then
        check_pass "Tool available: ${tool}"
    else
        check_warn "Tool missing: ${tool} — will be installed by setup scripts"
    fi
done

# Node-specific checks
case "$NODE_TYPE" in
    yugabyte)
        log_section "YugabyteDB-specific Checks"

        # Swappiness
        SWAPPINESS=$(cat /proc/sys/vm/swappiness)
        if [[ $SWAPPINESS -le 1 ]]; then
            check_pass "vm.swappiness: ${SWAPPINESS}"
        else
            check_warn "vm.swappiness: ${SWAPPINESS} (should be 0 for YugabyteDB)"
        fi

        # Ulimits
        NOFILE=$(ulimit -n)
        if [[ $NOFILE -ge 65536 ]]; then
            check_pass "ulimit nofile: ${NOFILE}"
        else
            check_warn "ulimit nofile: ${NOFILE} (should be ≥1048576)"
        fi

        # Data dir
        if [[ -d "${YB_DATA_DIR}" ]] || mountpoint -q "${YB_DATA_DIR}" 2>/dev/null; then
            DATA_FREE=$(df -BG "${YB_DATA_DIR}" 2>/dev/null | awk 'NR==2 {gsub("G",""); print $4}')
            if [[ ${DATA_FREE:-0} -ge 200 ]]; then
                check_pass "YugabyteDB data dir: ${YB_DATA_DIR} (${DATA_FREE}GB free)"
            else
                check_warn "YugabyteDB data dir: ${YB_DATA_DIR} — only ${DATA_FREE:-0}GB free (500GB+ recommended)"
            fi
        else
            check_warn "YugabyteDB data dir '${YB_DATA_DIR}' does not exist yet"
        fi
        ;;

    odoo)
        log_section "Odoo-specific Checks"

        # Python version
        PY_VER=$(python3 --version 2>&1 | awk '{print $2}')
        if python3 -c "import sys; assert sys.version_info >= (3,10)" 2>/dev/null; then
            check_pass "Python version: ${PY_VER}"
        else
            check_warn "Python version: ${PY_VER} — Odoo 19 requires Python ≥ 3.10"
        fi

        # NFS mount
        if mountpoint -q "${NFS_MOUNT_PATH}" 2>/dev/null; then
            check_pass "NFS filestore mounted at ${NFS_MOUNT_PATH}"
        else
            check_warn "NFS filestore NOT mounted at ${NFS_MOUNT_PATH} — run 06-nfs-client.sh first"
        fi
        ;;
esac

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
log_section "PRE-FLIGHT SUMMARY"
echo -e "  ${GREEN}Passed:${NC}  ${PASS_COUNT}"
echo -e "  ${YELLOW}Warnings:${NC} ${WARN_COUNT}"
echo -e "  ${RED}Failed:${NC}  ${FAIL_COUNT}"
echo ""

if [[ $FAIL_COUNT -gt 0 ]]; then
    log_error "Pre-flight FAILED with ${FAIL_COUNT} critical issue(s). Fix them before proceeding."
    exit 1
elif [[ $WARN_COUNT -gt 0 ]]; then
    log_warn "Pre-flight passed with ${WARN_COUNT} warning(s). Review before proceeding."
    exit 0
else
    log_ok "All pre-flight checks passed! Ready to proceed."
    exit 0
fi
