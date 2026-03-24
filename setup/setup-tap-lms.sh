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

TAP_SERVER="${TAP_SERVER:-}"
TAP_SSH_USER="${TAP_SSH_USER:-ubuntu}"
TAP_USER="${TAP_USER:-frappe}"
TAP_SITE="${TAP_SITE:-tap.localhost}"
TAP_BRANCH="${TAP_BRANCH:-main}"
TAP_REPO="${TAP_REPO:-https://github.com/DalgoT4D/frappe_tap.git}"
TAP_APP="${TAP_APP:-tap_lms}"
TAP_PUBLIC_DOMAIN="${TAP_PUBLIC_DOMAIN:-}"
TAP_GUNICORN_PORT="${TAP_GUNICORN_PORT:-8000}"
TAP_SOCKETIO_PORT="${TAP_SOCKETIO_PORT:-9000}"
TAP_REDIS_CACHE="${TAP_REDIS_CACHE:-13000}"
TAP_REDIS_QUEUE="${TAP_REDIS_QUEUE:-11000}"
TAP_REDIS_SOCKETIO="${TAP_REDIS_SOCKETIO:-12000}"

FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-14}"
FRAPPE_BENCH_DIR="${FRAPPE_BENCH_DIR:-frappe-bench}"
DB_TYPE="${DB_TYPE:-postgres}"
DB_HOST="${DB_HOST:-localhost}"
DB_ROOT_USER="${DB_ROOT_USER:-postgres}"
DB_NAME="${DB_NAME:-frappe_db}"
DB_PASS="${DB_PASS:-}"
NODE_VERSION="${NODE_VERSION:-16.15.0}"
PYTHON_VERSION="${PYTHON_VERSION:-python3}"
EXTRA_REPO="${EXTRA_REPO:-https://github.com/Midocean-Technologies/business_theme_v14.git}"
EXTRA_APP="${EXTRA_APP:-business_theme_v14}"
INSTALL_EXTRA_APP="${INSTALL_EXTRA_APP:-true}"
INSTALL_SSL="${INSTALL_SSL:-false}"
SSL_DOMAIN="${SSL_DOMAIN:-}"
ENABLE_DEV_MODE="${ENABLE_DEV_MODE:-false}"
ENABLE_SERVER_SCRIPT="${ENABLE_SERVER_SCRIPT:-true}"
RESTORE_BACKUP="${RESTORE_BACKUP:-false}"
BACKUP_DB_PATH="${BACKUP_DB_PATH:-}"
BACKUP_PUBLIC_FILES_PATH="${BACKUP_PUBLIC_FILES_PATH:-}"
BACKUP_PRIVATE_FILES_PATH="${BACKUP_PRIVATE_FILES_PATH:-}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
PEM_FILE="${PEM_FILE:-}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --pem <path>             Path to .pem file for SSH"
    echo "  --server <ip>            Remote server IP or hostname"
    echo "  --user <user>            SSH user (default: ubuntu)"
    echo "  --frappe-user <user>     Frappe system user (default: frappe)"
    echo "  --site <name>            Site name (default: tap.localhost)"
    echo "  --app-branch <branch>    TAP app git branch (default: main)"
    echo "  --frappe-branch <branch> Frappe framework branch (default: version-14)"
    echo "  --repo <url>             TAP app git repo URL"
    echo "  --app <name>             TAP app name"
    echo "  --domain <domain>        Public domain or IP"
    echo "  --db-pass <pass>         PostgreSQL password"
    echo "  --restore                Restore from backup"
    echo "  --backup-db <path>       Path to DB backup .sql.gz"
    echo "  --backup-pub <path>      Path to public files backup .tar"
    echo "  --backup-priv <path>     Path to private files backup .tar"
    echo "  --ssl                    Install SSL certificate"
    echo "  --ssl-domain <domain>    Domain for SSL"
    echo "  --dev-mode               Enable developer mode"
    echo "  --config <path>          Path to config.env file"
    echo "  --local                  Run setup locally (no SSH)"
    echo "  --help                   Show this help"
    exit 0
}

