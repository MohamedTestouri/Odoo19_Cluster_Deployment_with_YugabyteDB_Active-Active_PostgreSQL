# Odoo 19 Cluster — Setup Scripts

Automated setup scripts for deploying Odoo 19 on a multi-node cluster backed by a YugabyteDB active-active PostgreSQL cluster.

---

## Quick Start

```bash
# 1. Clone / copy this folder to every node
# 2. Edit .env with your actual IPs, passwords, and settings
# 3. Follow the execution order below, one script per role
```

---

## File Structure

```
odoo19-cluster-scripts/
├── .env                          ← ALL variables (edit this first!)
├── lib/
│   └── common.sh                 ← Shared logging, helpers (auto-sourced)
│
├── 00-preflight.sh               ← Pre-flight checks (any node)
├── 01-common-setup.sh            ← OS baseline (ALL nodes)
│
├── 02-yugabytedb-install.sh      ← YB install    (yb-node-01/02/03)
├── 03-yugabytedb-cluster-init.sh ← YB bootstrap  (yb-node-01/02/03)
├── 04-yugabytedb-db-setup.sh     ← Odoo DB setup (yb-node-01 only)
│
├── 05-nfs-server.sh              ← NFS server    (nfs-01)
├── 06-nfs-client.sh              ← NFS mount     (odoo-app-01/02)
│
├── 07-redis-setup.sh             ← Redis setup   (redis-01)
│
├── 08-odoo-install.sh            ← Odoo install  (odoo-app-01/02)
├── 09-pgbouncer-setup.sh         ← PgBouncer     (odoo-app-01/02)
├── 10-haproxy-setup.sh           ← HAProxy + VIP (haproxy-01/02)
├── 11-odoo-service.sh            ← Start Odoo    (odoo-app-01/02)
│
├── 12-health-check.sh            ← Full health check (any node)
└── 13-backup.sh                  ← Backup DB + files (any node)
```

---

## Step-by-Step Execution Order

### 0. Configure Variables

```bash
# Copy and edit .env on EVERY node
cp .env /root/.env
nano /root/.env   # Set your IPs, passwords, versions
```

### 1. Pre-flight (all nodes)

```bash
# Run on every node before anything else
sudo bash 00-preflight.sh --node-type=yugabyte    # on YB nodes
sudo bash 00-preflight.sh --node-type=odoo        # on Odoo nodes
sudo bash 00-preflight.sh                          # on all others
```

### 2. Common OS Setup (all nodes)

```bash
# Run on EVERY node
sudo bash 01-common-setup.sh
```

### 3. YugabyteDB Setup (yb-node-01, yb-node-02, yb-node-03)

```bash
# Run on each YB node independently
sudo bash 02-yugabytedb-install.sh

# After install completes on ALL 3 nodes, run on each:
sudo bash 03-yugabytedb-cluster-init.sh

# Once cluster is healthy, run ONCE on yb-node-01:
sudo bash 04-yugabytedb-db-setup.sh
```

### 4. NFS (nfs-01 first, then Odoo nodes)

```bash
# On nfs-01:
sudo bash 05-nfs-server.sh

# On odoo-app-01 AND odoo-app-02:
sudo bash 06-nfs-client.sh
```

### 5. Redis (redis-01)

```bash
sudo bash 07-redis-setup.sh
```

### 6. Odoo Application Nodes (odoo-app-01 AND odoo-app-02)

```bash
# Install Odoo + configure (both nodes)
sudo bash 08-odoo-install.sh

# Install PgBouncer + connect to YugabyteDB (both nodes)
sudo bash 09-pgbouncer-setup.sh

# Start Odoo service
# On odoo-app-01 (initializes DB first):
sudo bash 11-odoo-service.sh --init-db

# On odoo-app-02 (DB already initialized):
sudo bash 11-odoo-service.sh
```

### 7. Load Balancer (haproxy-01 AND haproxy-02)

```bash
# Auto-detects MASTER vs BACKUP based on IP
sudo bash 10-haproxy-setup.sh
```

### 8. Verify

```bash
# Full cluster health check
bash 12-health-check.sh

# Watch mode (refreshes every 30s)
bash 12-health-check.sh --watch

# JSON output (for monitoring integrations)
bash 12-health-check.sh --json
```

### 9. Schedule Backups

```bash
# Add to root crontab
echo "0 2 * * * root bash /path/to/13-backup.sh --full >> /var/log/odoo-backup.log 2>&1" \
  | sudo tee /etc/cron.d/odoo-backup
```

---

## .env Variable Reference

| Variable | Description | Example |
|---|---|---|
| `VIP_IP` | Floating VIP for load balancers | `192.168.1.10` |
| `YB_NODE1_IP` / `_HOST` | YugabyteDB node 1 | `192.168.1.31` |
| `YB_VERSION` | YugabyteDB version | `2.21.1.0` |
| `YB_YSQL_PORT` | PostgreSQL-compatible port | `5433` |
| `DB_SUPERUSER_PASS` | YugabyteDB superuser password | strong password |
| `DB_ODOO_PASS` | Odoo DB user password | strong password |
| `DB_ODOO_NAME` | Odoo database name | `odoo19_prod` |
| `REDIS_PASS` | Redis auth password | strong password |
| `ODOO_MASTER_PASS` | Odoo admin master password | strong password |
| `ODOO_WORKERS` | Worker process count (2×CPUs) | `16` |
| `INTERNAL_SUBNET` | CIDR for firewall rules | `192.168.1.0/24` |
| `CLUSTER_DOMAIN` | Public domain for SSL cert | `odoo.example.com` |

---

## Common Operations

```bash
# Restart Odoo on a node
sudo systemctl restart odoo19

# Restart all cluster services
sudo systemctl restart yb-master yb-tserver   # on YB nodes
sudo systemctl restart odoo19                 # on app nodes
sudo systemctl restart haproxy keepalived     # on LB nodes

# View Odoo logs
journalctl -u odoo19 -f
tail -f /opt/odoo/logs/odoo.log

# View YugabyteDB logs
journalctl -u yb-tserver -f

# Manual backup
sudo bash 13-backup.sh --full

# Check cluster status (yb-admin)
/opt/yugabyte/bin/yb-admin \
  --master_addresses=yb-node-01:7100,yb-node-02:7100,yb-node-03:7100 \
  list_all_masters
```

---

## Troubleshooting

| Problem | Command |
|---|---|
| Odoo won't start | `journalctl -u odoo19 -n 50` |
| DB connection failed | `psql -h 127.0.0.1 -p 6432 -U odoo -d odoo19_prod` |
| YB node down | `systemctl status yb-master yb-tserver` |
| NFS mount lost | `sudo mount -a` |
| Redis unreachable | `redis-cli -h redis-01 -p 6379 -a $PASS ping` |
| VIP not floating | `systemctl status keepalived` |

---

> All scripts are idempotent — safe to re-run after fixing issues.
> All passwords and secrets live exclusively in `.env` — add it to `.gitignore`.
