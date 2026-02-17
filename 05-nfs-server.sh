#!/usr/bin/env bash
# =============================================================================
# 05-nfs-server.sh — Set up NFS server for shared Odoo filestore
# Run on nfs-01 ONLY.
# Usage: sudo bash 05-nfs-server.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env

LOG_FILE="/tmp/cluster-setup-05-nfs-server.log"
require_root
require_ubuntu

log_section "05 — NFS Server Setup on $(hostname)"

# ── Install NFS server ────────────────────────────────────────────────────────
log_step "Installing NFS kernel server..."
apt_update
apt_install nfs-kernel-server nfs-common

# ── Create export directory ───────────────────────────────────────────────────
log_step "Creating export directory: ${NFS_EXPORT_PATH}..."
mkdir -p "${NFS_EXPORT_PATH}"
# Match the odoo user UID/GID set in .env
chown -R "${ODOO_UID}:${ODOO_GID}" "$(dirname "${NFS_EXPORT_PATH}")"
chmod 2775 "${NFS_EXPORT_PATH}"
log_ok "Export directory ready: ${NFS_EXPORT_PATH}"

# ── Configure NFS exports ─────────────────────────────────────────────────────
log_step "Configuring /etc/exports..."
backup_file /etc/exports

# Remove existing Odoo entries (idempotent)
sed -i '/# ODOO-NFS-START/,/# ODOO-NFS-END/d' /etc/exports

cat >> /etc/exports <<EOF
# ODOO-NFS-START — managed by 05-nfs-server.sh
${NFS_EXPORT_PATH}  ${ODOO_NODE1_IP}(rw,sync,no_subtree_check,no_root_squash,anonuid=${ODOO_UID},anongid=${ODOO_GID})
${NFS_EXPORT_PATH}  ${ODOO_NODE2_IP}(rw,sync,no_subtree_check,no_root_squash,anonuid=${ODOO_UID},anongid=${ODOO_GID})
# ODOO-NFS-END
EOF

log_ok "/etc/exports configured"

# ── Apply exports ─────────────────────────────────────────────────────────────
log_step "Applying NFS exports..."
exportfs -rav >> "$LOG_FILE" 2>&1
log_ok "Exports applied"

# ── Enable NFS server ─────────────────────────────────────────────────────────
log_step "Enabling NFS kernel server..."
service_enable_start nfs-kernel-server

# ── UFW rules for NFS ────────────────────────────────────────────────────────
log_step "Opening NFS ports in firewall..."
ufw allow from "${ODOO_NODE1_IP}" to any port 2049 comment "NFS odoo-app-01" >> "$LOG_FILE" 2>&1
ufw allow from "${ODOO_NODE2_IP}" to any port 2049 comment "NFS odoo-app-02" >> "$LOG_FILE" 2>&1
log_ok "NFS firewall rules applied"

# ── Verify ────────────────────────────────────────────────────────────────────
log_step "Verifying NFS exports..."
showmount -e localhost 2>&1 | tee -a "$LOG_FILE"
log_ok "NFS server ready"

print_summary "NFS Server Ready" \
    "Export path:  ${NFS_EXPORT_PATH}" \
    "Clients:      ${ODOO_NODE1_IP}, ${ODOO_NODE2_IP}" \
    "Mount path:   ${NFS_MOUNT_PATH} (on clients)" \
    "Next step:    Run 06-nfs-client.sh on each Odoo app node" \
    "Log file:     ${LOG_FILE}"
