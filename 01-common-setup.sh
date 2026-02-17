#!/usr/bin/env bash
# =============================================================================
# 01-common-setup.sh — Common OS baseline for ALL cluster nodes
# Run on every node before role-specific scripts.
# Usage: sudo bash 01-common-setup.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env

LOG_FILE="/tmp/cluster-setup-01-common.log"
require_root
require_ubuntu

log_section "01 — Common OS Setup"
log_info "Configuring node: $(hostname)"

# ── System Update ─────────────────────────────────────────────────────────────
log_step "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt_update
apt-get upgrade -y -q >> "$LOG_FILE" 2>&1
log_ok "System updated"

# ── Base Packages ─────────────────────────────────────────────────────────────
log_step "Installing base packages..."
apt_install \
    curl wget git vim htop net-tools \
    chrony ntp \
    build-essential \
    ca-certificates \
    gnupg lsb-release \
    software-properties-common \
    ufw \
    netcat-openbsd \
    jq \
    rsync \
    unzip \
    acl

# ── Timezone ──────────────────────────────────────────────────────────────────
log_step "Setting timezone to ${CLUSTER_TIMEZONE}..."
timedatectl set-timezone "${CLUSTER_TIMEZONE}" >> "$LOG_FILE" 2>&1
log_ok "Timezone: ${CLUSTER_TIMEZONE}"

# ── Locale ────────────────────────────────────────────────────────────────────
log_step "Configuring locale: ${CLUSTER_LOCALE}..."
locale-gen "${CLUSTER_LOCALE}" >> "$LOG_FILE" 2>&1
update-locale LANG="${CLUSTER_LOCALE}" LC_ALL="${CLUSTER_LOCALE}" >> "$LOG_FILE" 2>&1
log_ok "Locale: ${CLUSTER_LOCALE}"

# ── Hosts File ────────────────────────────────────────────────────────────────
log_step "Configuring /etc/hosts..."
# Remove existing cluster entries (idempotent)
sed -i '/# ODOO-CLUSTER-START/,/# ODOO-CLUSTER-END/d' /etc/hosts

cat >> /etc/hosts <<EOF
# ODOO-CLUSTER-START — managed by 01-common-setup.sh
${VIP_IP}          lb-vip
${LB_PRIMARY_IP}   ${LB_PRIMARY_HOST}
${LB_BACKUP_IP}    ${LB_BACKUP_HOST}
${ODOO_NODE1_IP}   ${ODOO_NODE1_HOST}
${ODOO_NODE2_IP}   ${ODOO_NODE2_HOST}
${YB_NODE1_IP}     ${YB_NODE1_HOST}
${YB_NODE2_IP}     ${YB_NODE2_HOST}
${YB_NODE3_IP}     ${YB_NODE3_HOST}
${REDIS_IP}        ${REDIS_HOST}
${NFS_SERVER_IP}   ${NFS_SERVER_HOST}
# ODOO-CLUSTER-END
EOF
log_ok "/etc/hosts configured"

# ── Time Sync ─────────────────────────────────────────────────────────────────
log_step "Enabling time sync with chrony..."
systemctl enable --now chrony >> "$LOG_FILE" 2>&1
chronyc makestep >> "$LOG_FILE" 2>&1 || true
log_ok "Chrony time sync active"

# ── Kernel Parameters ─────────────────────────────────────────────────────────
log_step "Applying kernel sysctl parameters..."
cat > /etc/sysctl.d/99-cluster.conf <<EOF
# =============================================================
# Cluster kernel tuning — managed by 01-common-setup.sh
# =============================================================

# File descriptors
fs.file-max = 1048576

# Network
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 65536
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 30
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_tw_reuse = 1
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# Virtual memory — critical for YugabyteDB
vm.swappiness = 0
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
vm.max_map_count = 1048576

# Enable IP forwarding (needed for VIP/Keepalived)
net.ipv4.ip_forward = 1
net.ipv4.ip_nonlocal_bind = 1
EOF

sysctl -p /etc/sysctl.d/99-cluster.conf >> "$LOG_FILE" 2>&1
log_ok "Kernel parameters applied"

# ── Ulimits ───────────────────────────────────────────────────────────────────
log_step "Configuring system ulimits..."
cat > /etc/security/limits.d/99-cluster.conf <<EOF
# Cluster ulimits — managed by 01-common-setup.sh
*         soft    nofile    1048576
*         hard    nofile    1048576
*         soft    nproc     65536
*         hard    nproc     65536
root      soft    nofile    1048576
root      hard    nofile    1048576
EOF
log_ok "Ulimits configured"

# ── Swap ──────────────────────────────────────────────────────────────────────
log_step "Disabling swap (required for YugabyteDB)..."
swapoff -a >> "$LOG_FILE" 2>&1
sed -i '/swap/d' /etc/fstab
log_ok "Swap disabled"

# ── UFW Firewall — Base Rules ─────────────────────────────────────────────────
log_step "Configuring UFW base rules..."
ufw --force reset >> "$LOG_FILE" 2>&1
ufw default deny incoming >> "$LOG_FILE" 2>&1
ufw default allow outgoing >> "$LOG_FILE" 2>&1
ufw allow ssh comment "SSH" >> "$LOG_FILE" 2>&1
ufw allow from "${INTERNAL_SUBNET}" comment "Internal cluster" >> "$LOG_FILE" 2>&1
ufw --force enable >> "$LOG_FILE" 2>&1
log_ok "UFW base rules applied (SSH + internal subnet allowed)"

# ── SSH Hardening (optional but recommended) ──────────────────────────────────
log_step "Hardening SSH..."
backup_file /etc/ssh/sshd_config

cat >> /etc/ssh/sshd_config.d/99-cluster-hardening.conf <<EOF
# Cluster hardening — managed by 01-common-setup.sh
PermitRootLogin prohibit-password
PasswordAuthentication no
X11Forwarding no
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
EOF

systemctl reload sshd >> "$LOG_FILE" 2>&1
log_ok "SSH hardened"

# ── Done ──────────────────────────────────────────────────────────────────────
print_summary "Common OS Setup Complete" \
    "Hostname:   $(hostname)" \
    "Timezone:   ${CLUSTER_TIMEZONE}" \
    "Locale:     ${CLUSTER_LOCALE}" \
    "Swap:       disabled" \
    "UFW:        active (SSH + ${INTERNAL_SUBNET} allowed)" \
    "Log file:   ${LOG_FILE}"
