# TAP DevOps — The Apprentice Project

Internal DevOps dashboard and deployment system for managing TAP services.

---

## Architecture

```
tap-devops/              ← repo & install root
├── dashboard/           ← Node.js server source
│   ├── server.js        ← Express + WebSocket app
│   ├── db.js            ← SQLite (better-sqlite3)
│   ├── ssh.js           ← SSH/deploy runner (node-ssh)
│   ├── github.js        ← GitHub API helpers
│   └── public/
│       └── index.html   ← Single-page dashboard UI
├── setup/
│   ├── setup-das.sh     ← Dashboard installer
│   ├── setup-plg.sh     ← PLG service deployer
│   ├── setup-rag.sh     ← RAG service deployer
│   └── setup-lms.sh     ← LMS service deployer
├── data/
│   ├── tap.db           ← App registry + deploy history
│   ├── envs/            ← Per-app .env files
│   └── keys/            ← Uploaded SSH keys (.pem)
└── config.env           ← Master config (all services)
```

---

## Services

| ID    | Name                  | Stack                        | Default Port |
|-------|-----------------------|------------------------------|--------------|
| `das` | DevOps Dashboard      | Node 20, Express, SQLite     | 9000         |
| `plg` | Plagiarism Checker    | Python 3.11, FastAPI, Podman | 8006         |
| `rag` | RAG Service           | Python 3.10, Frappe, Gunicorn| 8005         |
| `lms` | LMS                   | Python 3.11, Frappe, Gunicorn| 8004         |

---

## Config (`config.env`)

One flat file drives all services. Variables are namespaced by prefix.

| Prefix              | Covers                                    |
|---------------------|-------------------------------------------|
| `DASHBOARD_`        | Dashboard host, port, PEM, session secret |
| `PLG_`              | Plagiarism server, DB, RabbitMQ, Redis, CLIP model, thresholds |
| `RAG_`              | RAG server, Frappe, Postgres, Redis, RabbitMQ, LLM API keys |
| `LMS_`              | LMS server, Frappe, Postgres, Redis       |
| `GITHUB_TOKEN`      | Shared GitHub API token                   |
| `SESSION_SECRET`    | Dashboard session signing key             |

Key vars to set before first deploy:

```env
DASHBOARD_SERVER_HOST=<GCP external IP>
DASHBOARD_PEM_FILE=/path/to/key.pem
SESSION_SECRET=<random 32+ char string>
GITHUB_TOKEN=<token>

PLG_SERVER_HOST=<IP>
PLG_POSTGRES_PASSWORD=<secure>
PLG_RABBITMQ_PASS=<secure>
PLG_DEPLOY_SECRET_KEY=<random>

RAG_SERVER_HOST=<IP>
RAG_POSTGRES_PASSWORD=<secure>
RAG_LLM_API_KEY=<groq key>
RAG_DEPLOY_SECRET_KEY=<random>

LMS_SERVER_HOST=<IP>
LMS_POSTGRES_PASSWORD=<secure>
LMS_DEPLOY_SECRET_KEY=<random>
```

---

## Dashboard Setup (`setup-das.sh`)

Installs the Node dashboard as a systemd user service on the current machine.

```bash
# First install
./setup/setup-das.sh --force

# Update files + restart
./setup/setup-das.sh --update

# Replace scripts only (no restart)
./setup/setup-das.sh --upload

# Restart service only
./setup/setup-das.sh --restart

# Wipe everything
./setup/setup-das.sh --clean-only

# Preview without executing
./setup/setup-das.sh --dry-run
```

**Systemd service:** `tap-dashboard.service` (user scope)
**Node:** isolated via nvm (`~/.nvm`), version 20
**Logs:** `journalctl --user -u tap-dashboard.service -f`

---

## Service Deployment (`setup-plg.sh` / `setup-rag.sh` / `setup-lms.sh`)

All deployers run over SSH from the dashboard machine to the target server.
Config is read from `config.env` and injected as environment exports.

```bash
# Full deploy (all steps)
./setup/setup-plg.sh

# Partial steps
./setup/setup-plg.sh --steps 4-6

# Code update + service restart only
./setup/setup-plg.sh --update

# Config re-write + restart only
./setup/setup-plg.sh --update-config

# Restart all services
./setup/setup-plg.sh --restart

# Stop all services
./setup/setup-plg.sh --stop

# Status / health check
./setup/setup-plg.sh --status

# Full wipe (services, containers, volumes, dirs)
./setup/setup-plg.sh --clean-only

# Selective wipe
./setup/setup-plg.sh --clean-services --clean-containers

# Dry run
./setup/setup-plg.sh --dry-run
```

