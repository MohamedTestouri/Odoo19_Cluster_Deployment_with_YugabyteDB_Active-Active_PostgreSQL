#!/usr/bin/env bash
# =============================================================================
# 04-yugabytedb-db-setup.sh — Create Odoo database, user, and extensions
# Run ONCE from yb-node-01 after the cluster is healthy.
# Usage: sudo bash 04-yugabytedb-db-setup.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env

LOG_FILE="/tmp/cluster-setup-04-yb-db-setup.log"
require_root

YSQLSH="${YB_INSTALL_DIR}/bin/ysqlsh"
YB_ADMIN="${YB_INSTALL_DIR}/bin/yb-admin"
YB_MASTER_ADDRS="${YB_NODE1_HOST}:${YB_MASTER_PORT},${YB_NODE2_HOST}:${YB_MASTER_PORT},${YB_NODE3_HOST}:${YB_MASTER_PORT}"

log_section "04 — Odoo Database Setup on YugabyteDB"

# ── Verify YSQL connectivity ──────────────────────────────────────────────────
log_step "Testing YSQL connection to ${YB_NODE1_HOST}:${YB_YSQL_PORT}..."
wait_for_port "${YB_NODE1_HOST}" "${YB_YSQL_PORT}" 20 3

PGPASSWORD="${DB_SUPERUSER_PASS}" ${YSQLSH} \
    -h "${YB_NODE1_HOST}" \
    -p "${YB_YSQL_PORT}" \
    -U "${DB_SUPERUSER}" \
    -c "SELECT 1 AS connected;" >> "$LOG_FILE" 2>&1 \
    || die "Cannot connect to YSQL. Ensure cluster is healthy and password is correct."
log_ok "YSQL connection successful"

# ── Helper: run YSQL as superuser ─────────────────────────────────────────────
ysql_exec() {
    PGPASSWORD="${DB_SUPERUSER_PASS}" ${YSQLSH} \
        -h "${YB_NODE1_HOST}" \
        -p "${YB_YSQL_PORT}" \
        -U "${DB_SUPERUSER}" \
        -v ON_ERROR_STOP=1 \
        -c "$1" 2>&1 | tee -a "$LOG_FILE"
}

ysql_exec_db() {
    local db="$1" sql="$2"
    PGPASSWORD="${DB_ODOO_PASS}" ${YSQLSH} \
        -h "${YB_NODE1_HOST}" \
        -p "${YB_YSQL_PORT}" \
        -U "${DB_ODOO_USER}" \
        -d "${db}" \
        -v ON_ERROR_STOP=1 \
        -c "$sql" 2>&1 | tee -a "$LOG_FILE"
}

# ── Create Odoo Database User ─────────────────────────────────────────────────
log_step "Creating database user '${DB_ODOO_USER}'..."
ysql_exec "
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_ODOO_USER}') THEN
        CREATE USER ${DB_ODOO_USER} WITH PASSWORD '${DB_ODOO_PASS}' CREATEDB;
        RAISE NOTICE 'User ${DB_ODOO_USER} created.';
    ELSE
        ALTER USER ${DB_ODOO_USER} WITH PASSWORD '${DB_ODOO_PASS}';
        RAISE NOTICE 'User ${DB_ODOO_USER} already exists — password updated.';
    END IF;
END
\$\$;
"
log_ok "Database user '${DB_ODOO_USER}' ready"

# ── Create Odoo Database ──────────────────────────────────────────────────────
log_step "Creating database '${DB_ODOO_NAME}'..."
DB_EXISTS=$(PGPASSWORD="${DB_SUPERUSER_PASS}" ${YSQLSH} \
    -h "${YB_NODE1_HOST}" -p "${YB_YSQL_PORT}" -U "${DB_SUPERUSER}" \
    -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_ODOO_NAME}'" 2>/dev/null)

if [[ "$DB_EXISTS" == "1" ]]; then
    log_info "Database '${DB_ODOO_NAME}' already exists — skipping creation"
else
    ysql_exec "
CREATE DATABASE ${DB_ODOO_NAME}
    OWNER ${DB_ODOO_USER}
    ENCODING '${DB_ENCODING}'
    LC_COLLATE '${CLUSTER_LOCALE}'
    LC_CTYPE '${CLUSTER_LOCALE}'
    TEMPLATE ${DB_TEMPLATE};
"
    log_ok "Database '${DB_ODOO_NAME}' created"
