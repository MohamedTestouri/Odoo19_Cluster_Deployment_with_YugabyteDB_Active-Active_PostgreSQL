#!/usr/bin/env bash
# =============================================================================
# 06-nfs-client.sh — Mount NFS filestore on an Odoo application node
# Run on EACH Odoo app node (odoo-app-01, odoo-app-02).
# Usage: sudo bash 06-nfs-client.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env

LOG_FILE="/tmp/cluster-setup-06-nfs-client.log"
require_root
require_ubuntu

log_section "06 — NFS Client Setup on $(hostname)"

# ── Install NFS client ────────────────────────────────────────────────────────
log_step "Installing NFS client packages..."
apt_update
apt_install nfs-common

# ── Verify NFS server is reachable ───────────────────────────────────────────
log_step "Checking NFS server reachability: ${NFS_SERVER_HOST} (${NFS_SERVER_IP})..."
wait_for_port "${NFS_SERVER_IP}" 2049 20 3
log_ok "NFS server is reachable"

# ── Create mount point ────────────────────────────────────────────────────────
log_step "Creating mount point: ${NFS_MOUNT_PATH}..."
mkdir -p "${NFS_MOUNT_PATH}"
log_ok "Mount point created"

# ── Add to fstab (idempotent) ─────────────────────────────────────────────────
log_step "Configuring /etc/fstab..."
backup_file /etc/fstab
# Remove existing entry if present
sed -i '/# ODOO-NFS-CLIENT/d' /etc/fstab
sed -i "\|${NFS_SERVER_HOST}:${NFS_EXPORT_PATH}|d" /etc/fstab

cat >> /etc/fstab <<EOF
${NFS_SERVER_HOST}:${NFS_EXPORT_PATH}  ${NFS_MOUNT_PATH}  nfs  rw,hard,intr,rsize=65536,wsize=65536,timeo=14,_netdev,nofail  0  0  # ODOO-NFS-CLIENT
EOF
log_ok "/etc/fstab updated"

# ── Mount ─────────────────────────────────────────────────────────────────────
log_step "Mounting NFS share..."
umount -f "${NFS_MOUNT_PATH}" 2>/dev/null || true
mount "${NFS_MOUNT_PATH}" >> "$LOG_FILE" 2>&1 \
    || die "Failed to mount ${NFS_SERVER_HOST}:${NFS_EXPORT_PATH} → ${NFS_MOUNT_PATH}"
log_ok "NFS share mounted"

# ── Verify ────────────────────────────────────────────────────────────────────
log_step "Verifying mount..."
if mountpoint -q "${NFS_MOUNT_PATH}"; then
    DF_OUT=$(df -h "${NFS_MOUNT_PATH}")
    log_ok "Mount active:"
    echo "$DF_OUT"

    # Write test
    TEST_FILE="${NFS_MOUNT_PATH}/.mount-test-$(hostname)"
    touch "${TEST_FILE}" && rm -f "${TEST_FILE}" \
        && log_ok "Write test passed" \
        || log_warn "Write test failed — check NFS permissions and UID/GID matching"
else
    die "Mount failed — ${NFS_MOUNT_PATH} is not a mountpoint"
fi

print_summary "NFS Client Configured on $(hostname)" \
    "Server:      ${NFS_SERVER_HOST}:${NFS_EXPORT_PATH}" \
    "Mount point: ${NFS_MOUNT_PATH}" \
    "Mount type:  NFS (hard, intr, rsize/wsize 65536)" \
    "Next step:   Run 07-redis-setup.sh on ${REDIS_HOST}" \
    "Log file:    ${LOG_FILE}"
