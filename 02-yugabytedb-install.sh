#!/usr/bin/env bash
# =============================================================================
# 02-yugabytedb-install.sh — Install YugabyteDB on a single DB node
# Run this on EACH of the 3 YugabyteDB nodes independently.
# Usage: sudo bash 02-yugabytedb-install.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env

LOG_FILE="/tmp/cluster-setup-02-yugabyte-install.log"
require_root
require_ubuntu

log_section "02 — YugabyteDB ${YB_VERSION} Installation"
log_info "Node: $(hostname) ($(hostname -I | awk '{print $1}'))"

# ── Detect current node IP ────────────────────────────────────────────────────
NODE_IP=$(hostname -I | awk '{print $1}')
log_info "Detected node IP: ${NODE_IP}"

# ── Validate this is a YB node IP ────────────────────────────────────────────
if [[ "$NODE_IP" != "$YB_NODE1_IP" && \
      "$NODE_IP" != "$YB_NODE2_IP" && \
      "$NODE_IP" != "$YB_NODE3_IP" ]]; then
    die "IP ${NODE_IP} is not in the YugabyteDB node list. Check your .env and network."
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────
log_step "Installing YugabyteDB prerequisites..."
apt_update
apt_install \
    python3 python3-pip libssl-dev libffi-dev \
    libgflags2.2 libgoogle-glog0v5 libcap2 \
    libkrb5-3 libsnappy1v5 \
    tzdata

# ── Create YugabyteDB user ────────────────────────────────────────────────────
log_step "Creating system user '${YB_USER}'..."
if ! id "${YB_USER}" &>/dev/null; then
    useradd -m -d "${YB_INSTALL_DIR}" -s /bin/bash -U "${YB_USER}"
    log_ok "User '${YB_USER}' created"
else
    log_info "User '${YB_USER}' already exists"
fi

# ── Create directories ────────────────────────────────────────────────────────
log_step "Creating directories..."
mkdir -p \
    "${YB_INSTALL_DIR}" \
    "${YB_DATA_DIR}/master" \
    "${YB_DATA_DIR}/tserver" \
    "${YB_LOG_DIR}/master" \
    "${YB_LOG_DIR}/tserver" \
    "${YB_CONFIG_DIR}"

chown -R "${YB_USER}:${YB_GROUP}" \
    "${YB_INSTALL_DIR}" \
    "${YB_DATA_DIR}" \
    "${YB_LOG_DIR}" \
    "${YB_CONFIG_DIR}"

log_ok "Directories created"

# ── Download YugabyteDB ───────────────────────────────────────────────────────
TARBALL="/tmp/yugabyte-${YB_VERSION}.tar.gz"
if [[ ! -f "$TARBALL" ]]; then
    log_step "Downloading YugabyteDB ${YB_VERSION}..."
    wget -q --show-progress \
        "${YB_DOWNLOAD_URL}" \
        -O "${TARBALL}" >> "$LOG_FILE" 2>&1 \
        || die "Download failed. Check YB_DOWNLOAD_URL in .env: ${YB_DOWNLOAD_URL}"
    log_ok "Downloaded: ${TARBALL}"
else
    log_info "Tarball already exists: ${TARBALL} (skipping download)"
fi

# ── Extract ───────────────────────────────────────────────────────────────────
log_step "Extracting YugabyteDB to ${YB_INSTALL_DIR}..."
tar -xzf "${TARBALL}" -C "${YB_INSTALL_DIR}" --strip-components=1 >> "$LOG_FILE" 2>&1
chown -R "${YB_USER}:${YB_GROUP}" "${YB_INSTALL_DIR}"
log_ok "Extracted"

# ── Post-install ──────────────────────────────────────────────────────────────
log_step "Running YugabyteDB post-install script..."
sudo -u "${YB_USER}" "${YB_INSTALL_DIR}/bin/post_install.sh" >> "$LOG_FILE" 2>&1
log_ok "Post-install complete"

# ── Add binaries to PATH ──────────────────────────────────────────────────────
log_step "Adding YugabyteDB binaries to PATH..."
cat > /etc/profile.d/yugabyte.sh <<EOF
# YugabyteDB PATH — managed by 02-yugabytedb-install.sh
export YB_HOME="${YB_INSTALL_DIR}"
export PATH="\${YB_HOME}/bin:\${PATH}"
EOF
log_ok "PATH configured via /etc/profile.d/yugabyte.sh"

