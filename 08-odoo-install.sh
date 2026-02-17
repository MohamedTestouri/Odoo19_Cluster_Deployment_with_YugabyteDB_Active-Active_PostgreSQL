#!/usr/bin/env bash
# =============================================================================
# 08-odoo-install.sh — Install Odoo 19 on an application node
# Run on EACH Odoo app node (odoo-app-01, odoo-app-02).
# Usage: sudo bash 08-odoo-install.sh
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
load_env

LOG_FILE="/tmp/cluster-setup-08-odoo-install.log"
require_root
require_ubuntu

log_section "08 — Odoo ${ODOO_VERSION} Installation on $(hostname)"

# ── Verify NFS is mounted ──────────────────────────────────────────────────────
if ! mountpoint -q "${NFS_MOUNT_PATH}"; then
    die "NFS filestore is not mounted at ${NFS_MOUNT_PATH}. Run 06-nfs-client.sh first."
fi
log_ok "NFS filestore mounted: ${NFS_MOUNT_PATH}"

# ── System Dependencies ───────────────────────────────────────────────────────
log_step "Installing system dependencies..."
apt_update
apt_install \
    python3 python3-pip python3-venv python3-dev \
    libxml2-dev libxslt1-dev \
    libldap2-dev libsasl2-dev \
    libssl-dev libpq-dev \
    libjpeg-dev libffi-dev libcairo2-dev \
    node-less npm \
    git build-essential \
    fonts-liberation fonts-open-sans \
    libgeos-dev \
    libmagic1 \
    antiword \
    poppler-utils \
    ghostscript

# PostgreSQL client (for pg_dump backup and psql diagnostics)
log_step "Installing PostgreSQL client..."
apt_install postgresql-client
log_ok "PostgreSQL client installed"

# ── Wkhtmltopdf ───────────────────────────────────────────────────────────────
log_step "Installing wkhtmltopdf (patched Qt build)..."
WKHTMLTOPDF_DEB="/tmp/wkhtmltox.deb"
if [[ ! -f "$WKHTMLTOPDF_DEB" ]]; then
    wget -q --show-progress "${WKHTMLTOPDF_DEB_URL}" -O "${WKHTMLTOPDF_DEB}" >> "$LOG_FILE" 2>&1 \
        || log_warn "wkhtmltopdf download failed — PDF reports will not work"
fi

if [[ -f "$WKHTMLTOPDF_DEB" ]]; then
    dpkg -i "${WKHTMLTOPDF_DEB}" >> "$LOG_FILE" 2>&1 \
        || apt-get install -f -y >> "$LOG_FILE" 2>&1
    WKHTML_VER=$(wkhtmltopdf --version 2>/dev/null || echo "unknown")
    log_ok "wkhtmltopdf: ${WKHTML_VER}"
fi

# ── Create Odoo System User ───────────────────────────────────────────────────
log_step "Creating system user '${ODOO_USER}' (UID=${ODOO_UID})..."
if ! id "${ODOO_USER}" &>/dev/null; then
    useradd -m \
        -d "${ODOO_INSTALL_DIR}" \
        -s /bin/bash \
        -U \
        --uid "${ODOO_UID}" \
        "${ODOO_USER}"
    log_ok "User '${ODOO_USER}' created"
else
    log_info "User '${ODOO_USER}' already exists"
    usermod -u "${ODOO_UID}" "${ODOO_USER}" 2>/dev/null || true
fi

# ── Directory Structure ───────────────────────────────────────────────────────
log_step "Creating Odoo directory structure..."
mkdir -p \
    "${ODOO_INSTALL_DIR}" \
    "${ODOO_LOG_DIR}" \
    "${ODOO_SESSIONS_DIR}" \
    "${ODOO_ADDONS_DIR}" \
    "${ODOO_CONFIG_DIR}"

# Link NFS filestore
if [[ -L "${ODOO_FILESTORE_DIR}" ]]; then
    rm -f "${ODOO_FILESTORE_DIR}"
fi
ln -sf "${NFS_MOUNT_PATH}" "${ODOO_FILESTORE_DIR}"
log_ok "Filestore symlink: ${ODOO_FILESTORE_DIR} → ${NFS_MOUNT_PATH}"

chown -R "${ODOO_USER}:${ODOO_GROUP}" \
    "${ODOO_INSTALL_DIR}" \
    "${ODOO_LOG_DIR}" \
    "${ODOO_SESSIONS_DIR}" \
    "${ODOO_ADDONS_DIR}"

chown root:odoo "${ODOO_CONFIG_DIR}"
chmod 750 "${ODOO_CONFIG_DIR}"
log_ok "Directory structure ready"

# ── Clone Odoo Source ────────────────────────────────────────────────────────
if [[ -d "${ODOO_SOURCE_DIR}/.git" ]]; then
    log_step "Odoo source exists — pulling latest from branch ${ODOO_BRANCH}..."
    sudo -u "${ODOO_USER}" git -C "${ODOO_SOURCE_DIR}" pull --ff-only >> "$LOG_FILE" 2>&1 \
        && log_ok "Source updated" \
        || log_warn "Git pull failed — using existing source"
else
    log_step "Cloning Odoo ${ODOO_VERSION} from ${ODOO_REPO}..."
    sudo -u "${ODOO_USER}" git clone \
        --depth=1 \
        --branch="${ODOO_BRANCH}" \
        "${ODOO_REPO}" \
        "${ODOO_SOURCE_DIR}" >> "$LOG_FILE" 2>&1 \
        || die "Git clone failed. Check ODOO_REPO and ODOO_BRANCH in .env"
    log_ok "Odoo ${ODOO_VERSION} cloned to ${ODOO_SOURCE_DIR}"
