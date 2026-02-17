#!/usr/bin/env bash
# =============================================================================
# 07-redis-setup.sh — Install and configure Redis for Odoo session storage
# Run on redis-01.
# Usage: sudo bash 07-redis-setup.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env

LOG_FILE="/tmp/cluster-setup-07-redis.log"
require_root
require_ubuntu

log_section "07 — Redis Setup on $(hostname)"

# ── Install Redis ─────────────────────────────────────────────────────────────
log_step "Installing Redis..."
apt_update
apt_install redis-server redis-tools

# ── Configure Redis ───────────────────────────────────────────────────────────
log_step "Configuring Redis..."
backup_file /etc/redis/redis.conf

cat > /etc/redis/redis.conf <<EOF
# Redis configuration for Odoo session storage
# Managed by 07-redis-setup.sh — $(date)

# ── Network ────────────────────────────────────────────────────────────────
bind 0.0.0.0
port ${REDIS_PORT}
protected-mode yes
timeout 300
tcp-keepalive 60

# ── Authentication ─────────────────────────────────────────────────────────
requirepass ${REDIS_PASS}

# ── Memory ────────────────────────────────────────────────────────────────
maxmemory ${REDIS_MAXMEMORY}
maxmemory-policy allkeys-lru
maxmemory-samples 10

# ── Persistence ────────────────────────────────────────────────────────────
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
dbfilename dump.rdb
dir /var/lib/redis

# Append-only log for stronger durability
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage 100
auto-aof-rewrite-min-size 64mb
aof-load-truncated yes

# ── Logging ────────────────────────────────────────────────────────────────
loglevel notice
logfile /var/log/redis/redis-server.log

# ── Database ───────────────────────────────────────────────────────────────
databases 16

# ── Performance ────────────────────────────────────────────────────────────
hz 15
dynamic-hz yes
latency-monitor-threshold 100
slowlog-log-slower-than 10000
slowlog-max-len 128

# ── Security ───────────────────────────────────────────────────────────────
rename-command FLUSHALL ""
rename-command FLUSHDB  ""
rename-command DEBUG    ""
rename-command CONFIG   "CONFIG_ADMIN_ONLY"
EOF

log_ok "Redis config written"

# ── Kernel params for Redis ───────────────────────────────────────────────────
log_step "Applying Redis kernel parameters..."
cat > /etc/sysctl.d/99-redis.conf <<EOF
# Redis sysctl — managed by 07-redis-setup.sh
vm.overcommit_memory = 1
net.core.somaxconn = 32768
EOF
sysctl -p /etc/sysctl.d/99-redis.conf >> "$LOG_FILE" 2>&1
# Disable transparent huge pages
echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
echo 'echo never > /sys/kernel/mm/transparent_hugepage/enabled' >> /etc/rc.local
log_ok "Redis kernel params applied"

# ── Enable and start Redis ────────────────────────────────────────────────────
log_step "Starting Redis service..."
service_enable_start redis-server

# ── UFW Rules ─────────────────────────────────────────────────────────────────
log_step "Configuring firewall for Redis..."
ufw allow from "${ODOO_NODE1_IP}" to any port "${REDIS_PORT}" comment "Redis odoo-app-01" >> "$LOG_FILE" 2>&1
ufw allow from "${ODOO_NODE2_IP}" to any port "${REDIS_PORT}" comment "Redis odoo-app-02" >> "$LOG_FILE" 2>&1
log_ok "Redis firewall rules applied"

# ── Verify ────────────────────────────────────────────────────────────────────
log_step "Verifying Redis..."
sleep 2

PING=$(redis-cli -h 127.0.0.1 -p "${REDIS_PORT}" -a "${REDIS_PASS}" ping 2>/dev/null)
if [[ "$PING" == "PONG" ]]; then
    log_ok "Redis responds: PONG"
else
    die "Redis ping failed: ${PING}"
fi

INFO=$(redis-cli -h 127.0.0.1 -p "${REDIS_PORT}" -a "${REDIS_PASS}" info server 2>/dev/null \
    | grep -E "redis_version|maxmemory_human|aof_enabled")
log_info "Redis info: ${INFO}"

# ── Write a test key ──────────────────────────────────────────────────────────
redis-cli -h 127.0.0.1 -p "${REDIS_PORT}" -a "${REDIS_PASS}" \
    set "cluster:test" "setup-ok" EX 60 >> "$LOG_FILE" 2>/dev/null
redis-cli -h 127.0.0.1 -p "${REDIS_PORT}" -a "${REDIS_PASS}" \
    get "cluster:test" >> "$LOG_FILE" 2>/dev/null
log_ok "Redis read/write test passed"

print_summary "Redis Setup Complete on $(hostname)" \
    "Host:      ${REDIS_HOST}:${REDIS_PORT}" \
    "MaxMem:    ${REDIS_MAXMEMORY}" \
    "Eviction:  allkeys-lru" \
    "Auth:      enabled" \
    "AOF:       enabled (everysec)" \
    "Next step: Run 08-odoo-install.sh on each Odoo app node" \
    "Log file:  ${LOG_FILE}"
