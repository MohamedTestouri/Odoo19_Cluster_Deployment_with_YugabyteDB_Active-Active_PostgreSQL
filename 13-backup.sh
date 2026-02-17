#!/usr/bin/env bash
# =============================================================================
# 13-backup.sh — Backup Odoo database (pg_dump via YugabyteDB) + filestore
# Schedule via cron: 0 2 * * * root bash /opt/scripts/13-backup.sh
# Usage: sudo bash 13-backup.sh [--full] [--db-only] [--files-only]
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env

LOG_FILE="/tmp/cluster-backup-$(date +%Y%m%d).log"

BACKUP_DB=true
BACKUP_FILES=true
for arg in "$@"; do
    case "$arg" in
        --full)       BACKUP_DB=true;  BACKUP_FILES=true ;;
        --db-only)    BACKUP_DB=true;  BACKUP_FILES=false ;;
        --files-only) BACKUP_DB=false; BACKUP_FILES=true ;;
    esac
done

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_TODAY="${BACKUP_DIR}/${TIMESTAMP}"

log_section "13 — Odoo Cluster Backup (${TIMESTAMP})"
log_info "DB backup: ${BACKUP_DB} | Files backup: ${BACKUP_FILES}"

# ── Create backup directory ───────────────────────────────────────────────────
mkdir -p "${BACKUP_TODAY}"

# ── Database Backup (pg_dump → YugabyteDB YSQL) ───────────────────────────────
if $BACKUP_DB; then
    log_step "Starting database backup (pg_dump)..."
    DB_DUMP_FILE="${BACKUP_TODAY}/${DB_ODOO_NAME}_${TIMESTAMP}.dump"

    PGPASSWORD="${DB_ODOO_PASS}" pg_dump \
        -h "${YB_NODE1_HOST}" \
        -p "${YB_YSQL_PORT}" \
        -U "${DB_ODOO_USER}" \
        -d "${DB_ODOO_NAME}" \
        --format=custom \
        --compress=6 \
        --no-owner \
        --no-acl \
        --verbose \
        -f "${DB_DUMP_FILE}" \
        >> "$LOG_FILE" 2>&1

    if [[ $? -eq 0 && -f "${DB_DUMP_FILE}" ]]; then
        DUMP_SIZE=$(du -sh "${DB_DUMP_FILE}" | awk '{print $1}')
        log_ok "Database backup complete: ${DB_DUMP_FILE} (${DUMP_SIZE})"
    else
        log_error "Database backup FAILED. Check ${LOG_FILE}"
        # Try fallback node
        log_step "Retrying with ${YB_NODE2_HOST}..."
        PGPASSWORD="${DB_ODOO_PASS}" pg_dump \
            -h "${YB_NODE2_HOST}" \
            -p "${YB_YSQL_PORT}" \
            -U "${DB_ODOO_USER}" \
            -d "${DB_ODOO_NAME}" \
            --format=custom \
            --compress=6 \
            -f "${DB_DUMP_FILE}" \
            >> "$LOG_FILE" 2>&1 \
            && log_ok "Database backup succeeded via fallback node" \
            || log_error "Database backup failed on all nodes"
    fi

    # YugabyteDB native snapshot (if yb-admin available)
    if command -v "${YB_INSTALL_DIR}/bin/yb-admin" &>/dev/null; then
        log_step "Creating YugabyteDB native snapshot..."
        YB_MASTER_ADDRS="${YB_NODE1_HOST}:${YB_MASTER_PORT},${YB_NODE2_HOST}:${YB_MASTER_PORT},${YB_NODE3_HOST}:${YB_MASTER_PORT}"
        SNAPSHOT_ID=$(${YB_INSTALL_DIR}/bin/yb-admin \
            --master_addresses="${YB_MASTER_ADDRS}" \
            create_snapshot ysql."${DB_ODOO_NAME}" 2>/dev/null \
            | grep "snapshot_id" | awk '{print $NF}')
        if [[ -n "$SNAPSHOT_ID" ]]; then
            log_ok "YugabyteDB snapshot created: ${SNAPSHOT_ID}"
            echo "${SNAPSHOT_ID}" > "${BACKUP_TODAY}/yb_snapshot_id.txt"
        else
            log_warn "YugabyteDB snapshot creation failed (may need enterprise license)"
        fi
    fi
fi

# ── Filestore Backup (rsync) ──────────────────────────────────────────────────
if $BACKUP_FILES; then
    log_step "Backing up Odoo filestore..."
    FILES_BACKUP="${BACKUP_TODAY}/filestore"
    mkdir -p "${FILES_BACKUP}"

    rsync -av \
        --delete \
        --exclude="*.tmp" \
        --exclude="*.log" \
        "${NFS_MOUNT_PATH}/" \
        "${FILES_BACKUP}/" \
        >> "$LOG_FILE" 2>&1

    if [[ $? -eq 0 ]]; then
        FILES_SIZE=$(du -sh "${FILES_BACKUP}" | awk '{print $1}')
        log_ok "Filestore backup complete: ${FILES_BACKUP} (${FILES_SIZE})"
    else
        log_error "Filestore backup FAILED"
    fi
fi

# ── Write backup manifest ─────────────────────────────────────────────────────
log_step "Writing backup manifest..."
cat > "${BACKUP_TODAY}/MANIFEST.txt" <<EOF
Odoo Cluster Backup Manifest
============================
Timestamp:    ${TIMESTAMP}
Node:         $(hostname)
DB Name:      ${DB_ODOO_NAME}
DB Host:      ${YB_NODE1_HOST}:${YB_YSQL_PORT}
DB Dump:      $(basename "${DB_DUMP_FILE}" 2>/dev/null || echo "skipped")
Filestore:    $([ "${BACKUP_FILES}" == "true" ] && echo "${FILES_BACKUP}" || echo "skipped")
YB Snapshot:  $(cat "${BACKUP_TODAY}/yb_snapshot_id.txt" 2>/dev/null || echo "not created")
Log:          ${LOG_FILE}
EOF
log_ok "Manifest written: ${BACKUP_TODAY}/MANIFEST.txt"

# ── Retention: remove old backups ─────────────────────────────────────────────
log_step "Removing backups older than ${BACKUP_RETENTION_DAYS} days..."
find "${BACKUP_DIR}" -maxdepth 1 -type d -mtime "+${BACKUP_RETENTION_DAYS}" -print0 \
    | xargs -0 rm -rf 2>/dev/null
REMAINING=$(find "${BACKUP_DIR}" -maxdepth 1 -type d | wc -l)
log_ok "Retention applied — ${REMAINING} backup(s) retained"

# ── Verify backup integrity ───────────────────────────────────────────────────
if $BACKUP_DB && [[ -f "${DB_DUMP_FILE}" ]]; then
    log_step "Verifying backup file integrity..."
    pg_restore --list "${DB_DUMP_FILE}" >> "$LOG_FILE" 2>&1 \
        && log_ok "Backup file is valid pg_dump format" \
        || log_warn "Backup file integrity check failed — verify manually"
fi

print_summary "Backup Complete" \
    "Timestamp:  ${TIMESTAMP}" \
    "Location:   ${BACKUP_TODAY}" \
    "DB dump:    $([ "${BACKUP_DB}" == "true" ] && echo "${DUMP_SIZE:-done}" || echo "skipped")" \
    "Filestore:  $([ "${BACKUP_FILES}" == "true" ] && echo "${FILES_SIZE:-done}" || echo "skipped")" \
    "Retention:  ${BACKUP_RETENTION_DAYS} days" \
    "Log file:   ${LOG_FILE}"