LOCAL_MODE=false
CLEAN_SITE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pem)            PEM_FILE="$2"; shift 2 ;;
        --server)         TAP_SERVER="$2"; shift 2 ;;
        --user)           TAP_SSH_USER="$2"; shift 2 ;;
        --frappe-user)    TAP_USER="$2"; shift 2 ;;
        --site)           TAP_SITE="$2"; shift 2 ;;
        --app-branch)     TAP_BRANCH="$2"; shift 2 ;;
        --frappe-branch)  FRAPPE_BRANCH="$2"; shift 2 ;;
        --repo)           TAP_REPO="$2"; shift 2 ;;
        --app)            TAP_APP="$2"; shift 2 ;;
        --domain)         TAP_PUBLIC_DOMAIN="$2"; shift 2 ;;
        --db-pass)        DB_PASS="$2"; shift 2 ;;
        --restore)        RESTORE_BACKUP=true; shift ;;
        --backup-db)      BACKUP_DB_PATH="$2"; shift 2 ;;
        --backup-pub)     BACKUP_PUBLIC_FILES_PATH="$2"; shift 2 ;;
        --backup-priv)    BACKUP_PRIVATE_FILES_PATH="$2"; shift 2 ;;
        --ssl)            INSTALL_SSL=true; shift ;;
        --ssl-domain)     SSL_DOMAIN="$2"; shift 2 ;;
        --dev-mode)       ENABLE_DEV_MODE=true; shift ;;
        --clean-site)     CLEAN_SITE=true; shift ;;
        --config)         CONFIG_FILE="$2"; source "$CONFIG_FILE"; shift 2 ;;
        --local)          LOCAL_MODE=true; shift ;;
        --help)           usage ;;
        *)                echo "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$DB_PASS" ]]; then
    echo -n "Enter PostgreSQL password for user '$DB_ROOT_USER': "
    read -rs DB_PASS
    echo ""
fi

if [[ "$LOCAL_MODE" == false ]]; then
    if [[ -z "$PEM_FILE" ]]; then
        echo -n "Enter path to .pem file: "
        read -r PEM_FILE
    fi
    if [[ ! -f "$PEM_FILE" ]]; then
        echo "Error: PEM file not found at '$PEM_FILE'"
        exit 1
    fi
    chmod 400 "$PEM_FILE"
    if [[ -z "$TAP_SERVER" ]]; then
        echo "Error: TAP_SERVER is not set. Use --server or config.env."
        exit 1
    fi
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30"
if [[ "$LOCAL_MODE" == false ]]; then
    SSH_OPTS="$SSH_OPTS -i $PEM_FILE"
fi

run_remote() {
    local cmd="$1"
    if [[ "$LOCAL_MODE" == true ]]; then
        bash -c "$cmd"
    else
        ssh $SSH_OPTS "${TAP_SSH_USER}@${TAP_SERVER}" "$cmd"
    fi
}

run_script_remote() {
    local script="$1"
    if [[ "$LOCAL_MODE" == true ]]; then
        bash <(echo "$script")
    else
        echo "$script" | ssh $SSH_OPTS "${TAP_SSH_USER}@${TAP_SERVER}" bash
    fi
}

run_as_frappe() {
    local script="$1"
    local full_script="export NVM_DIR=\"\$HOME/.nvm\"; [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\"; ${script}"
    if [[ "$LOCAL_MODE" == true ]]; then
        sudo -u "${TAP_USER}" bash <(echo "$full_script")
    else
        echo "$full_script" | ssh $SSH_OPTS "${TAP_SSH_USER}@${TAP_SERVER}" "sudo -u ${TAP_USER} bash"
    fi
}

copy_to_remote() {
    local src="$1"
    local dst="$2"
    if [[ "$LOCAL_MODE" == false ]]; then
        scp $SSH_OPTS "$src" "${TAP_SSH_USER}@${TAP_SERVER}:${dst}"
    else
        cp "$src" "$dst"
    fi
}

echo "==> [1/20] Updating and upgrading packages"
run_remote "sudo apt-get update -y && sudo apt-get upgrade -y"

echo "==> [2/20] Installing Python dev tools"
run_remote "sudo apt-get install -y python3-dev"

echo "==> [3/20] Installing setuptools and pip"
run_remote "sudo apt-get install -y python3-setuptools python3-pip"

echo "==> [4/20] Installing virtualenv"
run_remote "sudo apt-get install -y virtualenv"
run_remote "PYVER=\$(python3 -c 'import sys; print(f\"{sys.version_info.major}.{sys.version_info.minor}\")') && sudo apt-get install -y python\${PYVER}-venv || sudo apt-get install -y python3-venv"

echo "==> [5/20] Installing PostgreSQL"
run_remote "sudo apt-get install -y software-properties-common postgresql postgresql-contrib postgresql-client"
run_remote "sudo systemctl start postgresql && sudo systemctl enable postgresql"
run_remote "sudo -u postgres psql -c \"ALTER USER ${DB_ROOT_USER} WITH PASSWORD '${DB_PASS}';\""

