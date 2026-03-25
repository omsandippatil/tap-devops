#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CWD="$(pwd)"

_find_config() {
    local dir="$1"
    local depth=0
    while [[ "$dir" != "/" && $depth -lt 5 ]]; do
        if [[ -f "${dir}/config.env" ]]; then
            echo "${dir}/config.env"
            return 0
        fi
        dir="$(dirname "$dir")"
        depth=$((depth + 1))
    done
    return 1
}

CONFIG_FILE=""
if [[ -f "${CWD}/config.env" ]]; then
    CONFIG_FILE="${CWD}/config.env"
elif found=$(_find_config "$SCRIPT_DIR"); then
    CONFIG_FILE="$found"
fi

if [[ -n "$CONFIG_FILE" ]]; then
    set -a
    source "$CONFIG_FILE"
    set +a
fi

RAG_SERVER="${RAG_SERVER:-}"
RAG_SSH_USER="${RAG_SSH_USER:-azureuser}"
RAG_USER="${RAG_USER:-frappe}"
RAG_SITE="${RAG_SITE:-rag_service.local}"
RAG_BRANCH="${RAG_BRANCH:-main}"
RAG_REPO="${RAG_REPO:-https://github.com/theapprenticeproject/rag_service.git}"
RAG_APP="${RAG_APP:-rag_service}"
RAG_PUBLIC_DOMAIN="${RAG_PUBLIC_DOMAIN:-}"
RAG_GUNICORN_PORT="${RAG_GUNICORN_PORT:-8010}"
RAG_SOCKETIO_PORT="${RAG_SOCKETIO_PORT:-9010}"
RAG_REDIS_CACHE="${RAG_REDIS_CACHE:-14000}"
RAG_REDIS_QUEUE="${RAG_REDIS_QUEUE:-14001}"
RAG_REDIS_SOCKETIO="${RAG_REDIS_SOCKETIO:-14002}"

FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-14}"
FRAPPE_BENCH_DIR="${FRAPPE_BENCH_DIR:-rag-bench}"
DB_TYPE="${DB_TYPE:-postgres}"
DB_HOST="${DB_HOST:-localhost}"
DB_ROOT_USER="${DB_ROOT_USER:-postgres}"
DB_NAME="${DB_NAME:-rag_db}"
DB_PASS="${DB_PASS:-}"
NODE_VERSION="${NODE_VERSION:-16.15.0}"

EXTRA_REPO="${EXTRA_REPO:-https://github.com/Midocean-Technologies/business_theme_v14.git}"
EXTRA_APP="${EXTRA_APP:-business_theme_v14}"
INSTALL_EXTRA_APP="${INSTALL_EXTRA_APP:-true}"

SSL_DOMAIN="${SSL_DOMAIN:-}"
ENABLE_DEV_MODE="${ENABLE_DEV_MODE:-false}"
ENABLE_SERVER_SCRIPT="${ENABLE_SERVER_SCRIPT:-true}"
RESTORE_BACKUP="${RESTORE_BACKUP:-false}"
BACKUP_DB_PATH="${BACKUP_DB_PATH:-}"
BACKUP_PUBLIC_FILES_PATH="${BACKUP_PUBLIC_FILES_PATH:-}"
BACKUP_PRIVATE_FILES_PATH="${BACKUP_PRIVATE_FILES_PATH:-}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
PEM_FILE="${PEM_FILE:-}"

NGINX_CONF_NAME="rag-bench"
NGINX_SSL_CONF_NAME="rag-ssl"
SUPERVISOR_CONF_NAME="rag-bench"

LOCAL_MODE=false
CLEAN_SITE=false
NO_SSL=false

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "  --pem <path>             Path to .pem file for SSH"
    echo "  --server <ip>            Remote server IP or hostname"
    echo "  --user <user>            SSH user (default: azureuser)"
    echo "  --frappe-user <user>     Frappe system user (default: frappe)"
    echo "  --site <name>            Site name (default: rag_service.local)"
    echo "  --app-branch <branch>    RAG app git branch (default: main)"
    echo "  --frappe-branch <branch> Frappe framework branch (default: version-14)"
    echo "  --repo <url>             RAG app git repo URL"
    echo "  --app <name>             RAG app name (default: rag_service)"
    echo "  --domain <domain>        Public domain or IP"
    echo "  --db-pass <pass>         PostgreSQL password"
    echo "  --bench-dir <dir>        Bench directory name (default: rag-bench)"
    echo "  --gunicorn-port <port>   Gunicorn port (default: 8010)"
    echo "  --socketio-port <port>   SocketIO port (default: 9010)"
    echo "  --redis-cache <port>     Redis cache port (default: 14000)"
    echo "  --redis-queue <port>     Redis queue port (default: 14001)"
    echo "  --redis-socketio <port>  Redis socketio port (default: 14002)"
    echo "  --restore                Restore from backup"
    echo "  --backup-db <path>       Path to DB backup .sql.gz"
    echo "  --backup-pub <path>      Path to public files backup .tar"
    echo "  --backup-priv <path>     Path to private files backup .tar"
    echo "  --ssl-domain <domain>    Use Let's Encrypt for this domain"
    echo "  --no-ssl                 Skip SSL entirely"
    echo "  --dev-mode               Enable developer mode"
    echo "  --clean-site             Drop and recreate the site from scratch"
    echo "  --config <path>          Path to config.env file"
    echo "  --local                  Run setup locally (no SSH)"
    echo "  --help                   Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pem)              PEM_FILE="$2"; shift 2 ;;
        --server)           RAG_SERVER="$2"; shift 2 ;;
        --user)             RAG_SSH_USER="$2"; shift 2 ;;
        --frappe-user)      RAG_USER="$2"; shift 2 ;;
        --site)             RAG_SITE="$2"; shift 2 ;;
        --app-branch)       RAG_BRANCH="$2"; shift 2 ;;
        --frappe-branch)    FRAPPE_BRANCH="$2"; shift 2 ;;
        --repo)             RAG_REPO="$2"; shift 2 ;;
        --app)              RAG_APP="$2"; shift 2 ;;
        --domain)           RAG_PUBLIC_DOMAIN="$2"; shift 2 ;;
        --db-pass)          DB_PASS="$2"; shift 2 ;;
        --bench-dir)        FRAPPE_BENCH_DIR="$2"; shift 2 ;;
        --gunicorn-port)    RAG_GUNICORN_PORT="$2"; shift 2 ;;
        --socketio-port)    RAG_SOCKETIO_PORT="$2"; shift 2 ;;
        --redis-cache)      RAG_REDIS_CACHE="$2"; shift 2 ;;
        --redis-queue)      RAG_REDIS_QUEUE="$2"; shift 2 ;;
        --redis-socketio)   RAG_REDIS_SOCKETIO="$2"; shift 2 ;;
        --restore)          RESTORE_BACKUP=true; shift ;;
        --backup-db)        BACKUP_DB_PATH="$2"; shift 2 ;;
        --backup-pub)       BACKUP_PUBLIC_FILES_PATH="$2"; shift 2 ;;
        --backup-priv)      BACKUP_PRIVATE_FILES_PATH="$2"; shift 2 ;;
        --ssl-domain)       SSL_DOMAIN="$2"; shift 2 ;;
        --no-ssl)           NO_SSL=true; shift ;;
        --dev-mode)         ENABLE_DEV_MODE=true; shift ;;
        --clean-site)       CLEAN_SITE=true; shift ;;
        --config)           CONFIG_FILE="$2"; source "$CONFIG_FILE"; shift 2 ;;
        --local)            LOCAL_MODE=true; shift ;;
        --help)             usage ;;
        *)                  echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$DB_PASS" ]]; then
    echo -n "Enter PostgreSQL password for user '${DB_ROOT_USER}': "
    read -rs DB_PASS
    echo ""
