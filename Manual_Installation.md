# Odoo 19 Cluster Deployment with YugabyteDB Active-Active PostgreSQL

> **Target Audience:** DevOps / Infrastructure Engineers  
> **Stack:** Odoo 19 · HAProxy · YugabyteDB · Ubuntu 24.04 LTS  
> **Architecture:** Multi-node Odoo cluster + YugabyteDB 3-node active-active distributed SQL

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Infrastructure Requirements](#2-infrastructure-requirements)
3. [YugabyteDB Active-Active Cluster Setup](#3-yugabytedb-active-active-cluster-setup)
4. [Preparing the Database for Odoo](#4-preparing-the-database-for-odoo)
5. [Shared Storage Setup (NFS / GlusterFS)](#5-shared-storage-setup)
6. [Installing Odoo 19 on Each Application Node](#6-installing-odoo-19-on-each-application-node)
7. [Configuring Odoo for Cluster Mode](#7-configuring-odoo-for-cluster-mode)
8. [Load Balancer Configuration (HAProxy)](#8-load-balancer-configuration-haproxy)
9. [Redis for Session Management](#9-redis-for-session-management)
10. [Systemd Service & Auto-start](#10-systemd-service--auto-start)
11. [Health Checks & Monitoring](#11-health-checks--monitoring)
12. [Backup Strategy](#12-backup-strategy)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Architecture Overview

```
                        ┌─────────────────────────────────────┐
                        │          Internet / Users            │
                        └──────────────────┬──────────────────┘
                                           │
                        ┌──────────────────▼──────────────────┐
                        │     HAProxy / Nginx (VIP)            │
                        │   192.168.1.10 (Keepalived VIP)      │
                        └────────┬─────────────────┬──────────┘
                                 │                 │
               ┌─────────────────▼──┐         ┌───▼─────────────────┐
               │   Odoo Node 1      │         │   Odoo Node 2        │
               │   192.168.1.21     │         │   192.168.1.22       │
               │   (odoo-app-01)    │         │   (odoo-app-02)      │
               └─────────┬──────────┘         └────┬────────────────┘
                         │                         │
                         └───────────┬─────────────┘
                                     │  PostgreSQL wire protocol
                         ┌───────────▼─────────────┐
                         │   YugabyteDB Cluster      │
                         │                           │
                         │  ┌────────┐ ┌────────┐   │
                         │  │  YB-1  │ │  YB-2  │   │
                         │  │.1.31   │ │.1.32   │   │
                         │  └────────┘ └────────┘   │
                         │       ┌────────┐          │
                         │       │  YB-3  │          │
                         │       │.1.33   │          │
                         │       └────────┘          │
                         └───────────────────────────┘
                                     │
                         ┌───────────▼─────────────┐
                         │   Redis Sentinel Cluster  │
                         │   (Session Storage)       │
                         └───────────────────────────┘
                                     │
                         ┌───────────▼─────────────┐
                         │   NFS / GlusterFS         │
                         │   (Shared Filestore)      │
                         └───────────────────────────┘
```

### Node IP Reference Table

| Role | Hostname | IP Address |
|---|---|---|
| Load Balancer (VIP) | lb-vip | 192.168.1.10 |
| Load Balancer Primary | haproxy-01 | 192.168.1.11 |
| Load Balancer Secondary | haproxy-02 | 192.168.1.12 |
| Odoo App Node 1 | odoo-app-01 | 192.168.1.21 |
| Odoo App Node 2 | odoo-app-02 | 192.168.1.22 |
| YugabyteDB Node 1 | yb-node-01 | 192.168.1.31 |
| YugabyteDB Node 2 | yb-node-02 | 192.168.1.32 |
| YugabyteDB Node 3 | yb-node-03 | 192.168.1.33 |
| Redis Sentinel 1 | redis-01 | 192.168.1.41 |
| NFS Server | nfs-01 | 192.168.1.51 |

---

## 2. Infrastructure Requirements

### Minimum Hardware per Role

| Node Type | CPU | RAM | Disk | Network |
|---|---|---|---|---|
| Odoo App Node | 8 vCPU | 16 GB | 100 GB SSD | 1 Gbps |
| YugabyteDB Node | 16 vCPU | 32 GB | 500 GB NVMe | 10 Gbps |
| HAProxy Node | 4 vCPU | 8 GB | 50 GB | 1 Gbps |
| Redis Node | 4 vCPU | 8 GB | 50 GB | 1 Gbps |
| NFS Server | 4 vCPU | 8 GB | 1 TB | 1 Gbps |

### OS Prerequisites (All Nodes)

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Set hostnames (run on each node accordingly)
sudo hostnamectl set-hostname odoo-app-01   # change per node

# Add all nodes to /etc/hosts on every machine
sudo tee -a /etc/hosts <<EOF
192.168.1.10  lb-vip
192.168.1.11  haproxy-01
192.168.1.12  haproxy-02
192.168.1.21  odoo-app-01
192.168.1.22  odoo-app-02
192.168.1.31  yb-node-01
192.168.1.32  yb-node-02
192.168.1.33  yb-node-03
192.168.1.41  redis-01
192.168.1.51  nfs-01
EOF

# Install common dependencies
sudo apt install -y curl wget git vim htop net-tools ntp chrony
sudo systemctl enable --now chrony
```

---

## 3. YugabyteDB Active-Active Cluster Setup

YugabyteDB is a distributed SQL database fully compatible with the PostgreSQL wire protocol (YSQL). Its active-active architecture allows every node to serve both reads and writes simultaneously, making it ideal for high-availability Odoo deployments.

### 3.1 Understanding YugabyteDB Internals

YugabyteDB uses the **Raft consensus protocol** to replicate data. With 3 nodes and a replication factor of 3 (RF=3), it can tolerate the loss of 1 node without any data loss or downtime. Each row (tablet) has a Raft leader on one node but can be read from any node (follower reads).

Key components:
- **YB-Master**: Handles metadata, cluster coordination, DDL operations.
- **YB-TServer**: Handles actual data storage and query execution (YSQL listens on port 5433).

### 3.2 Install YugabyteDB on All Three DB Nodes

Run the following on **yb-node-01**, **yb-node-02**, and **yb-node-03**:

```bash
# Install prerequisites
sudo apt install -y python3 python3-pip libssl-dev libffi-dev

# Create yugabyte user
sudo useradd -m -s /bin/bash yugabyte
sudo mkdir -p /opt/yugabyte /data/yugabyte
sudo chown -R yugabyte:yugabyte /opt/yugabyte /data/yugabyte

# Download YugabyteDB (check https://download.yugabyte.com for latest 2.x stable)
YB_VERSION="2.21.1.0"
wget -q "https://downloads.yugabyte.com/releases/${YB_VERSION}/yugabyte-${YB_VERSION}-b545-linux-x86_64.tar.gz" \
  -O /tmp/yugabyte.tar.gz

sudo tar -xzf /tmp/yugabyte.tar.gz -C /opt/yugabyte --strip-components=1
sudo chown -R yugabyte:yugabyte /opt/yugabyte

# Post-install setup (run as yugabyte)
sudo -u yugabyte /opt/yugabyte/bin/post_install.sh
```

### 3.3 Configure Kernel Parameters for YugabyteDB

```bash
sudo tee /etc/sysctl.d/99-yugabyte.conf <<EOF
# Increase max file descriptors
fs.file-max = 1048576

# Network tuning
net.core.somaxconn = 32768
net.ipv4.tcp_max_syn_backlog = 65536
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 30

# Virtual memory
vm.swappiness = 0
vm.dirty_ratio = 5
vm.dirty_background_ratio = 2
EOF

sudo sysctl -p /etc/sysctl.d/99-yugabyte.conf

# Increase ulimits for yugabyte user
sudo tee /etc/security/limits.d/yugabyte.conf <<EOF
yugabyte  soft  nofile  1048576
yugabyte  hard  nofile  1048576
yugabyte  soft  nproc   12000
yugabyte  hard  nproc   12000
EOF
```

### 3.4 Bootstrap the YugabyteDB Cluster

#### Step 1: Start YB-Master on Node 1 (Bootstrap Leader)

```bash
# On yb-node-01 ONLY first
sudo -u yugabyte /opt/yugabyte/bin/yb-master \
  --master_addresses=yb-node-01:7100,yb-node-02:7100,yb-node-03:7100 \
  --rpc_bind_addresses=192.168.1.31:7100 \
  --webserver_interface=192.168.1.31 \
  --webserver_port=7000 \
  --fs_data_dirs=/data/yugabyte/master \
  --replication_factor=3 \
  --logtostderr=false \
  --log_dir=/var/log/yugabyte/master \
  --flagfile=/etc/yugabyte/master.conf \
  >>/var/log/yugabyte/master/master.out 2>&1 &
```

#### Step 2: Create Master Configuration File (All Nodes)

```bash
sudo mkdir -p /etc/yugabyte /var/log/yugabyte/master /var/log/yugabyte/tserver
sudo chown -R yugabyte:yugabyte /var/log/yugabyte /etc/yugabyte

# Master config (adapt IP per node)
sudo tee /etc/yugabyte/master.conf <<EOF
--master_addresses=yb-node-01:7100,yb-node-02:7100,yb-node-03:7100
--replication_factor=3
--fs_data_dirs=/data/yugabyte/master
--log_dir=/var/log/yugabyte/master
--logtostderr=false
--use_cassandra_authentication=false
--enable_ysql=true
EOF

# TServer config (adapt --rpc_bind_addresses per node IP)
sudo tee /etc/yugabyte/tserver.conf <<EOF
--tserver_master_addrs=yb-node-01:7100,yb-node-02:7100,yb-node-03:7100
--fs_data_dirs=/data/yugabyte/tserver
--log_dir=/var/log/yugabyte/tserver
--logtostderr=false
--enable_ysql=true
--pgsql_proxy_bind_address=0.0.0.0:5433
--cql_proxy_bind_address=0.0.0.0:9042
--webserver_port=9000
--ysql_max_connections=500
--ysql_pg_conf_csv=max_connections=500,shared_buffers=8GB,effective_cache_size=24GB,work_mem=64MB,maintenance_work_mem=2GB,checkpoint_completion_target=0.9,wal_buffers=64MB,default_statistics_target=500,random_page_cost=1.1,effective_io_concurrency=200,min_wal_size=2GB,max_wal_size=8GB
EOF
```

#### Step 3: Start All Masters and TServers

Create a systemd service on **each YugabyteDB node**:

```bash
# YB-Master service
sudo tee /etc/systemd/system/yb-master.service <<EOF
[Unit]
Description=YugabyteDB Master
After=network.target
Wants=network.target

[Service]
User=yugabyte
Group=yugabyte
ExecStart=/opt/yugabyte/bin/yb-master --flagfile=/etc/yugabyte/master.conf \
  --rpc_bind_addresses=NODE_IP:7100 \
  --webserver_interface=NODE_IP
Restart=always
RestartSec=5
LimitNOFILE=1048576
LimitNPROC=12000

[Install]
WantedBy=multi-user.target
EOF

# YB-TServer service
sudo tee /etc/systemd/system/yb-tserver.service <<EOF
[Unit]
Description=YugabyteDB TServer
After=network.target yb-master.service
Wants=network.target

[Service]
User=yugabyte
Group=yugabyte
ExecStart=/opt/yugabyte/bin/yb-tserver --flagfile=/etc/yugabyte/tserver.conf \
  --rpc_bind_addresses=NODE_IP:9100 \
  --webserver_interface=NODE_IP
Restart=always
RestartSec=5
LimitNOFILE=1048576
LimitNPROC=12000

[Install]
WantedBy=multi-user.target
EOF
```

> **Important:** Replace `NODE_IP` with the actual IP of each node before enabling the service.

```bash
# On each YB node (replace NODE_IP first!)
sudo sed -i 's/NODE_IP/192.168.1.31/' /etc/systemd/system/yb-master.service
sudo sed -i 's/NODE_IP/192.168.1.31/' /etc/systemd/system/yb-tserver.service
# Use 192.168.1.32 on yb-node-02, 192.168.1.33 on yb-node-03

sudo systemctl daemon-reload
sudo systemctl enable --now yb-master yb-tserver
```

### 3.5 Verify Cluster Health

```bash
# Check master status
/opt/yugabyte/bin/yb-admin \
  --master_addresses=yb-node-01:7100,yb-node-02:7100,yb-node-03:7100 \
  list_all_masters

# Check tablet server status
/opt/yugabyte/bin/yb-admin \
  --master_addresses=yb-node-01:7100,yb-node-02:7100,yb-node-03:7100 \
  list_all_tablet_servers

# Expected output: 3 ALIVE masters, 3 ALIVE tablet servers

# Access YB UI (from browser)
# http://yb-node-01:7000  → Master dashboard
# http://yb-node-01:9000  → TServer dashboard
```

### 3.6 Configure YSQL (PostgreSQL-Compatible Layer)

```bash
# Connect to YSQL on any node
/opt/yugabyte/bin/ysqlsh -h yb-node-01 -p 5433 -U yugabyte

# Set a strong password for the yugabyte superuser
ALTER USER yugabyte WITH PASSWORD 'StrongYBPassword!2024';

# Verify replication is working
SELECT * FROM yb_servers();
```

---

## 4. Preparing the Database for Odoo

Run all commands below on **any one YugabyteDB node** (changes replicate automatically):

```bash
/opt/yugabyte/bin/ysqlsh -h yb-node-01 -p 5433 -U yugabyte -W
```

```sql
-- Create dedicated Odoo database user
CREATE USER odoo WITH PASSWORD 'OdooSecurePass!2024' CREATEDB;

-- Create the Odoo database
CREATE DATABASE odoo19_prod
  OWNER odoo
  ENCODING 'UTF8'
  LC_COLLATE 'en_US.UTF-8'
  LC_CTYPE 'en_US.UTF-8'
  TEMPLATE template0;

-- Grant privileges
GRANT ALL PRIVILEGES ON DATABASE odoo19_prod TO odoo;

-- Connect to the new database and set up extensions
\c odoo19_prod odoo

-- Enable required PostgreSQL extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";
CREATE EXTENSION IF NOT EXISTS "unaccent";
CREATE EXTENSION IF NOT EXISTS "btree_gin";

-- Verify extensions
SELECT extname, extversion FROM pg_extension;
\q
```

### 4.1 Configure YSQL for Odoo Workloads

YugabyteDB YSQL is tuned differently from standard PostgreSQL because it is a distributed system. Add these settings:

```bash
# On all YB TServer nodes, add to tserver.conf
sudo tee -a /etc/yugabyte/tserver.conf <<EOF
--ysql_pg_conf_csv=max_connections=300,idle_in_transaction_session_timeout=30000,statement_timeout=600000,lock_timeout=30000,deadlock_timeout=1000,log_min_duration_statement=2000
EOF

sudo systemctl restart yb-tserver
```

### 4.2 Firewall Rules for YugabyteDB

```bash
# On all YB nodes - open required ports
sudo ufw allow from 192.168.1.0/24 to any port 5433 comment "YSQL"
sudo ufw allow from 192.168.1.0/24 to any port 7100 comment "YB-Master RPC"
sudo ufw allow from 192.168.1.0/24 to any port 9100 comment "YB-TServer RPC"
sudo ufw allow from 192.168.1.0/24 to any port 7000 comment "YB-Master Web UI"
sudo ufw allow from 192.168.1.0/24 to any port 9000 comment "YB-TServer Web UI"
sudo ufw allow from 192.168.1.0/24 to any port 6379 comment "Redis"
sudo ufw enable
```

---

## 5. Shared Storage Setup

Odoo stores user-uploaded files, attachments, and generated reports in its `filestore` directory. In a cluster, all nodes must access the same filestore. NFS is the simplest option; GlusterFS provides high availability.

### 5.1 NFS Server Setup (on nfs-01)

```bash
sudo apt install -y nfs-kernel-server

# Create shared directory
sudo mkdir -p /export/odoo/filestore
sudo chown -R 1001:1001 /export/odoo   # UID/GID of the odoo user

# Configure NFS exports
sudo tee /etc/exports <<EOF
/export/odoo  192.168.1.21(rw,sync,no_subtree_check,no_root_squash) \
              192.168.1.22(rw,sync,no_subtree_check,no_root_squash)
EOF

sudo exportfs -rav
sudo systemctl enable --now nfs-kernel-server

# Verify
showmount -e localhost
```

### 5.2 NFS Client Mount (on each Odoo App Node)

```bash
sudo apt install -y nfs-common

# Create mount point
sudo mkdir -p /mnt/odoo-filestore

# Mount NFS share
sudo tee -a /etc/fstab <<EOF
nfs-01:/export/odoo/filestore  /mnt/odoo-filestore  nfs  rw,hard,intr,rsize=65536,wsize=65536,timeo=14,_netdev  0  0
EOF

sudo mount -a
df -h | grep odoo-filestore
```

---

## 6. Installing Odoo 19 on Each Application Node

Perform these steps on **odoo-app-01** and **odoo-app-02** identically.

### 6.1 Install System Dependencies

```bash
sudo apt update && sudo apt install -y \
  python3 python3-pip python3-venv python3-dev \
  libxml2-dev libxslt1-dev libldap2-dev libsasl2-dev \
  libssl-dev libpq-dev libjpeg-dev libffi-dev \
  node-less npm git build-essential \
  wkhtmltopdf xfonts-75dpi xfonts-base \
  fonts-liberation fonts-open-sans \
  postgresql-client-16

# Install wkhtmltopdf with patched Qt (required for PDF reports)
wget -q https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/\
wkhtmltox_0.12.6.1-3.jammy_amd64.deb -O /tmp/wkhtmltox.deb
sudo dpkg -i /tmp/wkhtmltox.deb || sudo apt install -f -y

# Verify wkhtmltopdf
wkhtmltopdf --version
```

### 6.2 Create Odoo System User

```bash
sudo useradd -m -d /opt/odoo -U -r -s /bin/bash odoo
sudo usermod -u 1001 odoo   # Match NFS UID
```

### 6.3 Clone Odoo 19 Source

```bash
sudo -u odoo bash -c "
  git clone --depth=1 --branch=19.0 \
    https://github.com/odoo/odoo.git \
    /opt/odoo/odoo19
"

# If Odoo 19 is not yet publicly released, use the enterprise or community beta:
# git clone --branch saas-17.4 https://github.com/odoo/odoo.git /opt/odoo/odoo19
```

### 6.4 Python Virtual Environment & Dependencies

```bash
sudo -u odoo bash -c "
  python3 -m venv /opt/odoo/venv19
  source /opt/odoo/venv19/bin/activate
  pip install --upgrade pip wheel setuptools
  pip install -r /opt/odoo/odoo19/requirements.txt

  # Additional packages for cluster/production use
  pip install gevent psutil redis hiredis greenlet
"
```

### 6.5 Create Odoo Directory Structure

```bash
sudo -u odoo bash -c "
  mkdir -p /opt/odoo/{logs,sessions,custom_addons}
"

# Link the NFS filestore
sudo -u odoo ln -s /mnt/odoo-filestore /opt/odoo/filestore

# Set permissions
sudo chown -R odoo:odoo /opt/odoo
sudo chmod 750 /opt/odoo/logs /opt/odoo/sessions
```

---

## 7. Configuring Odoo for Cluster Mode

### 7.1 Create Odoo Configuration File

Create `/etc/odoo/odoo19.conf` on **each app node**. The content is identical except where noted.

```bash
sudo mkdir -p /etc/odoo
sudo tee /etc/odoo/odoo19.conf <<EOF
[options]

; ── Database ────────────────────────────────────────────────────────────────
; Connect to any YugabyteDB node (or use a VIP/pgbouncer in front)
db_host = yb-node-01
db_port = 5433
db_name = odoo19_prod
db_user = odoo
db_password = OdooSecurePass!2024
db_maxconn = 64

; ── Application Server ───────────────────────────────────────────────────────
http_interface = 0.0.0.0
http_port = 8069
longpolling_port = 8072
proxy_mode = True

; Workers (set to 2 × CPU cores for prod)
workers = 16
max_cron_threads = 2
limit_time_cpu = 600
limit_time_real = 1200
limit_memory_hard = 2684354560
limit_memory_soft = 2147483648
limit_request = 8192

; ── Session Storage (Redis) ──────────────────────────────────────────────────
; Required for sticky-session-free clustering
session_redis_host = redis-01
session_redis_port = 6379
session_redis_password = RedisSecurePass!2024
session_redis_db = 0
session_redis_prefix = odoo19_

; ── File Storage ─────────────────────────────────────────────────────────────
data_dir = /opt/odoo/filestore

; ── Logging ──────────────────────────────────────────────────────────────────
logfile = /opt/odoo/logs/odoo.log
log_level = info
log_handler = :INFO
logrotate = True

; ── Add-ons ──────────────────────────────────────────────────────────────────
addons_path = /opt/odoo/odoo19/addons,/opt/odoo/custom_addons

; ── Security ─────────────────────────────────────────────────────────────────
admin_passwd = $pbkdf2-sha512$...  ; generated with: python3 -c "from passlib.context import CryptContext; print(CryptContext(['pbkdf2_sha512']).hash('YourMasterPassword'))"

; ── Gevent / Async ───────────────────────────────────────────────────────────
; gevent is required for longpolling workers
gevent_port = 8072

EOF

sudo chown root:odoo /etc/odoo/odoo19.conf
sudo chmod 640 /etc/odoo/odoo19.conf
```

### 7.2 Generate the Admin Master Password Hash

```bash
sudo -u odoo /opt/odoo/venv19/bin/python3 -c "
from passlib.context import CryptContext
ctx = CryptContext(['pbkdf2_sha512'])
print(ctx.hash('YourMasterPassword123!'))
"
# Paste the output as the admin_passwd value in odoo19.conf
```

### 7.3 Database Connection Pooling with PgBouncer

To protect YugabyteDB from connection storms, deploy PgBouncer in front of YSQL on each Odoo node:

```bash
sudo apt install -y pgbouncer

sudo tee /etc/pgbouncer/pgbouncer.ini <<EOF
[databases]
odoo19_prod = host=yb-node-01 port=5433 dbname=odoo19_prod

; Fallback/round-robin to other YB nodes
* = host=yb-node-01,yb-node-02,yb-node-03 port=5433

[pgbouncer]
listen_addr = 127.0.0.1
listen_port = 6432
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt
pool_mode = transaction
max_client_conn = 500
default_pool_size = 40
reserve_pool_size = 10
reserve_pool_timeout = 3
server_reset_query = DISCARD ALL
server_check_query = SELECT 1
server_check_delay = 30
ignore_startup_parameters = extra_float_digits
logfile = /var/log/pgbouncer/pgbouncer.log
pidfile = /var/run/pgbouncer/pgbouncer.pid
EOF

# Create userlist
sudo tee /etc/pgbouncer/userlist.txt <<EOF
"odoo" "OdooSecurePass!2024"
EOF

sudo systemctl enable --now pgbouncer
```

Update `db_host` and `db_port` in `odoo19.conf` to use PgBouncer:

```ini
db_host = 127.0.0.1
db_port = 6432
```

---

## 8. Load Balancer Configuration (HAProxy)

### 8.1 Install HAProxy and Keepalived

```bash
# On haproxy-01 and haproxy-02
sudo apt install -y haproxy keepalived
```

### 8.2 HAProxy Configuration

```bash
sudo tee /etc/haproxy/haproxy.cfg <<'EOF'
global
    log /dev/log local0
    log /dev/log local1 notice
    chroot /var/lib/haproxy
    stats socket /run/haproxy/admin.sock mode 660 level admin
    stats timeout 30s
    user haproxy
    group haproxy
    daemon
    maxconn 50000
    tune.ssl.default-dh-param 2048

defaults
    log     global
    mode    http
    option  httplog
    option  dontlognull
    option  forwardfor
    option  http-server-close
    timeout connect 5s
    timeout client  60s
    timeout server  60s
    errorfile 400 /etc/haproxy/errors/400.http
    errorfile 503 /etc/haproxy/errors/503.http

# ── Stats Dashboard ───────────────────────────────────────────────────────────
listen stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
    stats auth admin:HAProxyAdmin!2024
    stats show-legends
    stats show-node

# ── Odoo HTTP Frontend ────────────────────────────────────────────────────────
frontend odoo_http_front
    bind *:80
    bind *:443 ssl crt /etc/ssl/odoo/odoo.pem
    http-request redirect scheme https unless { ssl_fc }
    http-request set-header X-Forwarded-Proto https
    http-request set-header X-Real-IP %[src]

    # Route longpolling to dedicated backend
    acl is_longpoll path_beg /longpolling
    use_backend odoo_longpoll if is_longpoll
    default_backend odoo_web

# ── Odoo Web Backend ──────────────────────────────────────────────────────────
backend odoo_web
    balance leastconn
    option httpchk GET /web/health
    http-check expect status 200

    # Sticky sessions based on cookie (fallback when Redis is unavailable)
    cookie SERVERID insert indirect nocache

    server odoo-app-01 192.168.1.21:8069 check inter 3s rise 2 fall 3 cookie app01
    server odoo-app-02 192.168.1.22:8069 check inter 3s rise 2 fall 3 cookie app02

# ── Odoo Longpolling Backend ─────────────────────────────────────────────────
backend odoo_longpoll
    balance source
    option httpchk GET /web/health
    http-check expect status 200
    timeout tunnel 3600s

    server odoo-app-01 192.168.1.21:8072 check inter 5s rise 2 fall 3
    server odoo-app-02 192.168.1.22:8072 check inter 5s rise 2 fall 3

EOF

sudo systemctl enable --now haproxy
sudo haproxy -c -f /etc/haproxy/haproxy.cfg   # Validate config
```

### 8.3 Keepalived for HAProxy VIP Failover

```bash
# On haproxy-01 (MASTER)
sudo tee /etc/keepalived/keepalived.conf <<EOF
global_defs {
    notification_email { admin@example.com }
    notification_email_from keepalived@haproxy-01
    smtp_server 127.0.0.1
    smtp_connect_timeout 30
    router_id haproxy_01
    vrrp_garp_interval 0
    vrrp_gna_interval 0
}

vrrp_script check_haproxy {
    script "killall -0 haproxy"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 200
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass KeepAliveSecret
    }
    virtual_ipaddress {
        192.168.1.10/24 dev eth0 label eth0:vip
    }
    track_script {
        check_haproxy
    }
}
EOF

sudo systemctl enable --now keepalived
```

```bash
# On haproxy-02 (BACKUP) - same config but state BACKUP, priority 100
sudo sed 's/MASTER/BACKUP/; s/priority 200/priority 100/' \
  /etc/keepalived/keepalived.conf > /tmp/kconf && \
  sudo cp /tmp/kconf /etc/keepalived/keepalived.conf
```

### 8.4 SSL Certificate Setup

```bash
sudo mkdir -p /etc/ssl/odoo

# Self-signed for testing (replace with Let's Encrypt or CA cert in production)
sudo openssl req -x509 -nodes -days 365 -newkey rsa:4096 \
  -keyout /etc/ssl/odoo/odoo.key \
  -out /etc/ssl/odoo/odoo.crt \
  -subj "/C=US/ST=CA/O=MyCompany/CN=odoo.example.com"

# HAProxy expects key + cert in single PEM
sudo cat /etc/ssl/odoo/odoo.crt /etc/ssl/odoo/odoo.key | \
  sudo tee /etc/ssl/odoo/odoo.pem > /dev/null

sudo chmod 600 /etc/ssl/odoo/odoo.pem
sudo systemctl reload haproxy
```

---

## 9. Redis for Session Management

Redis is essential in a cluster so that any Odoo node can serve any session without requiring sticky sessions on the load balancer.

```bash
# On redis-01
sudo apt install -y redis-server

sudo tee -a /etc/redis/redis.conf <<EOF
bind 0.0.0.0
requirepass RedisSecurePass!2024
maxmemory 2gb
maxmemory-policy allkeys-lru
save 900 1
save 300 10
save 60 10000
EOF

sudo systemctl enable --now redis-server

# Test from Odoo node
redis-cli -h redis-01 -p 6379 -a RedisSecurePass!2024 ping
# Expected: PONG
```

### 9.1 Install Redis Python Module in Odoo venv

```bash
sudo -u odoo bash -c "
  source /opt/odoo/venv19/bin/activate
  pip install redis hiredis
"
```

---

## 10. Systemd Service & Auto-start

Create systemd service on **each Odoo app node**:

```bash
sudo tee /etc/systemd/system/odoo19.service <<EOF
[Unit]
Description=Odoo 19 Community
Documentation=https://www.odoo.com
After=network.target postgresql.service

[Service]
Type=simple
User=odoo
Group=odoo
SyslogIdentifier=odoo19
PermissionsStartOnly=true
ExecStart=/opt/odoo/venv19/bin/python3 /opt/odoo/odoo19/odoo-bin \
  --config /etc/odoo/odoo19.conf \
  --logfile /opt/odoo/logs/odoo.log
StandardOutput=journal+console
Restart=on-failure
RestartSec=5
KillMode=mixed

# Resource limits
LimitNOFILE=65536
LimitNPROC=4096
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now odoo19

# Check status
sudo systemctl status odoo19
sudo journalctl -u odoo19 -f
```

### 10.1 Database Initialization (First Run Only)

Run this **once** from odoo-app-01 only:

```bash
sudo -u odoo /opt/odoo/venv19/bin/python3 /opt/odoo/odoo19/odoo-bin \
  --config /etc/odoo/odoo19.conf \
  --init base \
  --stop-after-init \
  --log-level=info

# Verify DB was created
/opt/yugabyte/bin/ysqlsh -h yb-node-01 -p 5433 -U odoo -d odoo19_prod -c "\dt" | head -20
```

---

## 11. Health Checks & Monitoring

### 11.1 Odoo Health Endpoint

```bash
# Test from any node or load balancer
curl -s http://192.168.1.21:8069/web/health
# Expected: {"status": "pass"}
```

### 11.2 YugabyteDB Health Check Script

```bash
sudo tee /usr/local/bin/check-yugabyte.sh <<'EOF'
#!/bin/bash
MASTERS="yb-node-01:7100,yb-node-02:7100,yb-node-03:7100"
ALIVE=$(/opt/yugabyte/bin/yb-admin --master_addresses=$MASTERS \
  list_all_masters 2>/dev/null | grep -c "ALIVE")

if [ "$ALIVE" -lt 2 ]; then
    echo "CRITICAL: Only $ALIVE YB masters alive!"
    exit 2
elif [ "$ALIVE" -lt 3 ]; then
    echo "WARNING: Only $ALIVE YB masters alive"
    exit 1
else
    echo "OK: $ALIVE YB masters alive"
    exit 0
fi
EOF
chmod +x /usr/local/bin/check-yugabyte.sh
```

### 11.3 Prometheus + Grafana Integration

YugabyteDB exposes Prometheus metrics natively:

```bash
# YB metrics endpoint (no extra setup needed)
curl http://yb-node-01:9000/prometheus-metrics | head -50

# Prometheus scrape config
cat >> /etc/prometheus/prometheus.yml <<EOF
  - job_name: 'yugabytedb_tserver'
    static_configs:
      - targets:
          - 'yb-node-01:9000'
          - 'yb-node-02:9000'
          - 'yb-node-03:9000'
    metrics_path: /prometheus-metrics

  - job_name: 'yugabytedb_master'
    static_configs:
      - targets:
          - 'yb-node-01:7000'
          - 'yb-node-02:7000'
          - 'yb-node-03:7000'
    metrics_path: /prometheus-metrics
EOF
```

---

## 12. Backup Strategy

### 12.1 YugabyteDB Backup

```bash
# Distributed backup using yb-admin (backs up entire cluster)
/opt/yugabyte/bin/yb-admin \
  --master_addresses=yb-node-01:7100,yb-node-02:7100,yb-node-03:7100 \
  create_snapshot_schedule \
  1440 \   # Interval in minutes (24h)
  10080 \  # Retention in minutes (7 days)
  ysql.odoo19_prod

# List snapshots
/opt/yugabyte/bin/yb-admin \
  --master_addresses=yb-node-01:7100,yb-node-02:7100,yb-node-03:7100 \
  list_snapshots

# Export snapshot to S3/NFS (PITR)
/opt/yugabyte/bin/yb-admin \
  --master_addresses=yb-node-01:7100,yb-node-02:7100,yb-node-03:7100 \
  create_snapshot ysql.odoo19_prod
```

### 12.2 Logical Backup (pg_dump via YSQL)

```bash
# From any YugabyteDB node or a machine with pg_dump
pg_dump \
  -h yb-node-01 \
  -p 5433 \
  -U odoo \
  -Fc \
  -f /backup/odoo19_prod_$(date +%Y%m%d_%H%M%S).dump \
  odoo19_prod

# Schedule daily with cron
echo "0 2 * * * odoo pg_dump -h yb-node-01 -p 5433 -U odoo -Fc -f /backup/odoo_\$(date +\%Y\%m\%d).dump odoo19_prod" \
  | sudo tee /etc/cron.d/odoo-backup
```

### 12.3 Filestore Backup

```bash
# Rsync filestore to backup server nightly
rsync -avz --delete /mnt/odoo-filestore/ backup-server:/backup/odoo-filestore/
```

---

## 13. Troubleshooting

### Odoo Cannot Connect to YugabyteDB

```bash
# Test YSQL connectivity from Odoo node
psql -h yb-node-01 -p 5433 -U odoo -d odoo19_prod -c "SELECT version();"

# Check PgBouncer
sudo systemctl status pgbouncer
psql -h 127.0.0.1 -p 6432 -U odoo -d odoo19_prod -c "SELECT 1;"

# Check YB TServer logs
sudo journalctl -u yb-tserver --since "10 minutes ago"
tail -f /var/log/yugabyte/tserver/postgresql*.log
```

### YugabyteDB Node Is Down

```bash
# Check which master is leader
/opt/yugabyte/bin/yb-admin \
  --master_addresses=yb-node-01:7100,yb-node-02:7100,yb-node-03:7100 \
  list_all_masters

# Force leader election if needed
/opt/yugabyte/bin/yb-admin \
  --master_addresses=yb-node-01:7100,yb-node-02:7100,yb-node-03:7100 \
  master_leader_stepdown

# Re-add a replacement node
/opt/yugabyte/bin/yb-admin \
  --master_addresses=yb-node-01:7100,yb-node-02:7100,yb-node-03:7100 \
  change_master_config ADD_SERVER yb-node-04 7100
```

### Odoo Workers Crashing (OOM)

```bash
# Check memory usage
sudo journalctl -u odoo19 | grep "Worker"

# Reduce workers and memory limits in odoo19.conf
workers = 8
limit_memory_soft = 1610612736   # 1.5GB
limit_memory_hard = 2147483648   # 2GB

sudo systemctl restart odoo19
```

### Session Issues (Users Getting Logged Out)

```bash
# Verify Redis is reachable from all Odoo nodes
redis-cli -h redis-01 -p 6379 -a RedisSecurePass!2024 ping

# Check Odoo session config
grep -i redis /etc/odoo/odoo19.conf

# List active sessions
redis-cli -h redis-01 -p 6379 -a RedisSecurePass!2024 keys "odoo19_*" | wc -l
```

### Filestore Access Denied

```bash
# Check NFS mount
mount | grep odoo-filestore
ls -la /mnt/odoo-filestore

# Re-mount if disconnected
sudo umount /mnt/odoo-filestore
sudo mount -a

# Check NFS server
sudo exportfs -v
sudo systemctl status nfs-kernel-server
```

---

## Summary Checklist

Before going to production, verify each item:

- [ ] YugabyteDB cluster shows 3/3 masters ALIVE and 3/3 tservers ALIVE
- [ ] `yb_servers()` returns all 3 nodes from YSQL
- [ ] Odoo database initialized and accessible from both app nodes
- [ ] NFS filestore mounted on both app nodes (same UID/GID)
- [ ] Redis responding to PING from both app nodes
- [ ] PgBouncer running on both app nodes, connecting to YugabyteDB
- [ ] Both Odoo services running and healthy (`/web/health` returns 200)
- [ ] HAProxy distributing traffic across both app nodes
- [ ] Keepalived VIP floating correctly (test by stopping haproxy-01)
- [ ] Snapshots and pg_dump backup jobs scheduled and tested
- [ ] Monitoring dashboards showing all YugabyteDB and Odoo metrics
- [ ] Firewall rules locked down to internal subnet only
- [ ] SSL certificate installed and HTTPS enforced

---

*This document covers deployment on Ubuntu 24.04 LTS. Adjust package names and paths for RHEL/Rocky Linux deployments. Always test in a staging environment before applying to production.*