echo "==> [6/20] Installing Redis, Supervisor, wkhtmltopdf, Nginx, Cron"
run_remote "sudo apt-get install -y supervisor redis-server xvfb libfontconfig wkhtmltopdf nginx cron"
run_remote "sudo systemctl enable redis-server nginx supervisor cron"
run_remote "sudo systemctl start redis-server nginx supervisor cron"

echo "==> [7/20] Installing Node.js via NVM"
run_remote "sudo apt-get install -y curl"
run_remote "curl -s https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash"
run_remote "export NVM_DIR=\"\$HOME/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" && nvm install ${NODE_VERSION} && nvm use ${NODE_VERSION} && nvm alias default ${NODE_VERSION}"

echo "==> [8/20] Installing Yarn"
run_remote "export NVM_DIR=\"\$HOME/.nvm\" && [ -s \"\$NVM_DIR/nvm.sh\" ] && . \"\$NVM_DIR/nvm.sh\" && npm install -g yarn"

echo "==> [9/20] Creating system user '${TAP_USER}'"
run_remote "id -u ${TAP_USER} &>/dev/null || sudo adduser --disabled-password --gecos '' ${TAP_USER}"
run_remote "sudo usermod -aG sudo ${TAP_USER}"

echo "==> [10/20] Installing frappe-bench"
run_remote "sudo pip3 install frappe-bench --break-system-packages 2>/dev/null || sudo pip3 install frappe-bench"
run_remote "bench --version"

echo "==> [11/20] Initialising frappe-bench"
run_as_frappe "
if [ -d /home/${TAP_USER}/${FRAPPE_BENCH_DIR} ]; then
    echo 'frappe-bench already exists, skipping init'
else
    cd /home/${TAP_USER} && bench init ${FRAPPE_BENCH_DIR} --frappe-branch ${FRAPPE_BRANCH} --skip-redis-config-generation
fi
"