fi

if [[ "$LOCAL_MODE" == false ]]; then
    if [[ -z "$PEM_FILE" ]]; then
        echo -n "Enter path to .pem file: "
        read -r PEM_FILE
    fi
    if [[ ! -f "$PEM_FILE" ]]; then
        echo "Error: PEM file not found at '${PEM_FILE}'"
        exit 1
    fi
    chmod 400 "$PEM_FILE"
    if [[ -z "$RAG_SERVER" ]]; then
        echo "Error: RAG_SERVER is not set. Use --server or config.env."
        exit 1
    fi
fi

if [[ -z "$RAG_PUBLIC_DOMAIN" ]]; then
    if [[ -n "$RAG_SERVER" ]]; then
        RAG_PUBLIC_DOMAIN="$RAG_SERVER"
    else
        RAG_PUBLIC_DOMAIN="localhost"
    fi
fi

SSL_CN="${SSL_DOMAIN:-$RAG_PUBLIC_DOMAIN}"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30"
if [[ "$LOCAL_MODE" == false ]]; then
    SSH_OPTS="$SSH_OPTS -i $PEM_FILE"
fi

run_remote() {
    local cmd="$1"
    if [[ "$LOCAL_MODE" == true ]]; then
        bash -c "$cmd"
    else
        ssh $SSH_OPTS "${RAG_SSH_USER}@${RAG_SERVER}" "$cmd"
    fi
}

run_as_rag() {
    local script="$1"
    local full_script="
export NVM_DIR=\"/home/${RAG_USER}/.nvm\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"
export PATH=\"/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env/bin:/usr/local/bin:/usr/bin:/bin:\$PATH\"
export PYTHONPATH=\"\"
cd /home/${RAG_USER}/${FRAPPE_BENCH_DIR}
${script}
"
    if [[ "$LOCAL_MODE" == true ]]; then
        sudo -u "${RAG_USER}" bash -c "$full_script"
    else
        echo "$full_script" | ssh $SSH_OPTS "${RAG_SSH_USER}@${RAG_SERVER}" "sudo -u ${RAG_USER} bash"
    fi
}

copy_to_remote() {
    local src="$1"
    local dst="$2"
    if [[ "$LOCAL_MODE" == false ]]; then
        scp $SSH_OPTS "$src" "${RAG_SSH_USER}@${RAG_SERVER}:${dst}"
    else
        cp "$src" "$dst"
    fi
}

echo "==> [1/20] Updating and upgrading packages"
run_remote "
export DEBIAN_FRONTEND=noninteractive
sudo -E apt-get update -y 2>&1 | grep -v 'cnf-update-db\|apt_pkg\|ModuleNotFoundError\|Sub-process' || true
sudo -E apt-get upgrade -y \
    -o Dpkg::Options::='--force-confdef' \
    -o Dpkg::Options::='--force-confold' \
    -o APT::Get::Assume-Yes=true
if [ -f /etc/needrestart/needrestart.conf ]; then
    sudo sed -i 's/^#\?\s*\$nrconf{restart}.*$/\$nrconf{restart} = \"l\";/' /etc/needrestart/needrestart.conf
fi
"

echo "==> [2/20] Installing Python 3.11"
run_remote "
export DEBIAN_FRONTEND=noninteractive
sudo -E apt-get install -y software-properties-common
sudo add-apt-repository -y ppa:deadsnakes/ppa 2>/dev/null || true
sudo -E apt-get update -y 2>&1 | grep -v 'cnf-update-db\|apt_pkg\|ModuleNotFoundError\|Sub-process' || true
sudo -E apt-get install -y python3.11 python3.11-dev python3.11-venv python3.11-distutils
python3.11 --version
"

echo "==> [3/20] Installing setuptools and pip"
run_remote "export DEBIAN_FRONTEND=noninteractive && sudo -E apt-get install -y python3-setuptools python3-pip"

echo "==> [4/20] Installing virtualenv"
run_remote "export DEBIAN_FRONTEND=noninteractive && sudo -E apt-get install -y virtualenv"

echo "==> [5/20] Installing PostgreSQL"
run_remote "
export DEBIAN_FRONTEND=noninteractive
sudo -E apt-get install -y software-properties-common postgresql postgresql-contrib postgresql-client
sudo systemctl start postgresql
sudo systemctl enable postgresql
sudo -u postgres psql -c \"ALTER USER ${DB_ROOT_USER} WITH PASSWORD '${DB_PASS}';\"
"