fi

# ── Grant Privileges ──────────────────────────────────────────────────────────
log_step "Granting privileges to '${DB_ODOO_USER}'..."
ysql_exec "GRANT ALL PRIVILEGES ON DATABASE ${DB_ODOO_NAME} TO ${DB_ODOO_USER};"
log_ok "Privileges granted"

# ── Create Extensions ─────────────────────────────────────────────────────────
log_step "Creating required PostgreSQL extensions in '${DB_ODOO_NAME}'..."
for EXT in uuid-ossp pg_trgm unaccent btree_gin; do
    PGPASSWORD="${DB_SUPERUSER_PASS}" ${YSQLSH} \
        -h "${YB_NODE1_HOST}" \
        -p "${YB_YSQL_PORT}" \
        -U "${DB_SUPERUSER}" \
        -d "${DB_ODOO_NAME}" \
        -c "CREATE EXTENSION IF NOT EXISTS \"${EXT}\";" >> "$LOG_FILE" 2>&1 \
        && log_ok "Extension enabled: ${EXT}" \
        || log_warn "Extension '${EXT}' could not be created (may not be supported in YSQL)"
done

# ── Verify Setup ──────────────────────────────────────────────────────────────
log_step "Verifying database setup..."

echo ""
echo "--- Databases ---"
PGPASSWORD="${DB_SUPERUSER_PASS}" ${YSQLSH} \
    -h "${YB_NODE1_HOST}" -p "${YB_YSQL_PORT}" -U "${DB_SUPERUSER}" \
    -c "\l ${DB_ODOO_NAME}" 2>/dev/null

echo ""
echo "--- Roles ---"
PGPASSWORD="${DB_SUPERUSER_PASS}" ${YSQLSH} \
    -h "${YB_NODE1_HOST}" -p "${YB_YSQL_PORT}" -U "${DB_SUPERUSER}" \
    -c "\du ${DB_ODOO_USER}" 2>/dev/null

echo ""
echo "--- Extensions ---"
PGPASSWORD="${DB_SUPERUSER_PASS}" ${YSQLSH} \
    -h "${YB_NODE1_HOST}" -p "${YB_YSQL_PORT}" -U "${DB_SUPERUSER}" \
    -d "${DB_ODOO_NAME}" \
    -c "SELECT extname, extversion FROM pg_extension;" 2>/dev/null

# ── Test connection as Odoo user ──────────────────────────────────────────────
log_step "Testing connection as '${DB_ODOO_USER}'..."
PGPASSWORD="${DB_ODOO_PASS}" ${YSQLSH} \
    -h "${YB_NODE1_HOST}" \
    -p "${YB_YSQL_PORT}" \
    -U "${DB_ODOO_USER}" \
    -d "${DB_ODOO_NAME}" \
    -c "SELECT current_database(), current_user, version();" >> "$LOG_FILE" 2>&1 \
    && log_ok "Odoo user can connect to database" \
    || die "Odoo user cannot connect to database"

# ── Test replication ──────────────────────────────────────────────────────────
log_step "Verifying data is accessible from all YB nodes..."
for YB_NODE_IP in "${YB_NODE1_IP}" "${YB_NODE2_IP}" "${YB_NODE3_IP}"; do
    RESULT=$(PGPASSWORD="${DB_ODOO_PASS}" ${YSQLSH} \
        -h "${YB_NODE_IP}" -p "${YB_YSQL_PORT}" \
        -U "${DB_ODOO_USER}" -d "${DB_ODOO_NAME}" \
        -tAc "SELECT current_database();" 2>/dev/null || echo "FAILED")
    if [[ "$RESULT" == "${DB_ODOO_NAME}" ]]; then
        log_ok "Node ${YB_NODE_IP}: reachable and DB accessible"
    else
        log_warn "Node ${YB_NODE_IP}: connection returned '${RESULT}'"
    fi
done

print_summary "Database Setup Complete" \
    "Database:   ${DB_ODOO_NAME}" \
    "Owner:      ${DB_ODOO_USER}" \
    "Encoding:   ${DB_ENCODING}" \
    "Extensions: uuid-ossp, pg_trgm, unaccent, btree_gin" \
    "Endpoint:   ${YB_NODE1_HOST}:${YB_YSQL_PORT}" \
    "Next step:  Run 05-nfs-server.sh on ${NFS_SERVER_HOST}" \
    "Log file:   ${LOG_FILE}"