All flags also accepted as env vars: `PLG_UPDATE_ONLY=true ./setup/setup-plg.sh`

---

## Deploy Steps (PLG — representative)

| Step | Action                                          |
|------|-------------------------------------------------|
| 1    | System packages (apt)                           |
| 2    | cgroup delegation for rootless Podman           |
| 3    | Podman registry config (docker.io)              |
| 4    | Clone / pull git repo                           |
| 5    | Python venv + pip install requirements.txt      |
| 6    | Write `.env` from config                        |
| 7    | Pull container images (Postgres, RabbitMQ, Redis)|
| 8    | Download CLIP model (optional, skippable)       |
| 9    | Redis containers (cache + queue) via systemd    |
| 10   | Postgres container via systemd                  |
| 11   | Systemd units: RabbitMQ, plg-app, plg-api       |
| 12   | Firewall: open API port via ufw                 |
| 13   | Health check + service status                   |

Run a subset: `--steps 4,6,11` or `--steps 9-13`

---

## Containers (PLG)

| Name               | Image                        | Port (host→container)  |
|--------------------|------------------------------|------------------------|
| `plg-postgres`     | ankane/pgvector:latest       | 127.0.0.1:5436→5432    |
| `plg-rabbitmq`     | rabbitmq:3-management-alpine | 127.0.0.1:5674→5672    |
| `plg-redis-cache`  | redis:7-alpine               | 127.0.0.1:13000→6379   |
| `plg-redis-queue`  | redis:7-alpine               | 127.0.0.1:11000→6379   |

All containers run rootless via Podman under the app user.

---

## Systemd Services

### Dashboard machine
| Service              | Description              |
|----------------------|--------------------------|
| `tap-dashboard`      | Node.js dashboard server |

### PLG machine
| Service              | Description              |
|----------------------|--------------------------|
| `plg-postgres`       | Postgres (Podman)        |
| `plg-rabbitmq`       | RabbitMQ (Podman)        |
| `plg-redis-cache`    | Redis cache (Podman)     |
| `plg-redis-queue`    | Redis queue (Podman)     |
| `plg-app`            | Plagiarism worker        |
| `plg-api`            | FastAPI server           |

### RAG / LMS machines
Similar pattern: Postgres, Redis ×2, RabbitMQ containers + Frappe bench processes.

---

## Monitoring

### Service health
```bash
# All PLG services at once
./setup/setup-plg.sh --status

# Individual service journal
journalctl --user -u plg-app.service -n 50 --no-pager
journalctl --user -u plg-api.service -n 50 --no-pager
journalctl --user -u tap-dashboard.service -f

# Container status
podman ps
podman logs plg-postgres --tail 30
```

### Dashboard UI
The web dashboard polls all configured apps every `STATUS_POLL_INTERVAL_SECONDS` (default 60s) via SSH and displays:
- Per-app service status
- Port health probes (TCP connect)
- Deploy history + live log streaming
- GitHub branch info + recent commits

### Deploy logs
```
~/tap-devops/data/         ← SQLite deploy history
<app-dir>/observer/logs/   ← Per-service deployment JSONL log
/var/log/tap/<service>/    ← Rotating app logs (configurable)
```

---

## Webhook Deploys

Each app exposes a webhook endpoint on the dashboard:

```
POST /api/webhook/<app_id>/deploy
Header: x-deploy-key: <APP_DEPLOY_SECRET_KEY>
```

Triggers `--update --force --no-wait` on the remote setup script.

---

## SSH Key Management

Keys are stored in `data/keys/` (chmod 600).
Upload via dashboard UI or API:

```bash
curl -X POST http://localhost:9000/api/keys/upload \
  -H "Cookie: <session>" \
  -F "keyfile=@/path/to/key.pem" \
  -F "name=my-key"
```

---

## Common Operations

```bash
# Check dashboard is running
curl http://localhost:9000/api/auth/status

# Restart dashboard
systemctl --user restart tap-dashboard.service

# Re-deploy PLG after config change
./setup/setup-plg.sh --update-config

# Pull latest code + restart PLG
./setup/setup-plg.sh --update

# Full PLG redeploy from step 4 onwards (skip infra)
./setup/setup-plg.sh --clean-venv --steps 4-13

# View all registered apps in DB
sqlite3 ~/tap-devops/data/tap.db 'SELECT app_id, app_name, server_host FROM apps;'
```