echo "==> [6/20] Installing Redis, Supervisor, wkhtmltopdf, Nginx, Cron"
run_remote "
export DEBIAN_FRONTEND=noninteractive
sudo -E apt-get install -y supervisor redis-server xvfb libfontconfig wkhtmltopdf nginx cron
sudo systemctl enable redis-server supervisor cron nginx
sudo systemctl start redis-server supervisor cron
sudo systemctl stop nginx 2>/dev/null || true
"

echo "==> [7/20] Installing curl"
run_remote "
export DEBIAN_FRONTEND=noninteractive
sudo -E apt-get install -y curl
"

echo "==> [8/20] Creating system user '${RAG_USER}'"
run_remote "id -u ${RAG_USER} &>/dev/null || sudo adduser --disabled-password --gecos '' ${RAG_USER}"
run_remote "sudo usermod -aG sudo ${RAG_USER}"
run_remote "echo '${RAG_USER} ALL=(ALL) NOPASSWD: ALL' | sudo tee /etc/sudoers.d/${RAG_USER} > /dev/null"

echo "==> [8a/20] Installing Node.js via NVM for '${RAG_USER}'"
run_remote "
sudo -u ${RAG_USER} bash -c '
export NVM_DIR=\"/home/${RAG_USER}/.nvm\"
[ -s \"\$NVM_DIR/nvm.sh\" ] || curl -s https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
export NVM_DIR=\"/home/${RAG_USER}/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" && nvm install ${NODE_VERSION} && nvm use ${NODE_VERSION} && nvm alias default ${NODE_VERSION}
'
"

echo "==> [8b/20] Installing Yarn for '${RAG_USER}'"
run_remote "
sudo -u ${RAG_USER} bash -c '
export NVM_DIR=\"/home/${RAG_USER}/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" && npm install -g yarn
'
"

echo "==> [9/20] Cleaning previous RAG deployment"
run_remote "
export PGPASSWORD='${DB_PASS}'
SITE_CFG=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites/${RAG_SITE}/site_config.json
if [ -f \"\$SITE_CFG\" ]; then
    DB_USER=\$(python3.11 -c \"import json; c=json.load(open('\$SITE_CFG')); print(c.get('db_name',''))\" 2>/dev/null || true)
    if [ -n \"\$DB_USER\" ]; then
        psql -h ${DB_HOST} -U ${DB_ROOT_USER} -d postgres -c \"DROP DATABASE IF EXISTS \\\"\$DB_USER\\\";\" 2>/dev/null || true
        psql -h ${DB_HOST} -U ${DB_ROOT_USER} -d postgres -c \"DROP ROLE IF EXISTS \\\"\$DB_USER\\\";\" 2>/dev/null || true
    fi
fi
sudo supervisorctl stop all 2>/dev/null || true
sudo rm -rf /home/${RAG_USER}/${FRAPPE_BENCH_DIR}
sudo rm -f /etc/nginx/conf.d/${NGINX_CONF_NAME}.conf
sudo rm -f /etc/nginx/conf.d/${NGINX_SSL_CONF_NAME}.conf
sudo rm -f /etc/nginx/conf.d/rag-http-redirect.conf
for conf in /etc/supervisor/conf.d/*.conf; do
    [ -f \"\$conf\" ] || continue
    base=\$(basename \"\$conf\" .conf)
    if [ \"\$base\" != '${SUPERVISOR_CONF_NAME}' ]; then
        echo \"Removing stale supervisor conf: \$conf\"
        sudo rm -f \"\$conf\"
    fi
done
sudo supervisorctl reread 2>/dev/null || true
sudo supervisorctl update 2>/dev/null || true
"

echo "==> [10/20] Installing frappe-bench via Python 3.11"
run_remote "sudo python3.11 -m pip install frappe-bench --break-system-packages 2>/dev/null || sudo python3.11 -m pip install frappe-bench"
run_remote "sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.11 2 2>/dev/null || true"
run_remote "sudo update-alternatives --set python3 /usr/bin/python3.11"
run_remote "bench --version"

echo "==> [11/20] Initialising bench as '${FRAPPE_BENCH_DIR}'"
run_remote "
cat > /tmp/supervisord-placeholder.conf <<'EOF'
[supervisord]
EOF
sudo cp /tmp/supervisord-placeholder.conf /etc/supervisor/conf.d/${SUPERVISOR_CONF_NAME}.conf
sudo supervisorctl reread 2>/dev/null || true
sudo supervisorctl update 2>/dev/null || true
"

run_as_rag "
if [ -d /home/${RAG_USER}/${FRAPPE_BENCH_DIR} ] && [ -f /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites/apps.txt ]; then
    echo '${FRAPPE_BENCH_DIR} already exists, skipping init'
else
    cd /home/${RAG_USER}
    bench init ${FRAPPE_BENCH_DIR} --frappe-branch ${FRAPPE_BRANCH} --python python3.11
fi
"

run_remote "sudo chown -R ${RAG_USER}:${RAG_USER} /home/${RAG_USER}/${FRAPPE_BENCH_DIR}"

echo "==> [11a/20] Verifying bench venv uses Python 3.11"
run_remote "
sudo chown -R ${RAG_USER}:${RAG_USER} /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env
sudo chmod -R u+x /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env/bin/
VENV_PYTHON=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env/bin/python
VENV_VER=\$(sudo -u ${RAG_USER} \$VENV_PYTHON --version 2>&1 | awk '{print \$2}' | cut -d. -f1,2)
echo \"Bench venv python: \$(sudo -u ${RAG_USER} \$VENV_PYTHON --version 2>&1)\"
if [ \"\$VENV_VER\" != '3.11' ]; then
    echo 'Venv is not Python 3.11 — rebuilding...'
    sudo rm -rf /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env
    sudo -u ${RAG_USER} python3.11 -m venv /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env
    sudo -u ${RAG_USER} /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env/bin/pip install --upgrade pip
    FRAPPE_DIR=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/apps/frappe
    if [ -d \"\$FRAPPE_DIR\" ]; then
        sudo -u ${RAG_USER} /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env/bin/pip install -e \"\$FRAPPE_DIR\"
    fi
    for app_dir in /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/apps/*/; do
        app=\$(basename \"\$app_dir\")
        if [ \"\$app\" != 'frappe' ] && { [ -f \"\${app_dir}setup.py\" ] || [ -f \"\${app_dir}pyproject.toml\" ]; }; then
            sudo -u ${RAG_USER} /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env/bin/pip install -e \"\$app_dir\" || true
        fi
    done
    sudo chown -R ${RAG_USER}:${RAG_USER} /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env
    sudo chmod -R u+x /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env/bin/
    echo \"Venv rebuilt: \$(sudo -u ${RAG_USER} \$VENV_PYTHON --version 2>&1)\"
else
    echo 'Venv is already Python 3.11'
fi
"

echo "==> [11b/20] Generating Redis config files"
run_as_rag "bench setup redis"

echo "==> [11c/20] Ensuring redis_socketio.conf exists"
run_remote "
CONF_DIR=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/config
SOCKETIO_CONF=\"\$CONF_DIR/redis_socketio.conf\"
if [ ! -f \"\$SOCKETIO_CONF\" ]; then
    sudo -u ${RAG_USER} bash -c \"
mkdir -p \$CONF_DIR
cat > \$SOCKETIO_CONF <<REDISEOF
port ${RAG_REDIS_SOCKETIO}
daemonize yes
logfile /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/logs/redis-socketio.log
dir /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/logs
save \"\"
stop-writes-on-bgsave-error no
REDISEOF
\"
fi
"

echo "==> [12/20] Configuring Redis ports and webserver ports"
run_as_rag "
CFG=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites/common_site_config.json
[ -f \"\$CFG\" ] || echo '{}' > \"\$CFG\"
python3 -c \"
import json
p = '\$CFG'
with open(p) as f: c = json.load(f)
c['redis_cache']    = 'redis://127.0.0.1:${RAG_REDIS_CACHE}'
c['redis_queue']    = 'redis://127.0.0.1:${RAG_REDIS_QUEUE}'
c['redis_socketio'] = 'redis://127.0.0.1:${RAG_REDIS_SOCKETIO}'
c['webserver_port'] = ${RAG_GUNICORN_PORT}
c['socketio_port']  = ${RAG_SOCKETIO_PORT}
with open(p, 'w') as f: json.dump(c, f, indent=2)
\"
"

echo "==> [12a/20] Patching Redis config files to use custom ports and starting Redis"
run_remote "
BENCH_DIR=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}

kill_port() {
    local port=\"\$1\"
    local pid
    pid=\$(sudo lsof -t -i:\"\$port\" 2>/dev/null || true)
    if [ -n \"\$pid\" ]; then
        sudo kill -9 \$pid 2>/dev/null || true
        sleep 1
    fi
}

patch_and_start() {
    local conf=\"\$1\"
    local target_port=\"\$2\"
    local log_name=\"\$3\"

    if redis-cli -p \"\$target_port\" ping 2>/dev/null | grep -q PONG; then
        echo \"Redis already up on port \$target_port\"
        return
    fi

    kill_port \"\$target_port\"

    if [ ! -f \"\$conf\" ]; then
        echo \"Creating minimal Redis conf at \$conf for port \$target_port\"
        sudo -u ${RAG_USER} bash -c \"
mkdir -p \$(dirname \$conf)
cat > \$conf <<RCEOF
port \$target_port
bind 127.0.0.1
daemonize yes
logfile /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/logs/\$log_name.log
dir /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/logs
save \"\"
stop-writes-on-bgsave-error no
RCEOF
\"
    fi

    sudo sed -i \"s/^port [0-9]*/port \$target_port/\" \"\$conf\"
    sudo grep -q '^port ' \"\$conf\" || echo \"port \$target_port\" | sudo tee -a \"\$conf\" > /dev/null
    sudo grep -q '^daemonize ' \"\$conf\" && sudo sed -i 's/^daemonize .*/daemonize yes/' \"\$conf\" || echo 'daemonize yes' | sudo tee -a \"\$conf\" > /dev/null
    sudo grep -q '^bind ' \"\$conf\" || echo 'bind 127.0.0.1' | sudo tee -a \"\$conf\" > /dev/null

    logfile=\$(sudo grep -i '^logfile' \"\$conf\" | awk '{print \$2}' | tr -d '\"' || true)
    if [ -n \"\$logfile\" ]; then
        sudo mkdir -p \"\$(dirname \"\$logfile\")\" 2>/dev/null || true
        sudo touch \"\$logfile\" 2>/dev/null || true
        sudo chown ${RAG_USER}:${RAG_USER} \"\$logfile\" 2>/dev/null || true
    fi

    sudo -u ${RAG_USER} redis-server \"\$conf\"
    sleep 2
}

patch_and_start \"\$BENCH_DIR/config/redis_cache.conf\"    ${RAG_REDIS_CACHE}    redis-cache
patch_and_start \"\$BENCH_DIR/config/redis_queue.conf\"    ${RAG_REDIS_QUEUE}    redis-queue
patch_and_start \"\$BENCH_DIR/config/redis_socketio.conf\" ${RAG_REDIS_SOCKETIO} redis-socketio

sleep 3

for port in ${RAG_REDIS_CACHE} ${RAG_REDIS_QUEUE} ${RAG_REDIS_SOCKETIO}; do
    redis-cli -p \"\$port\" ping 2>/dev/null | grep -q PONG \
        && echo \"Redis up on port \$port\" \
        || { echo \"ERROR: Redis failed to start on port \$port\"; exit 1; }
done
"

echo "==> [13/20] Patching PostgreSQL to allow public schema creation"
run_remote "
export PGPASSWORD='${DB_PASS}'

PG_CONF=\$(sudo -u postgres psql -tAc 'SHOW config_file;')
PG_VER=\$(sudo -u postgres psql -tAc 'SHOW server_version_num;')

echo \"PostgreSQL config: \$PG_CONF\"
echo \"PostgreSQL version_num: \$PG_VER\"

if [ \"\$PG_VER\" -ge 150000 ] 2>/dev/null; then
    echo 'PostgreSQL 15+ detected — restoring public schema CREATE privilege cluster-wide'
    sudo -u postgres psql -c \"ALTER ROLE ${DB_ROOT_USER} SUPERUSER;\" 2>/dev/null || true
    sudo -u postgres psql -d template1 -c \"GRANT CREATE ON SCHEMA public TO PUBLIC;\"
    sudo -u postgres psql -d template1 -c \"GRANT USAGE ON SCHEMA public TO PUBLIC;\"
    sudo -u postgres psql -d postgres  -c \"GRANT CREATE ON SCHEMA public TO PUBLIC;\"
    sudo -u postgres psql -d postgres  -c \"GRANT USAGE ON SCHEMA public TO PUBLIC;\"
    echo 'Public schema grants applied to template1 and postgres databases'
fi
"

echo "==> [13a/20] Creating site '${RAG_SITE}'"
run_as_rag "
BENCH_PYTHON=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env/bin/python
SITE_DIR=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites/${RAG_SITE}
SITE_CFG=\${SITE_DIR}/site_config.json

SITE_VALID=false
if [ -d \"\$SITE_DIR\" ] && [ -f \"\$SITE_CFG\" ]; then
    DB_USER=\$(\$BENCH_PYTHON -c \"import json; c=json.load(open('\$SITE_CFG')); print(c.get('db_name',''))\" 2>/dev/null || true)
    DB_PW=\$(\$BENCH_PYTHON -c \"import json; c=json.load(open('\$SITE_CFG')); print(c.get('db_password',''))\" 2>/dev/null || true)
    if [ -n \"\$DB_USER\" ] && [ -n \"\$DB_PW\" ]; then
        TABLE_COUNT=\$(PGPASSWORD=\"\$DB_PW\" psql -h ${DB_HOST} -U \"\$DB_USER\" -d \"\$DB_USER\" -tAc \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'\" 2>/dev/null || echo 0)
        if [ \"\$TABLE_COUNT\" -gt 0 ] 2>/dev/null; then
            SITE_VALID=true
        else
            rm -rf \"\$SITE_DIR\"
        fi
    else
        rm -rf \"\$SITE_DIR\"
    fi
fi

if [ \"\$SITE_VALID\" != 'true' ]; then
    export PGPASSWORD='${DB_PASS}'
    bench new-site ${RAG_SITE} \
        --db-type ${DB_TYPE} \
        --db-host ${DB_HOST} \
        --db-root-username ${DB_ROOT_USER} \
        --db-name ${DB_NAME} \
        --admin-password ${DB_PASS} \
        --db-password ${DB_PASS} \
        --db-root-password ${DB_PASS}
fi
"

echo "==> [13b/20] Fixing schema ownership on site database"
run_remote "
export PGPASSWORD='${DB_PASS}'
SITE_CFG=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites/${RAG_SITE}/site_config.json

if ! sudo test -f \"\$SITE_CFG\"; then
    echo 'site_config.json not found — skipping post-creation schema fix'
    exit 0
fi

DB_USER=\$(sudo python3.11 -c \"import json; c=json.load(open('\$SITE_CFG')); print(c.get('db_name',''))\" 2>/dev/null)
DB_PW=\$(sudo python3.11 -c \"import json; c=json.load(open('\$SITE_CFG')); print(c.get('db_password',''))\" 2>/dev/null)

if [ -z \"\$DB_USER\" ] || [ -z \"\$DB_PW\" ]; then
    echo 'Could not read db credentials from site_config.json — skipping'
    exit 0
fi

echo \"Fixing schema on actual database: \$DB_USER\"
sudo -u postgres psql -d \"\$DB_USER\" -c \"ALTER SCHEMA public OWNER TO \\\"\$DB_USER\\\";\" 2>/dev/null || true
sudo -u postgres psql -d \"\$DB_USER\" -c \"GRANT ALL ON SCHEMA public TO \\\"\$DB_USER\\\";\" 2>/dev/null || true
sudo -u postgres psql -d \"\$DB_USER\" -c \"GRANT CREATE ON SCHEMA public TO \\\"\$DB_USER\\\";\" 2>/dev/null || true
echo \"Schema fixed for \$DB_USER\"
"

run_as_rag "bench use ${RAG_SITE}"

echo "==> [14/20] Installing RAG service app"
run_as_rag "
_APP_DIR=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/apps/${RAG_APP}
VENV_PYTHON=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/env/bin/python

if [ ! -d \"\$_APP_DIR\" ]; then
    bench get-app --branch ${RAG_BRANCH} ${RAG_REPO}
fi

APP_PYTHON_NAME=\$(find \"\$_APP_DIR\" -maxdepth 2 -name 'hooks.py' | head -1 | xargs -I{} dirname {} | xargs basename 2>/dev/null || true)
if [ -z \"\$APP_PYTHON_NAME\" ]; then
    APP_PYTHON_NAME=${RAG_APP}
fi
echo \"Resolved app Python module name: \$APP_PYTHON_NAME\"

uv pip install --quiet --upgrade -e \"\$_APP_DIR\" --python \"\$VENV_PYTHON\"

APPS_TXT=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites/apps.txt
grep -qxF \"\$APP_PYTHON_NAME\" \"\$APPS_TXT\" 2>/dev/null || echo \"\$APP_PYTHON_NAME\" >> \"\$APPS_TXT\"

if bench --site ${RAG_SITE} list-apps 2>/dev/null | grep -qF \"\$APP_PYTHON_NAME\"; then
    echo \"\$APP_PYTHON_NAME already installed on site, skipping install-app\"
else
    bench --site ${RAG_SITE} install-app \"\$APP_PYTHON_NAME\" 2>&1 | grep -v 'no such group' || true
fi
"

if [[ "$INSTALL_EXTRA_APP" == "true" && -n "$EXTRA_REPO" && -n "$EXTRA_APP" ]]; then
    echo "==> [14b/20] Installing extra app '${EXTRA_APP}'"
    run_as_rag "
EXTRA_APP_DIR=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}/apps/${EXTRA_APP}
if [ -d \"\$EXTRA_APP_DIR\" ] && { [ -f \"\${EXTRA_APP_DIR}/setup.py\" ] || [ -f \"\${EXTRA_APP_DIR}/pyproject.toml\" ]; }; then
    echo '${EXTRA_APP} already present, skipping get-app'
else
    [ -d \"\$EXTRA_APP_DIR\" ] && rm -rf \"\$EXTRA_APP_DIR\"
    bench get-app ${EXTRA_REPO}
fi
if bench --site ${RAG_SITE} list-apps 2>/dev/null | grep -qF '${EXTRA_APP}'; then
    echo '${EXTRA_APP} already installed on site, skipping install-app'
else
    bench --site ${RAG_SITE} install-app ${EXTRA_APP}
fi
"
fi

echo "==> [14c/20] Running migrate and build"
run_remote "
BENCH_DIR=/home/${RAG_USER}/${FRAPPE_BENCH_DIR}
for port in ${RAG_REDIS_CACHE} ${RAG_REDIS_QUEUE} ${RAG_REDIS_SOCKETIO}; do
    if ! redis-cli -p \"\$port\" ping 2>/dev/null | grep -q PONG; then
        echo \"Redis not responding on \$port, attempting restart\"
        for conf in \"\$BENCH_DIR/config/redis_cache.conf\" \"\$BENCH_DIR/config/redis_queue.conf\" \"\$BENCH_DIR/config/redis_socketio.conf\"; do
            [ -f \"\$conf\" ] || continue
            conf_port=\$(grep '^port' \"\$conf\" | awk '{print \$2}')
            [ \"\$conf_port\" = \"\$port\" ] && sudo -u ${RAG_USER} redis-server \"\$conf\"
        done
    fi
done
sleep 2
"
run_as_rag "bench --site ${RAG_SITE} migrate"
run_as_rag "bench build"

echo "==> [14d/20] Setting site host_name"
run_as_rag "bench --site ${RAG_SITE} set-config host_name ${RAG_PUBLIC_DOMAIN}"

if [[ "$RESTORE_BACKUP" == "true" ]]; then
    echo "==> [14e/20] Restoring database backup"
    if [[ -n "$BACKUP_DB_PATH" ]]; then
        if [[ "$LOCAL_MODE" == false ]]; then
            remote_db="/home/${RAG_SSH_USER}/restore_rag_db.sql.gz"
            copy_to_remote "$BACKUP_DB_PATH" "$remote_db"
        else
            remote_db="$BACKUP_DB_PATH"
        fi
        run_as_rag "bench --site ${RAG_SITE} restore ${remote_db}"
    fi
    if [[ -n "$BACKUP_PUBLIC_FILES_PATH" ]]; then
        if [[ "$LOCAL_MODE" == false ]]; then
            remote_pub="/home/${RAG_SSH_USER}/restore_rag_pub.tar"
            copy_to_remote "$BACKUP_PUBLIC_FILES_PATH" "$remote_pub"
        else
            remote_pub="$BACKUP_PUBLIC_FILES_PATH"
        fi
        run_remote "tar -xvf ${remote_pub} -C /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites/${RAG_SITE}/public"
        run_remote "cp -r /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites/${RAG_SITE}/public/*/public/files/* /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites/${RAG_SITE}/public/files/ 2>/dev/null || true"
    fi
    if [[ -n "$BACKUP_PRIVATE_FILES_PATH" ]]; then
        if [[ "$LOCAL_MODE" == false ]]; then
            remote_priv="/home/${RAG_SSH_USER}/restore_rag_priv.tar"
            copy_to_remote "$BACKUP_PRIVATE_FILES_PATH" "$remote_priv"
        else
            remote_priv="$BACKUP_PRIVATE_FILES_PATH"
        fi
        run_remote "tar -xvf ${remote_priv} -C /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites/${RAG_SITE}/private"
        run_remote "cp -r /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites/${RAG_SITE}/private/*/private/files/* /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites/${RAG_SITE}/private/files/ 2>/dev/null || true"
    fi
    run_as_rag "bench --site ${RAG_SITE} migrate"
fi

echo "==> [15/20] Configuring Nginx"
run_remote "
sudo rm -f /etc/nginx/conf.d/frappe-bench.conf
sudo rm -f /etc/nginx/conf.d/${NGINX_CONF_NAME}.conf
sudo rm -f /etc/nginx/conf.d/${NGINX_SSL_CONF_NAME}.conf
sudo rm -f /etc/nginx/conf.d/rag-http-redirect.conf
sudo rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
"
run_as_rag "bench setup nginx --yes"
run_remote "sudo ln -sf /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/config/nginx.conf /etc/nginx/conf.d/${NGINX_CONF_NAME}.conf"
run_remote "sudo grep -q 'log_format main' /etc/nginx/nginx.conf || sudo sed -i '/^http {/a\\    log_format main \"\$remote_addr - \$remote_user [\$time_local] \\\"\$request\\\" \$status \$body_bytes_sent \\\"\$http_referer\\\" \\\"\$http_user_agent\\\" \\\"\$http_x_forwarded_for\\\"\";' /etc/nginx/nginx.conf"
run_remote "sudo sed -i 's/server_name\s*_;/server_name ${RAG_PUBLIC_DOMAIN};/g' /etc/nginx/conf.d/${NGINX_CONF_NAME}.conf"

echo "==> [16/20] Configuring Supervisor"
run_as_rag "bench setup supervisor --yes"
run_remote "sudo ln -sf /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/config/supervisor.conf /etc/supervisor/conf.d/${SUPERVISOR_CONF_NAME}.conf"

run_remote "
CONF=/etc/supervisor/conf.d/${SUPERVISOR_CONF_NAME}.conf
sudo python3.11 -c \"
import re, sys
with open('\$CONF') as f:
    content = f.read()
seen = set()
out_blocks = []
for block in re.split(r'(?=^\[)', content, flags=re.MULTILINE):
    header = re.match(r'^\[([^\]]+)\]', block)
    if header:
        key = header.group(1).strip()
        if key in seen:
            continue
        seen.add(key)
    out_blocks.append(block)
with open('\$CONF', 'w') as f:
    f.write(''.join(out_blocks))
\"
"

echo "==> [17/20] Installing and enabling fail2ban"
run_remote "export DEBIAN_FRONTEND=noninteractive && sudo -E apt-get install -y fail2ban 2>/dev/null || true"
run_remote "sudo systemctl enable fail2ban && sudo systemctl start fail2ban || true"

echo "==> [18/20] Setting up production"
run_remote "export DEBIAN_FRONTEND=noninteractive && sudo -E apt-get install -y ansible"
run_remote "sudo chmod 755 /home/${RAG_SSH_USER}"
run_remote "sudo chmod 755 /home/${RAG_USER}"

run_remote "sudo lsof -t -i:${RAG_REDIS_CACHE} -i:${RAG_REDIS_QUEUE} -i:${RAG_REDIS_SOCKETIO} 2>/dev/null | xargs sudo kill -9 2>/dev/null || true"

run_remote "
sudo rm -f /etc/nginx/conf.d/frappe-bench.conf
sudo rm -f /etc/nginx/conf.d/${NGINX_CONF_NAME}.conf
sudo rm -f /etc/nginx/conf.d/${NGINX_SSL_CONF_NAME}.conf
sudo rm -f /etc/nginx/conf.d/rag-http-redirect.conf
"

run_remote "
sudo python3.11 -c \"
import re
path = '/usr/local/lib/python3.11/dist-packages/bench/config/production_setup.py'
with open(path) as f:
    content = f.read()
patched = content.replace(
    'service(\\\"nginx\\\", \\\"reload\\\")',
    'import subprocess; r = subprocess.run([\\\"sudo\\\", \\\"systemctl\\\", \\\"is-active\\\", \\\"nginx\\\"], capture_output=True, text=True); service(\\\"nginx\\\", \\\"reload\\\" if r.stdout.strip() == \\\"active\\\" else \\\"start\\\")'
)
with open(path, 'w') as f:
    f.write(patched)
\"
"

run_as_rag "yes | sudo bench setup production ${RAG_USER}"

run_remote "
sudo ln -sf /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/config/nginx.conf /etc/nginx/conf.d/${NGINX_CONF_NAME}.conf
sudo sed -i 's/server_name\s*_;/server_name ${RAG_PUBLIC_DOMAIN};/g' /etc/nginx/conf.d/${NGINX_CONF_NAME}.conf
"

run_remote "
CONF=/etc/supervisor/conf.d/${SUPERVISOR_CONF_NAME}.conf
sudo python3.11 -c \"
import re, sys
with open('\$CONF') as f:
    content = f.read()
seen = set()
out_blocks = []
for block in re.split(r'(?=^\[)', content, flags=re.MULTILINE):
    header = re.match(r'^\[([^\]]+)\]', block)
    if header:
        key = header.group(1).strip()
        if key in seen:
            continue
        seen.add(key)
    out_blocks.append(block)
with open('\$CONF', 'w') as f:
    f.write(''.join(out_blocks))
\"
"

run_as_rag "bench --site ${RAG_SITE} enable-scheduler"
run_as_rag "bench --site ${RAG_SITE} set-maintenance-mode off"
run_as_rag "bench clear-cache"
run_as_rag "bench --site ${RAG_SITE} clear-website-cache"

run_remote "sudo supervisorctl reread && sudo supervisorctl update"

echo "==> Waiting for supervisord to stabilise"
run_remote "
for i in \$(seq 1 15); do
    STATE=\$(sudo supervisorctl status 2>/dev/null | head -1 || true)
    if echo \"\$STATE\" | grep -qE 'RUNNING|no such'; then
        echo \"Supervisord ready after \${i}s\"
        break
    fi
    sleep 1
done
"

echo "==> [19/20] Configuring SSL"

if [[ "$NO_SSL" == "true" ]]; then
    echo "  Skipping SSL"
elif [[ -n "$SSL_DOMAIN" ]]; then
    run_remote "export DEBIAN_FRONTEND=noninteractive && sudo -E apt-get install -y certbot python3-certbot-nginx"
    run_remote "sudo certbot --nginx -d ${SSL_DOMAIN} --redirect --non-interactive --agree-tos --register-unsafely-without-email"
    run_remote "sudo sed -i 's/server_name\s*_;/server_name ${SSL_DOMAIN};/g' /etc/nginx/conf.d/${NGINX_CONF_NAME}.conf"
    run_remote "(crontab -l 2>/dev/null | grep -q 'certbot renew') || { crontab -l 2>/dev/null; echo '0 3 * * * certbot renew --quiet --post-hook \"service nginx reload\"'; } | crontab -"
else
    run_remote "sudo openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /etc/ssl/private/rag-selfsigned.key \
        -out /etc/ssl/certs/rag-selfsigned.crt \
        -subj \"/CN=${SSL_CN}\""

    run_remote "cat > /tmp/${NGINX_SSL_CONF_NAME}.conf <<'NGINXEOF'
upstream rag-ssl-gunicorn {
    server 127.0.0.1:${RAG_GUNICORN_PORT} fail_timeout=0;
}

upstream rag-ssl-socketio {
    server 127.0.0.1:${RAG_SOCKETIO_PORT} fail_timeout=0;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${SSL_CN};

    ssl_certificate /etc/ssl/certs/rag-selfsigned.crt;
    ssl_certificate_key /etc/ssl/private/rag-selfsigned.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:RAG_SSL:10m;
    ssl_session_timeout 10m;

    root /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/sites;

    proxy_buffer_size 128k;
    proxy_buffers 4 256k;
    proxy_busy_buffers_size 256k;

    add_header X-Frame-Options \"SAMEORIGIN\";
    add_header X-Content-Type-Options nosniff;
    add_header X-XSS-Protection \"1; mode=block\";
    add_header Referrer-Policy \"same-origin, strict-origin-when-cross-origin\";

    sendfile on;
    keepalive_timeout 15;
    client_max_body_size 50m;
    client_body_buffer_size 16K;
    client_header_buffer_size 1k;

    gzip on;
    gzip_http_version 1.1;
    gzip_comp_level 5;
    gzip_min_length 256;
    gzip_proxied any;
    gzip_vary on;
    gzip_types application/atom+xml application/javascript application/json application/rss+xml application/xhtml+xml application/xml text/css text/plain image/svg+xml;

    location /assets {
        try_files \$uri =404;
        add_header Cache-Control \"max-age=31536000\";
    }

    location ~ ^/protected/(.*) {
        internal;
        try_files /${RAG_SITE}/\$1 =404;
    }

    location /socket.io {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \"upgrade\";
        proxy_set_header X-Frappe-Site-Name ${RAG_SITE};
        proxy_set_header Origin \$scheme://\$http_host;
        proxy_set_header Host \$host;
        proxy_pass http://rag-ssl-socketio;
    }

    location / {
        rewrite ^(.+)/\$ \$1 permanent;
        rewrite ^(.+)/index\.html\$ \$1 permanent;
        rewrite ^(.+)\.html\$ \$1 permanent;

        location ~* ^/files/.*\.(htm|html|svg|xml) {
            add_header Content-Disposition \"attachment\";
            try_files /${RAG_SITE}/public/\$uri @webserver;
        }

        try_files /${RAG_SITE}/public/\$uri @webserver;
    }

    location @webserver {
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Frappe-Site-Name ${RAG_SITE};
        proxy_set_header Host \$host;
        proxy_set_header X-Use-X-Accel-Redirect True;
        proxy_read_timeout 120;
        proxy_redirect off;
        proxy_pass http://rag-ssl-gunicorn;
    }

    error_page 502 /502.html;
    location /502.html {
        root /usr/local/lib/python3.12/dist-packages/bench/config/templates;
        internal;
    }
}
NGINXEOF
sudo mv /tmp/${NGINX_SSL_CONF_NAME}.conf /etc/nginx/conf.d/${NGINX_SSL_CONF_NAME}.conf"

    run_remote "cat > /tmp/rag-http-redirect.conf <<'REDIRECTEOF'
server {
    listen 80;
    listen [::]:80;
    server_name ${SSL_CN};
    return 301 https://\$host\$request_uri;
}
REDIRECTEOF
sudo mv /tmp/rag-http-redirect.conf /etc/nginx/conf.d/${NGINX_CONF_NAME}.conf"
fi

run_remote "sudo nginx -t"
run_remote "sudo systemctl start nginx || sudo service nginx start"
run_remote "sudo service nginx reload"
run_remote "sudo supervisorctl reload"

echo "==> Waiting for supervisord processes to start"
run_remote "
for i in \$(seq 1 30); do
    RUNNING=\$(sudo supervisorctl status 2>/dev/null | grep -c RUNNING || true)
    if [ \"\$RUNNING\" -gt 0 ]; then
        echo \"Supervisor processes running: \$RUNNING\"
        break
    fi
    sleep 2
done
sudo supervisorctl status 2>/dev/null || true
"

echo "==> [20/20] Applying final site configuration"

if [[ "$ENABLE_SERVER_SCRIPT" == "true" ]]; then
    run_as_rag "bench --site ${RAG_SITE} set-config server_script_enabled true"
fi

if [[ "$ENABLE_DEV_MODE" == "true" ]]; then
    run_as_rag "bench set-config -g developer_mode true"
fi

run_remote "find /home/${RAG_USER}/${FRAPPE_BENCH_DIR}/logs -name '*.log' -mtime +${LOG_RETENTION_DAYS} -delete 2>/dev/null || true"

run_remote "
echo 'Waiting for supervisor processes before final restart...'
for i in \$(seq 1 30); do
    RUNNING=\$(sudo supervisorctl status 2>/dev/null | grep -c RUNNING || true)
    if [ \"\$RUNNING\" -gt 0 ]; then
        echo \"Supervisor ready with \$RUNNING running processes\"
        break
    fi
    sleep 2
done
"

run_remote "
for group in ${SUPERVISOR_CONF_NAME}-redis ${SUPERVISOR_CONF_NAME}-web ${SUPERVISOR_CONF_NAME}-workers; do
    if sudo supervisorctl status 2>/dev/null | grep -q \"^\$group:\"; then
        sudo supervisorctl restart \"\$group:\" 2>/dev/null || true
    fi
done
"

echo ""
echo " Deployment complete"
echo ""
echo " Site:         ${RAG_SITE}"
echo " Domain:       ${RAG_PUBLIC_DOMAIN}"
echo " HTTP:         http://${RAG_PUBLIC_DOMAIN}  ->  redirects to HTTPS"
if [[ "$NO_SSL" != "true" ]]; then
    echo " HTTPS:        https://${RAG_PUBLIC_DOMAIN}"
    if [[ -z "$SSL_DOMAIN" ]]; then
        echo " SSL:          Self-signed (click Advanced > Proceed in browser)"
    else
        echo " SSL:          Let's Encrypt (${SSL_DOMAIN})"
    fi
fi
echo " Bench dir:    /home/${RAG_USER}/${FRAPPE_BENCH_DIR}"
echo " Gunicorn:     127.0.0.1:${RAG_GUNICORN_PORT}"
echo " SocketIO:     127.0.0.1:${RAG_SOCKETIO_PORT}"
echo " Redis Cache:  127.0.0.1:${RAG_REDIS_CACHE}"
echo " Redis Queue:  127.0.0.1:${RAG_REDIS_QUEUE}"
echo " Redis SockIO: 127.0.0.1:${RAG_REDIS_SOCKETIO}"
echo ""