echo "==> [12/20] Configuring Redis and ports in common_site_config.json"
run_as_frappe "
CFG=/home/${TAP_USER}/${FRAPPE_BENCH_DIR}/sites/common_site_config.json
[ -f \"\$CFG\" ] || echo '{}' > \"\$CFG\"
python3 -c \"
import json
p = '\$CFG'
with open(p) as f: c = json.load(f)
c['redis_cache']    = 'redis://127.0.0.1:${TAP_REDIS_CACHE}'
c['redis_queue']    = 'redis://127.0.0.1:${TAP_REDIS_QUEUE}'
c['redis_socketio'] = 'redis://127.0.0.1:${TAP_REDIS_SOCKETIO}'
c['webserver_port'] = ${TAP_GUNICORN_PORT}
c['socketio_port']  = ${TAP_SOCKETIO_PORT}
with open(p, 'w') as f: json.dump(c, f, indent=2)
print('common_site_config.json updated')
\"
"

echo "==> [13/20] Creating site '${TAP_SITE}'"

if [[ "${CLEAN_SITE}" == "true" ]]; then
    echo "  --clean-site set: removing site dir and dropping postgres role/db"
    run_remote "
export PGPASSWORD='${DB_PASS}'
SITE_CFG=/home/${TAP_USER}/${FRAPPE_BENCH_DIR}/sites/${TAP_SITE}/site_config.json
if [ -f \"\$SITE_CFG\" ]; then
    DB_USER=\$(python3 -c \"import json; c=json.load(open('\$SITE_CFG')); print(c.get('db_name',''))\" 2>/dev/null)
    if [ -n \"\$DB_USER\" ]; then
        psql -h ${DB_HOST} -U ${DB_ROOT_USER} -d postgres -c \"DROP DATABASE IF EXISTS \\\"\$DB_USER\\\";\" 2>/dev/null || true
        psql -h ${DB_HOST} -U ${DB_ROOT_USER} -d postgres -c \"DROP ROLE IF EXISTS \\\"\$DB_USER\\\";\" 2>/dev/null || true
        echo \"Dropped postgres role and database '\$DB_USER'\"
    fi
fi
sudo rm -rf /home/${TAP_USER}/${FRAPPE_BENCH_DIR}/sites/${TAP_SITE}
echo 'Site directory removed'
"
fi

run_as_frappe "
cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR}

SITE_VALID=false
if [ -d sites/${TAP_SITE} ] && [ -f sites/${TAP_SITE}/site_config.json ]; then
    DB_USER=\$(python3 -c \"import json; c=json.load(open('sites/${TAP_SITE}/site_config.json')); print(c.get('db_name',''))\" 2>/dev/null)
    DB_PW=\$(python3 -c \"import json; c=json.load(open('sites/${TAP_SITE}/site_config.json')); print(c.get('db_password',''))\" 2>/dev/null)
    if [ -n \"\$DB_USER\" ] && [ -n \"\$DB_PW\" ]; then
        TABLE_COUNT=\$(PGPASSWORD=\"\$DB_PW\" psql -h ${DB_HOST} -U \"\$DB_USER\" -d \"\$DB_USER\" -tAc \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'\" 2>/dev/null || echo 0)
        if [ \"\$TABLE_COUNT\" -gt 0 ] 2>/dev/null; then
            SITE_VALID=true
            echo 'Site ${TAP_SITE} exists and database has tables, skipping bench new-site'
        else
            echo 'Site dir exists but database is empty, re-creating site'
            rm -rf sites/${TAP_SITE}
        fi
    fi
fi

if [ \"\$SITE_VALID\" != 'true' ]; then
    export PGPASSWORD='${DB_PASS}'
    bench new-site ${TAP_SITE} \
        --db-type ${DB_TYPE} \
        --db-host ${DB_HOST} \
        --db-root-username ${DB_ROOT_USER} \
        --db-name ${DB_NAME} \
        --admin-password ${DB_PASS} \
        --db-password ${DB_PASS} \
        --db-root-password ${DB_PASS}
fi
"

echo "==> [13b/20] Reconciling PostgreSQL role and database from site_config.json"
run_remote "
export PGPASSWORD='${DB_PASS}'
SITE_CFG=/home/${TAP_USER}/${FRAPPE_BENCH_DIR}/sites/${TAP_SITE}/site_config.json

if [ ! -f \"\$SITE_CFG\" ]; then
    echo 'site_config.json not found, skipping postgres reconciliation'
    exit 0
fi

DB_USER=\$(python3 -c \"import json; c=json.load(open('\$SITE_CFG')); print(c.get('db_name',''))\" 2>/dev/null)
DB_PW=\$(python3 -c \"import json; c=json.load(open('\$SITE_CFG')); print(c.get('db_password',''))\" 2>/dev/null)

if [ -z \"\$DB_USER\" ] || [ -z \"\$DB_PW\" ]; then
    echo 'Could not read db_name/db_password from site_config.json'
    exit 1
fi

ROLE_EXISTS=\$(psql -h ${DB_HOST} -U ${DB_ROOT_USER} -d postgres -tAc \"SELECT 1 FROM pg_roles WHERE rolname='\$DB_USER'\" 2>/dev/null)
if [ \"\$ROLE_EXISTS\" != '1' ]; then
    psql -h ${DB_HOST} -U ${DB_ROOT_USER} -d postgres -c \"CREATE ROLE \\\"\$DB_USER\\\" WITH LOGIN PASSWORD '\$DB_PW';\"
    echo \"Role '\$DB_USER' created\"
else
    psql -h ${DB_HOST} -U ${DB_ROOT_USER} -d postgres -c \"ALTER ROLE \\\"\$DB_USER\\\" WITH PASSWORD '\$DB_PW';\"
    echo \"Role '\$DB_USER' password synced\"
fi

DB_EXISTS=\$(psql -h ${DB_HOST} -U ${DB_ROOT_USER} -d postgres -tAc \"SELECT 1 FROM pg_database WHERE datname='\$DB_USER'\" 2>/dev/null)
if [ \"\$DB_EXISTS\" != '1' ]; then
    psql -h ${DB_HOST} -U ${DB_ROOT_USER} -d postgres -c \"CREATE DATABASE \\\"\$DB_USER\\\" OWNER \\\"\$DB_USER\\\";\"
    echo \"Database '\$DB_USER' created\"
else
    echo \"Database '\$DB_USER' already exists\"
fi

psql -h ${DB_HOST} -U ${DB_ROOT_USER} -d postgres -c \"GRANT ALL PRIVILEGES ON DATABASE \\\"\$DB_USER\\\" TO \\\"\$DB_USER\\\";\"
echo 'Postgres reconciliation complete'
"

run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && bench use ${TAP_SITE}"

echo "==> [14/20] Installing TAP LMS app"
run_as_frappe "
cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR}
BENCH_DIR=/home/${TAP_USER}/${FRAPPE_BENCH_DIR}
APP_DIR=\${BENCH_DIR}/apps/${TAP_APP}
REPO_DIR=\${BENCH_DIR}/apps/frappe_tap

if [ -d \"\$APP_DIR\" ] && [ -f \"\${APP_DIR}/setup.py\" -o -f \"\${APP_DIR}/pyproject.toml\" ]; then
    echo '${TAP_APP} already present, skipping get-app'
else
    [ -d \"\$APP_DIR\" ] && rm -rf \"\$APP_DIR\"
    [ -d \"\$REPO_DIR\" ] && rm -rf \"\$REPO_DIR\"
    bench get-app --branch ${TAP_BRANCH} ${TAP_REPO}
fi

if bench --site ${TAP_SITE} list-apps 2>/dev/null | grep -q '^${TAP_APP}$'; then
    echo '${TAP_APP} already installed on site, skipping install-app'
else
    bench --site ${TAP_SITE} install-app ${TAP_APP} 2>&1 | grep -v 'no such group' || true
fi
"

if [[ "$INSTALL_EXTRA_APP" == "true" && -n "$EXTRA_REPO" && -n "$EXTRA_APP" ]]; then
    echo "==> [14b] Installing extra app '${EXTRA_APP}'"
    run_as_frappe "
cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR}
EXTRA_APP_DIR=/home/${TAP_USER}/${FRAPPE_BENCH_DIR}/apps/${EXTRA_APP}

if [ -d \"\$EXTRA_APP_DIR\" ] && [ -f \"\${EXTRA_APP_DIR}/setup.py\" -o -f \"\${EXTRA_APP_DIR}/pyproject.toml\" ]; then
    echo '${EXTRA_APP} already installed, skipping get-app'
else
    [ -d \"\$EXTRA_APP_DIR\" ] && rm -rf \"\$EXTRA_APP_DIR\"
    bench get-app ${EXTRA_REPO}
fi

if bench --site ${TAP_SITE} list-apps 2>/dev/null | grep -q '^${EXTRA_APP}$'; then
    echo '${EXTRA_APP} already installed on site, skipping install-app'
else
    bench --site ${TAP_SITE} install-app ${EXTRA_APP}
fi
"
fi

if [[ "$RESTORE_BACKUP" == "true" ]]; then
    echo "==> [14c] Restoring database backup"
    if [[ -n "$BACKUP_DB_PATH" ]]; then
        if [[ "$LOCAL_MODE" == false ]]; then
            remote_db="/home/${TAP_SSH_USER}/restore_db.sql.gz"
            copy_to_remote "$BACKUP_DB_PATH" "$remote_db"
        else
            remote_db="$BACKUP_DB_PATH"
        fi
        run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && bench --site ${TAP_SITE} restore ${remote_db}"
    fi

    if [[ -n "$BACKUP_PUBLIC_FILES_PATH" ]]; then
        if [[ "$LOCAL_MODE" == false ]]; then
            remote_pub="/home/${TAP_SSH_USER}/restore_pub.tar"
            copy_to_remote "$BACKUP_PUBLIC_FILES_PATH" "$remote_pub"
        else
            remote_pub="$BACKUP_PUBLIC_FILES_PATH"
        fi
        run_remote "tar -xvf ${remote_pub} -C /home/${TAP_USER}/${FRAPPE_BENCH_DIR}/sites/${TAP_SITE}/public"
        run_remote "cp -r /home/${TAP_USER}/${FRAPPE_BENCH_DIR}/sites/${TAP_SITE}/public/*/public/files/* /home/${TAP_USER}/${FRAPPE_BENCH_DIR}/sites/${TAP_SITE}/public/files/ 2>/dev/null || true"
    fi

    if [[ -n "$BACKUP_PRIVATE_FILES_PATH" ]]; then
        if [[ "$LOCAL_MODE" == false ]]; then
            remote_priv="/home/${TAP_SSH_USER}/restore_priv.tar"
            copy_to_remote "$BACKUP_PRIVATE_FILES_PATH" "$remote_priv"
        else
            remote_priv="$BACKUP_PRIVATE_FILES_PATH"
        fi
        run_remote "tar -xvf ${remote_priv} -C /home/${TAP_USER}/${FRAPPE_BENCH_DIR}/sites/${TAP_SITE}/private"
        run_remote "cp -r /home/${TAP_USER}/${FRAPPE_BENCH_DIR}/sites/${TAP_SITE}/private/*/private/files/* /home/${TAP_USER}/${FRAPPE_BENCH_DIR}/sites/${TAP_SITE}/private/files/ 2>/dev/null || true"
    fi

    run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && bench --site ${TAP_SITE} migrate"
fi

echo "==> [15/20] Configuring Nginx"
run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && bench setup nginx --yes"
run_remote "sudo ln -sf /home/${TAP_USER}/${FRAPPE_BENCH_DIR}/config/nginx.conf /etc/nginx/conf.d/frappe-bench.conf"

run_remote "
python3 -c \"
import re, sys
path = '/etc/nginx/conf.d/frappe-bench.conf'
with open(path) as f:
    content = f.read()
content = re.sub(r'server_name [^;]+;', 'server_name ${TAP_PUBLIC_DOMAIN};', content)
with open('/tmp/frappe-bench.conf.tmp', 'w') as f:
    f.write(content)
\"
sudo cp /tmp/frappe-bench.conf.tmp /etc/nginx/conf.d/frappe-bench.conf
echo 'nginx server_name updated to ${TAP_PUBLIC_DOMAIN}'
"

run_remote "sudo grep -q 'log_format main' /etc/nginx/nginx.conf || sudo sed -i '/^http {/a\\    log_format main \"\$remote_addr - \$remote_user [\$time_local] \\\"\$request\\\" \$status \$body_bytes_sent \\\"\$http_referer\\\" \\\"\$http_user_agent\\\" \\\"\$http_x_forwarded_for\\\"\";' /etc/nginx/nginx.conf"

echo "==> [16/20] Configuring Supervisor"
run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && bench setup supervisor --yes"
run_remote "sudo ln -sf /home/${TAP_USER}/${FRAPPE_BENCH_DIR}/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf"

echo "==> [17/20] Installing and enabling fail2ban"
run_remote "sudo apt-get install -y fail2ban"
run_remote "sudo systemctl enable fail2ban && sudo systemctl start fail2ban"

echo "==> [18/20] Setting up production"
run_remote "sudo apt-get install -y ansible"
run_remote "sudo chmod 755 /home/${TAP_SSH_USER}"
run_remote "sudo chmod 755 /home/${TAP_USER}"
run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && yes | sudo bench setup production ${TAP_USER}"
run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && bench --site ${TAP_SITE} enable-scheduler"
run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && bench --site ${TAP_SITE} set-maintenance-mode off"
run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && bench clear-cache"
run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && bench --site ${TAP_SITE} clear-website-cache"

run_remote "sudo service nginx restart"
run_remote "sudo supervisorctl reload"

if [[ "$INSTALL_SSL" == "true" && -n "$SSL_DOMAIN" ]]; then
    echo "==> [19/20] Installing SSL certificate"
    run_remote "sudo apt-get install -y certbot python3-certbot-nginx"
    run_remote "sudo certbot -d ${SSL_DOMAIN} --register-unsafely-without-email --nginx --non-interactive --agree-tos"
    run_remote "sudo certbot renew --dry-run"
else
    echo "==> [19/20] Skipping SSL (INSTALL_SSL=${INSTALL_SSL})"
fi

if [[ "$ENABLE_SERVER_SCRIPT" == "true" || "$ENABLE_DEV_MODE" == "true" ]]; then
    echo "==> [20/20] Configuring developer/server-script settings"
fi

if [[ "$ENABLE_SERVER_SCRIPT" == "true" ]]; then
    run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && bench --site ${TAP_SITE} set-config server_script_enabled true"
fi

if [[ "$ENABLE_DEV_MODE" == "true" ]]; then
    run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && bench set-config -g developer_mode true"
else
    echo "==> [20/20] Skipping developer mode (ENABLE_DEV_MODE=${ENABLE_DEV_MODE})"
fi

run_remote "find /home/${TAP_USER}/${FRAPPE_BENCH_DIR}/logs -name '*.log' -mtime +${LOG_RETENTION_DAYS} -delete 2>/dev/null || true"

run_as_frappe "cd /home/${TAP_USER}/${FRAPPE_BENCH_DIR} && bench restart"

echo ""
echo "Deployment complete."
echo "Site: ${TAP_SITE}"
echo "Domain: ${TAP_PUBLIC_DOMAIN}"
echo "Gunicorn port: ${TAP_GUNICORN_PORT}"
echo "SocketIO port: ${TAP_SOCKETIO_PORT}"
echo "Redis Cache: ${TAP_REDIS_CACHE} | Queue: ${TAP_REDIS_QUEUE} | SocketIO: ${TAP_REDIS_SOCKETIO}"