# ── Kernel tuning specific to YugabyteDB ─────────────────────────────────────
log_step "Applying YugabyteDB-specific sysctl..."
cat > /etc/sysctl.d/99-yugabyte.conf <<EOF
# YugabyteDB sysctl — managed by 02-yugabytedb-install.sh
vm.swappiness = 0
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
fs.file-max = 1048576
kernel.core_pattern = /tmp/yugabyte_core_%e.%p.%t
EOF

sysctl -p /etc/sysctl.d/99-yugabyte.conf >> "$LOG_FILE" 2>&1
log_ok "YugabyteDB sysctl applied"

# ── Ulimits for yugabyte user ─────────────────────────────────────────────────
log_step "Setting ulimits for ${YB_USER}..."
cat > /etc/security/limits.d/99-yugabyte.conf <<EOF
# YugabyteDB ulimits — managed by 02-yugabytedb-install.sh
${YB_USER}  soft  nofile  1048576
${YB_USER}  hard  nofile  1048576
${YB_USER}  soft  nproc   12000
${YB_USER}  hard  nproc   12000
${YB_USER}  soft  core    unlimited
${YB_USER}  hard  core    unlimited
EOF
log_ok "Ulimits configured"

# ── Master Config ─────────────────────────────────────────────────────────────
log_step "Writing YB-Master config..."
cat > "${YB_CONFIG_DIR}/master.conf" <<EOF
# YB-Master configuration — managed by 02-yugabytedb-install.sh
# Generated: $(date)
--master_addresses=${YB_NODE1_HOST}:${YB_MASTER_PORT},${YB_NODE2_HOST}:${YB_MASTER_PORT},${YB_NODE3_HOST}:${YB_MASTER_PORT}
--replication_factor=${YB_REPLICATION_FACTOR}
--fs_data_dirs=${YB_DATA_DIR}/master
--log_dir=${YB_LOG_DIR}/master
--logtostderr=false
--use_cassandra_authentication=false
--enable_ysql=true
--ysql_enable_auth=true
EOF
chown "${YB_USER}:${YB_GROUP}" "${YB_CONFIG_DIR}/master.conf"
log_ok "Master config written"

# ── TServer Config ────────────────────────────────────────────────────────────
log_step "Writing YB-TServer config..."

YB_YSQL_PG_CONF="max_connections=${YB_YSQL_MAX_CONNECTIONS},\
shared_buffers=${YB_YSQL_SHARED_BUFFERS},\
effective_cache_size=${YB_YSQL_EFFECTIVE_CACHE},\
work_mem=${YB_YSQL_WORK_MEM},\
maintenance_work_mem=${YB_YSQL_MAINTENANCE_WORK_MEM},\
checkpoint_completion_target=${YB_YSQL_CHECKPOINT_TARGET},\
wal_buffers=${YB_YSQL_WAL_BUFFERS},\
default_statistics_target=${YB_YSQL_STATS_TARGET},\
random_page_cost=${YB_YSQL_RANDOM_PAGE_COST},\
effective_io_concurrency=${YB_YSQL_IO_CONCURRENCY},\
min_wal_size=${YB_YSQL_MIN_WAL_SIZE},\
max_wal_size=${YB_YSQL_MAX_WAL_SIZE},\
idle_in_transaction_session_timeout=${YB_IDLE_IN_TX_TIMEOUT},\
statement_timeout=${YB_STATEMENT_TIMEOUT},\
lock_timeout=${YB_LOCK_TIMEOUT},\
deadlock_timeout=${YB_DEADLOCK_TIMEOUT},\
log_min_duration_statement=${YB_SLOW_QUERY_MS}"

cat > "${YB_CONFIG_DIR}/tserver.conf" <<EOF
# YB-TServer configuration — managed by 02-yugabytedb-install.sh
# Generated: $(date)
--tserver_master_addrs=${YB_NODE1_HOST}:${YB_MASTER_PORT},${YB_NODE2_HOST}:${YB_MASTER_PORT},${YB_NODE3_HOST}:${YB_MASTER_PORT}
--fs_data_dirs=${YB_DATA_DIR}/tserver
--log_dir=${YB_LOG_DIR}/tserver
--logtostderr=false
--enable_ysql=true
--pgsql_proxy_bind_address=0.0.0.0:${YB_YSQL_PORT}
--cql_proxy_bind_address=0.0.0.0:9042
--webserver_port=${YB_TSERVER_WEB_PORT}
--ysql_max_connections=${YB_YSQL_MAX_CONNECTIONS}
--ysql_pg_conf_csv=${YB_YSQL_PG_CONF}
EOF
chown "${YB_USER}:${YB_GROUP}" "${YB_CONFIG_DIR}/tserver.conf"
log_ok "TServer config written"

