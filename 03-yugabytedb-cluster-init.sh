#!/usr/bin/env bash
# =============================================================================
# 03-yugabytedb-cluster-init.sh — Bootstrap and initialize the YugabyteDB cluster
# Run on ALL YugabyteDB nodes. The script auto-detects node role.
# Wait for all 3 nodes to have run 02-yugabytedb-install.sh before running this.
# Usage: sudo bash 03-yugabytedb-cluster-init.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env

LOG_FILE="/tmp/cluster-setup-03-yb-cluster-init.log"
require_root

YB_ADMIN="${YB_INSTALL_DIR}/bin/yb-admin"
YSQLSH="${YB_INSTALL_DIR}/bin/ysqlsh"
YB_MASTER_ADDRS="${YB_NODE1_HOST}:${YB_MASTER_PORT},${YB_NODE2_HOST}:${YB_MASTER_PORT},${YB_NODE3_HOST}:${YB_MASTER_PORT}"

NODE_IP=$(hostname -I | awk '{print $1}')
log_section "03 — YugabyteDB Cluster Initialization"
log_info "Node IP: ${NODE_IP}"

# ── Start Services ────────────────────────────────────────────────────────────
log_step "Enabling and starting yb-master on this node..."
systemctl daemon-reload
systemctl enable yb-master >> "$LOG_FILE" 2>&1
systemctl start yb-master >> "$LOG_FILE" 2>&1
sleep 3

if systemctl is-active --quiet yb-master; then
    log_ok "yb-master is running on $(hostname)"
else
    log_error "yb-master failed to start. Checking logs..."
    journalctl -u yb-master --no-pager -n 40 | tail -20
    die "yb-master failed"
fi

log_step "Enabling and starting yb-tserver on this node..."
systemctl enable yb-tserver >> "$LOG_FILE" 2>&1
systemctl start yb-tserver >> "$LOG_FILE" 2>&1
sleep 5

if systemctl is-active --quiet yb-tserver; then
    log_ok "yb-tserver is running on $(hostname)"
else
    log_error "yb-tserver failed to start. Checking logs..."
    journalctl -u yb-tserver --no-pager -n 40 | tail -20
    die "yb-tserver failed"
fi

# ── Only run cluster verification/setup from the primary node ─────────────────
if [[ "$NODE_IP" == "$YB_NODE1_IP" ]]; then
    log_section "Cluster Verification (running from primary node ${YB_NODE1_HOST})"

    # Wait for all TServers to join
    log_step "Waiting for all 3 YB TServers to register (up to 120s)..."
    for i in $(seq 1 40); do
        ALIVE_TS=$(${YB_ADMIN} --master_addresses="${YB_MASTER_ADDRS}" \
            list_all_tablet_servers 2>/dev/null | grep -c "ALIVE" || echo 0)
        if [[ $ALIVE_TS -ge 3 ]]; then
            log_ok "All 3 TServers are ALIVE"
            break
        fi
        log_info "TServers alive: ${ALIVE_TS}/3 — waiting (${i}/40)..."
        sleep 3
    done

    if [[ $ALIVE_TS -lt 3 ]]; then
        die "Only ${ALIVE_TS}/3 TServers became ALIVE. Check logs on other nodes."
    fi

    # Wait for all Masters
    log_step "Verifying all 3 YB Masters..."
    ALIVE_MASTERS=$(${YB_ADMIN} --master_addresses="${YB_MASTER_ADDRS}" \
        list_all_masters 2>/dev/null | grep -c "ALIVE" || echo 0)
    if [[ $ALIVE_MASTERS -eq 3 ]]; then
        log_ok "All 3 Masters are ALIVE"
    else
        log_warn "Masters alive: ${ALIVE_MASTERS}/3 — proceeding anyway"
    fi

    # Print cluster info
    log_section "Cluster Status"
    ${YB_ADMIN} --master_addresses="${YB_MASTER_ADDRS}" list_all_masters 2>/dev/null
    echo ""
    ${YB_ADMIN} --master_addresses="${YB_MASTER_ADDRS}" list_all_tablet_servers 2>/dev/null

    # ── Set YugabyteDB superuser password ─────────────────────────────────────
    log_step "Waiting for YSQL to be ready on ${YB_NODE1_HOST}:${YB_YSQL_PORT}..."
    wait_for_port "${YB_NODE1_HOST}" "${YB_YSQL_PORT}" 30 4

    log_step "Setting YugabyteDB superuser password..."
    PGPASSWORD="" ${YSQLSH} \
        -h "${YB_NODE1_HOST}" \
        -p "${YB_YSQL_PORT}" \
        -U "${DB_SUPERUSER}" \
        -c "ALTER USER ${DB_SUPERUSER} WITH PASSWORD '${DB_SUPERUSER_PASS}';" \
        >> "$LOG_FILE" 2>&1 \
        && log_ok "Superuser password set" \
        || log_warn "Could not set superuser password (may already be set)"

    # ── Verify all nodes via yb_servers() ─────────────────────────────────────
    log_step "Verifying cluster via YSQL yb_servers()..."
    PGPASSWORD="${DB_SUPERUSER_PASS}" ${YSQLSH} \
        -h "${YB_NODE1_HOST}" \
        -p "${YB_YSQL_PORT}" \
        -U "${DB_SUPERUSER}" \
        -c "SELECT host, port, num_connections, node_type, cloud, region, zone, public_ip FROM yb_servers();" \
        2>&1 | tee -a "$LOG_FILE"

    # ── Configure snapshot schedule ────────────────────────────────────────────
    log_step "Creating automatic snapshot schedule..."
    ${YB_ADMIN} --master_addresses="${YB_MASTER_ADDRS}" \
        create_snapshot_schedule \
        "${BACKUP_YB_SNAPSHOT_INTERVAL_MIN}" \
        "${BACKUP_YB_SNAPSHOT_RETENTION_MIN}" \
        2>/dev/null >> "$LOG_FILE" 2>&1 \
        && log_ok "Snapshot schedule created (interval: ${BACKUP_YB_SNAPSHOT_INTERVAL_MIN}m, retention: ${BACKUP_YB_SNAPSHOT_RETENTION_MIN}m)" \
        || log_warn "Snapshot schedule creation failed (may require enterprise license)"

    print_summary "YugabyteDB Cluster Initialized" \
        "Masters:       ${ALIVE_MASTERS}/3 ALIVE" \
        "TServers:      ${ALIVE_TS}/3 ALIVE" \
        "YSQL endpoint: ${YB_NODE1_HOST}:${YB_YSQL_PORT}" \
        "Master UI:     http://${YB_NODE1_HOST}:${YB_MASTER_WEB_PORT}" \
        "TServer UI:    http://${YB_NODE1_HOST}:${YB_TSERVER_WEB_PORT}" \
        "Next step:     Run 04-yugabytedb-db-setup.sh on ${YB_NODE1_HOST}"

else
    log_info "Skipping cluster verification (only runs on primary node ${YB_NODE1_HOST})"
    print_summary "YugabyteDB Services Started on $(hostname)" \
        "yb-master:   active" \
        "yb-tserver:  active" \
        "Node IP:     ${NODE_IP}" \
        "Next step:   Verify cluster from ${YB_NODE1_HOST}"
fi