fi

# ── Python Virtual Environment ────────────────────────────────────────────────
log_step "Creating Python virtual environment at ${ODOO_VENV_DIR}..."
sudo -u "${ODOO_USER}" python3 -m venv "${ODOO_VENV_DIR}" >> "$LOG_FILE" 2>&1
log_ok "Virtual environment created"

log_step "Installing Python dependencies (this may take several minutes)..."
sudo -u "${ODOO_USER}" bash -c "
    source ${ODOO_VENV_DIR}/bin/activate
    pip install --upgrade pip wheel setuptools >> ${LOG_FILE} 2>&1
    pip install -r ${ODOO_SOURCE_DIR}/requirements.txt >> ${LOG_FILE} 2>&1
    pip install gevent psutil redis hiredis greenlet paramiko >> ${LOG_FILE} 2>&1
"
log_ok "Python dependencies installed"

# ── Generate Admin Password Hash ──────────────────────────────────────────────
log_step "Generating hashed admin master password..."
ADMIN_PASS_HASH=$(sudo -u "${ODOO_USER}" \
    "${ODOO_VENV_DIR}/bin/python3" -c "
from passlib.context import CryptContext
ctx = CryptContext(['pbkdf2_sha512'])
print(ctx.hash('${ODOO_MASTER_PASS}'))
" 2>/dev/null)
log_ok "Admin password hash generated"

# ── Odoo Configuration File ───────────────────────────────────────────────────
log_step "Writing Odoo configuration: ${ODOO_CONFIG_FILE}..."
cat > "${ODOO_CONFIG_FILE}" <<EOF
[options]
; ============================================================
; Odoo ${ODOO_VERSION} Configuration
; Generated by 08-odoo-install.sh on $(date)
; Node: $(hostname)
; ============================================================

; ── Database ──────────────────────────────────────────────
db_host = ${PGBOUNCER_HOST}
db_port = ${PGBOUNCER_PORT}
db_name = ${DB_ODOO_NAME}
db_user = ${DB_ODOO_USER}
db_password = ${DB_ODOO_PASS}
db_maxconn = ${ODOO_DB_MAXCONN}
db_sslmode = prefer

; ── Application Server ────────────────────────────────────
http_interface = 0.0.0.0
http_port = ${ODOO_HTTP_PORT}
longpolling_port = ${ODOO_LONGPOLL_PORT}
gevent_port = ${ODOO_GEVENT_PORT}
proxy_mode = True

; ── Workers ───────────────────────────────────────────────
workers = ${ODOO_WORKERS}
max_cron_threads = ${ODOO_MAX_CRON_THREADS}
limit_time_cpu = ${ODOO_LIMIT_TIME_CPU}
limit_time_real = ${ODOO_LIMIT_TIME_REAL}
limit_memory_hard = ${ODOO_LIMIT_MEMORY_HARD}
limit_memory_soft = ${ODOO_LIMIT_MEMORY_SOFT}
limit_request = ${ODOO_LIMIT_REQUEST}

; ── Session (Redis) ────────────────────────────────────────
session_redis_host = ${REDIS_HOST}
session_redis_port = ${REDIS_PORT}
session_redis_password = ${REDIS_PASS}
session_redis_db = ${REDIS_DB}
session_redis_prefix = ${REDIS_PREFIX}

; ── File Storage ───────────────────────────────────────────
data_dir = ${ODOO_FILESTORE_DIR}

; ── Logging ────────────────────────────────────────────────
logfile = ${ODOO_LOG_DIR}/odoo.log
log_level = ${ODOO_LOG_LEVEL}
log_handler = :INFO
logrotate = True

; ── Add-ons ────────────────────────────────────────────────
addons_path = ${ODOO_SOURCE_DIR}/addons,${ODOO_ADDONS_DIR}

; ── Security ───────────────────────────────────────────────
admin_passwd = ${ADMIN_PASS_HASH}
list_db = False

EOF

chown root:"${ODOO_GROUP}" "${ODOO_CONFIG_FILE}"
chmod 640 "${ODOO_CONFIG_FILE}"
log_ok "Odoo config written: ${ODOO_CONFIG_FILE}"

# ── UFW Rules for Odoo ───────────────────────────────────────────────────────
log_step "Opening Odoo ports in firewall..."
ufw allow from "${INTERNAL_SUBNET}" to any port "${ODOO_HTTP_PORT}"   comment "Odoo HTTP" >> "$LOG_FILE" 2>&1
ufw allow from "${INTERNAL_SUBNET}" to any port "${ODOO_LONGPOLL_PORT}" comment "Odoo Longpoll" >> "$LOG_FILE" 2>&1
log_ok "Odoo firewall ports opened"

# ── Logrotate ─────────────────────────────────────────────────────────────────
log_step "Configuring log rotation..."
cat > /etc/logrotate.d/odoo19 <<EOF
${ODOO_LOG_DIR}/odoo.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    copytruncate
    su ${ODOO_USER} ${ODOO_GROUP}
}
EOF
log_ok "Logrotate configured"

print_summary "Odoo ${ODOO_VERSION} Installed on $(hostname)" \
    "Source:     ${ODOO_SOURCE_DIR}" \
    "Venv:       ${ODOO_VENV_DIR}" \
    "Config:     ${ODOO_CONFIG_FILE}" \
    "Filestore:  ${ODOO_FILESTORE_DIR} → ${NFS_MOUNT_PATH}" \
    "HTTP port:  ${ODOO_HTTP_PORT}" \
    "Next step:  Run 09-pgbouncer-setup.sh on this node" \
    "Log file:   ${LOG_FILE}"