# ── Systemd: YB-Master ────────────────────────────────────────────────────────
log_step "Creating yb-master systemd service..."
cat > /etc/systemd/system/yb-master.service <<EOF
[Unit]
Description=YugabyteDB Master (${YB_VERSION})
Documentation=https://docs.yugabyte.com
After=network.target
Wants=network.target

[Service]
Type=simple
User=${YB_USER}
Group=${YB_GROUP}
ExecStart=${YB_INSTALL_DIR}/bin/yb-master \\
    --flagfile=${YB_CONFIG_DIR}/master.conf \\
    --rpc_bind_addresses=${NODE_IP}:${YB_MASTER_PORT} \\
    --webserver_interface=${NODE_IP} \\
    --webserver_port=${YB_MASTER_WEB_PORT}
Restart=on-failure
RestartSec=5
KillMode=mixed
LimitNOFILE=1048576
LimitNPROC=12000
StandardOutput=append:${YB_LOG_DIR}/master/master.out
StandardError=append:${YB_LOG_DIR}/master/master.err

[Install]
WantedBy=multi-user.target
EOF

# ── Systemd: YB-TServer ───────────────────────────────────────────────────────
log_step "Creating yb-tserver systemd service..."
cat > /etc/systemd/system/yb-tserver.service <<EOF
[Unit]
Description=YugabyteDB TServer (${YB_VERSION})
Documentation=https://docs.yugabyte.com
After=network.target yb-master.service
Wants=network.target

[Service]
Type=simple
User=${YB_USER}
Group=${YB_GROUP}
ExecStart=${YB_INSTALL_DIR}/bin/yb-tserver \\
    --flagfile=${YB_CONFIG_DIR}/tserver.conf \\
    --rpc_bind_addresses=${NODE_IP}:${YB_TSERVER_RPC_PORT} \\
    --webserver_interface=${NODE_IP}
Restart=on-failure
RestartSec=5
KillMode=mixed
LimitNOFILE=1048576
LimitNPROC=12000
StandardOutput=append:${YB_LOG_DIR}/tserver/tserver.out
StandardError=append:${YB_LOG_DIR}/tserver/tserver.err

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
log_ok "Systemd services created (not started yet — run 03-yugabytedb-cluster-init.sh)"

# ── UFW Firewall rules for YugabyteDB ────────────────────────────────────────
log_step "Opening firewall ports for YugabyteDB..."
ufw allow from "${INTERNAL_SUBNET}" to any port "${YB_YSQL_PORT}"     comment "YB YSQL" >> "$LOG_FILE" 2>&1
ufw allow from "${INTERNAL_SUBNET}" to any port "${YB_MASTER_PORT}"   comment "YB Master RPC" >> "$LOG_FILE" 2>&1
ufw allow from "${INTERNAL_SUBNET}" to any port "${YB_TSERVER_RPC_PORT}" comment "YB TServer RPC" >> "$LOG_FILE" 2>&1
ufw allow from "${INTERNAL_SUBNET}" to any port "${YB_MASTER_WEB_PORT}"  comment "YB Master Web" >> "$LOG_FILE" 2>&1
ufw allow from "${INTERNAL_SUBNET}" to any port "${YB_TSERVER_WEB_PORT}" comment "YB TServer Web" >> "$LOG_FILE" 2>&1
ufw allow from "${INTERNAL_SUBNET}" to any port 9042 comment "YB CQL" >> "$LOG_FILE" 2>&1
log_ok "Firewall ports opened"

# ── Verify installation ───────────────────────────────────────────────────────
log_step "Verifying YugabyteDB installation..."
YB_VERS_OUTPUT=$("${YB_INSTALL_DIR}/bin/yb-master" --version 2>&1 | head -1)
log_ok "YugabyteDB binary: ${YB_VERS_OUTPUT}"

print_summary "YugabyteDB ${YB_VERSION} Installed on $(hostname)" \
    "Install dir:   ${YB_INSTALL_DIR}" \
    "Data dir:      ${YB_DATA_DIR}" \
    "Log dir:       ${YB_LOG_DIR}" \
    "Config dir:    ${YB_CONFIG_DIR}" \
    "Node IP:       ${NODE_IP}" \
    "YSQL port:     ${YB_YSQL_PORT}" \
    "Next step:     Run 03-yugabytedb-cluster-init.sh on ALL nodes" \
    "Log file:      ${LOG_FILE}"
