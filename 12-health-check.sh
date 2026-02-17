#!/usr/bin/env bash
# =============================================================================
# 12-health-check.sh — Full cluster health check and status report
# Run from any node that can reach all cluster components.
# Usage: bash 12-health-check.sh [--json] [--watch]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env

LOG_FILE="/tmp/cluster-setup-12-health.log"

JSON_MODE=false
WATCH_MODE=false
for arg in "$@"; do
    case "$arg" in
        --json)  JSON_MODE=true  ;;
        --watch) WATCH_MODE=true ;;
    esac
done

PASS=0; FAIL=0; WARN=0
declare -A RESULTS

hc_pass() { log_ok "$1";    RESULTS["$1"]="PASS"; ((PASS++)); }
hc_fail() { log_fail "$1";  RESULTS["$1"]="FAIL"; ((FAIL++)); }
hc_warn() { log_warn "$1";  RESULTS["$1"]="WARN"; ((WARN++)); }

# ── Run checks ────────────────────────────────────────────────────────────────
run_checks() {
    PASS=0; FAIL=0; WARN=0
    RESULTS=()

    log_section "CLUSTER HEALTH CHECK — $(date '+%Y-%m-%d %H:%M:%S')"

    # ── VIP / Load Balancer ────────────────────────────────────────────────────
    log_section "Load Balancer"
    for LB_IP in "${LB_PRIMARY_IP}" "${LB_BACKUP_IP}"; do
        if check_port_open "${LB_IP}" 443; then
            hc_pass "LB ${LB_IP}:443 reachable"
        else
            hc_fail "LB ${LB_IP}:443 NOT reachable"
        fi
    done

    # Check VIP
    if check_port_open "${VIP_IP}" 443; then
        hc_pass "VIP ${VIP_IP}:443 reachable"
    else
        hc_fail "VIP ${VIP_IP}:443 NOT reachable"
    fi

    # Health endpoint via VIP
    HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
        "https://${VIP_IP}/web/health" \
        --resolve "${CLUSTER_DOMAIN}:443:${VIP_IP}" 2>/dev/null || echo "000")
    if [[ "$HTTP_CODE" == "200" ]]; then
        hc_pass "Odoo via VIP: HTTP ${HTTP_CODE}"
    else
        hc_warn "Odoo via VIP: HTTP ${HTTP_CODE} (Odoo may still be starting)"
    fi

    # ── Odoo App Nodes ─────────────────────────────────────────────────────────
    log_section "Odoo Application Nodes"
    for NODE_INFO in "${ODOO_NODE1_HOST}:${ODOO_NODE1_IP}" "${ODOO_NODE2_HOST}:${ODOO_NODE2_IP}"; do
        NODE_HOST="${NODE_INFO%%:*}"
        NODE_ADDR="${NODE_INFO##*:}"

        # HTTP health
        HTTP=$(curl -s -o /dev/null -w "%{http_code}" \
            "http://${NODE_ADDR}:${ODOO_HTTP_PORT}/web/health" \
            --connect-timeout 5 2>/dev/null || echo "000")
        if [[ "$HTTP" == "200" ]]; then
            hc_pass "${NODE_HOST} HTTP health: ${HTTP}"
        else
            hc_fail "${NODE_HOST} HTTP health: ${HTTP}"
        fi

        # Longpoll port
        if check_port_open "${NODE_ADDR}" "${ODOO_LONGPOLL_PORT}"; then
            hc_pass "${NODE_HOST} longpoll port ${ODOO_LONGPOLL_PORT}: open"
        else
            hc_warn "${NODE_HOST} longpoll port ${ODOO_LONGPOLL_PORT}: closed"
        fi

        # PgBouncer
        if check_port_open "${NODE_ADDR}" "${PGBOUNCER_PORT}"; then
            hc_pass "${NODE_HOST} PgBouncer port ${PGBOUNCER_PORT}: open"
        else
            hc_fail "${NODE_HOST} PgBouncer port ${PGBOUNCER_PORT}: closed"
        fi
    done

    # ── YugabyteDB Cluster ─────────────────────────────────────────────────────
    log_section "YugabyteDB Cluster"
    YB_ADMIN_CMD="${YB_INSTALL_DIR}/bin/yb-admin"
    YB_MASTER_ADDRS="${YB_NODE1_HOST}:${YB_MASTER_PORT},${YB_NODE2_HOST}:${YB_MASTER_PORT},${YB_NODE3_HOST}:${YB_MASTER_PORT}"

    for YB_INFO in "${YB_NODE1_HOST}:${YB_NODE1_IP}" "${YB_NODE2_HOST}:${YB_NODE2_IP}" "${YB_NODE3_HOST}:${YB_NODE3_IP}"; do
        YB_HOST="${YB_INFO%%:*}"
        YB_ADDR="${YB_INFO##*:}"

        # YSQL port
        if check_port_open "${YB_ADDR}" "${YB_YSQL_PORT}"; then
            hc_pass "${YB_HOST} YSQL port ${YB_YSQL_PORT}: open"
        else
            hc_fail "${YB_HOST} YSQL port ${YB_YSQL_PORT}: closed"
        fi

        # Master web UI
        HTTP_UI=$(curl -s -o /dev/null -w "%{http_code}" \
            "http://${YB_ADDR}:${YB_MASTER_WEB_PORT}/" \
            --connect-timeout 5 2>/dev/null || echo "000")
        if [[ "$HTTP_UI" =~ ^(200|301|302)$ ]]; then
            hc_pass "${YB_HOST} master UI: HTTP ${HTTP_UI}"
        else
            hc_warn "${YB_HOST} master UI: HTTP ${HTTP_UI}"
        fi
    done

    # Check master count via yb-admin (if available)
    if command -v "${YB_ADMIN_CMD}" &>/dev/null; then
        ALIVE_MASTERS=$(${YB_ADMIN_CMD} --master_addresses="${YB_MASTER_ADDRS}" \
            list_all_masters 2>/dev/null | grep -c "ALIVE" || echo "0")
        ALIVE_TS=$(${YB_ADMIN_CMD} --master_addresses="${YB_MASTER_ADDRS}" \
            list_all_tablet_servers 2>/dev/null | grep -c "ALIVE" || echo "0")

        if [[ $ALIVE_MASTERS -eq 3 ]]; then
            hc_pass "YB Masters: ${ALIVE_MASTERS}/3 ALIVE"
        elif [[ $ALIVE_MASTERS -ge 2 ]]; then
            hc_warn "YB Masters: ${ALIVE_MASTERS}/3 ALIVE (degraded but functional)"
        else
            hc_fail "YB Masters: ${ALIVE_MASTERS}/3 ALIVE (cluster at risk!)"
        fi

        if [[ $ALIVE_TS -eq 3 ]]; then
            hc_pass "YB TServers: ${ALIVE_TS}/3 ALIVE"
        elif [[ $ALIVE_TS -ge 2 ]]; then
            hc_warn "YB TServers: ${ALIVE_TS}/3 ALIVE (degraded)"
        else
            hc_fail "YB TServers: ${ALIVE_TS}/3 ALIVE"
        fi
    else
        log_info "yb-admin not found locally — skipping master/tserver counts"
    fi

    # ── Database Connectivity ──────────────────────────────────────────────────
    log_section "Database Access"
    for YB_ADDR in "${YB_NODE1_IP}" "${YB_NODE2_IP}" "${YB_NODE3_IP}"; do
        DB_RESULT=$(PGPASSWORD="${DB_ODOO_PASS}" psql \
            -h "${YB_ADDR}" -p "${YB_YSQL_PORT}" \
            -U "${DB_ODOO_USER}" -d "${DB_ODOO_NAME}" \
            -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public';" \
            --connect-timeout=5 2>/dev/null || echo "FAIL")
        if [[ "$DB_RESULT" =~ ^[0-9]+$ ]] && [[ $DB_RESULT -gt 0 ]]; then
            hc_pass "DB ${YB_ADDR}: ${DB_RESULT} tables reachable"
        else
            hc_fail "DB ${YB_ADDR}: cannot query (${DB_RESULT})"
        fi
    done

    # ── Redis ─────────────────────────────────────────────────────────────────
    log_section "Redis Session Store"
    REDIS_PING=$(redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" \
        -a "${REDIS_PASS}" --no-auth-warning ping 2>/dev/null || echo "FAIL")
    if [[ "$REDIS_PING" == "PONG" ]]; then
        hc_pass "Redis ${REDIS_HOST}:${REDIS_PORT}: PONG"
        SESSION_COUNT=$(redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" \
            -a "${REDIS_PASS}" --no-auth-warning \
            eval "return #redis.call('keys', '${REDIS_PREFIX}*')" 0 2>/dev/null || echo "?")
        log_info "Active Odoo sessions in Redis: ${SESSION_COUNT}"
    else
        hc_fail "Redis ${REDIS_HOST}:${REDIS_PORT}: NOT responding (${REDIS_PING})"
    fi

    # ── NFS ───────────────────────────────────────────────────────────────────
    log_section "Shared Storage (NFS)"
    if check_port_open "${NFS_SERVER_IP}" 2049; then
        hc_pass "NFS server ${NFS_SERVER_HOST}:2049: reachable"
    else
        hc_fail "NFS server ${NFS_SERVER_HOST}:2049: not reachable"
    fi

    # ── Summary ───────────────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${BOLD} CLUSTER HEALTH SUMMARY${NC}"
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
    echo -e "  ${GREEN}✔ PASS:${NC}  ${PASS}"
    echo -e "  ${YELLOW}⚠ WARN:${NC}  ${WARN}"
    echo -e "  ${RED}✘ FAIL:${NC}  ${FAIL}"
    echo -e "${BOLD}══════════════════════════════════════════${NC}"

    if [[ $FAIL -gt 0 ]]; then
        echo -e "\n${RED}STATUS: UNHEALTHY — ${FAIL} check(s) failed${NC}"
        OVERALL_STATUS="UNHEALTHY"
        OVERALL_EXIT=2
    elif [[ $WARN -gt 0 ]]; then
        echo -e "\n${YELLOW}STATUS: DEGRADED — ${WARN} warning(s)${NC}"
        OVERALL_STATUS="DEGRADED"
        OVERALL_EXIT=1
    else
        echo -e "\n${GREEN}STATUS: HEALTHY — all checks passed${NC}"
        OVERALL_STATUS="HEALTHY"
        OVERALL_EXIT=0
    fi

    # ── JSON output ────────────────────────────────────────────────────────────
    if $JSON_MODE; then
        echo ""
        echo "{"
        echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
        echo "  \"status\": \"${OVERALL_STATUS}\","
        echo "  \"pass\": ${PASS},"
        echo "  \"warn\": ${WARN},"
        echo "  \"fail\": ${FAIL},"
        echo "  \"checks\": {"
        FIRST=true
        for key in "${!RESULTS[@]}"; do
            $FIRST || echo ","
            printf '    "%s": "%s"' "${key}" "${RESULTS[$key]}"
            FIRST=false
        done
        echo ""
        echo "  }"
        echo "}"
    fi

    return $OVERALL_EXIT
}

# ── Watch mode ────────────────────────────────────────────────────────────────
if $WATCH_MODE; then
    log_info "Watch mode: refreshing every 30 seconds. Press Ctrl+C to stop."
    while true; do
        clear
        run_checks || true
        sleep 30
    done
else
    run_checks
    exit $?
fi
