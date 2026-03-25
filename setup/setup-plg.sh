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

PLG_SERVER="${PLG_SERVER:-}"
PLG_SSH_USER="${PLG_SSH_USER:-gcp-data}"
PLG_BRANCH="${PLG_BRANCH:-plg_integration}"
PLG_REPO="${PLG_REPO:-https://github.com/theapprenticeproject/tap_plg.git}"
PLG_API_PORT="${PLG_API_PORT:-8006}"
PLG_DB_CONTAINER="${PLG_DB_CONTAINER:-plg-postgresdb}"
PLG_CLIP_MODEL="${PLG_CLIP_MODEL:-ViT-L-14}"
PLG_SERVICE_USER="${PLG_SERVICE_USER:-${PLG_SSH_USER}}"

DB_PASS="${DB_PASS:-}"
PLG_DB_NAME="${PLG_DB_NAME:-plg_db}"
PLG_DB_USER="${PLG_DB_USER:-plg}"
PLG_DB_PORT="${PLG_DB_PORT:-5432}"

GITHUB_TOKEN="${GITHUB_TOKEN:-}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-7}"
PEM_FILE="${PEM_FILE:-}"

PYTHON_VERSION="${PYTHON_VERSION:-3.10}"

ENABLE_DEV_MODE="${ENABLE_DEV_MODE:-false}"
RESTORE_BACKUP="${RESTORE_BACKUP:-false}"
BACKUP_DB_PATH="${BACKUP_DB_PATH:-}"

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --pem <path>              Path to .pem file for SSH"
    echo "  --server <ip>             Remote server IP or hostname"
    echo "  --user <user>             SSH user (default: gcp-data)"
    echo "  --service-user <user>     Linux user to run PLG (defaults to SSH user)"
    echo "  --branch <branch>         PLG git branch (default: plg_integration)"
    echo "  --repo <url>              PLG git repo URL"
    echo "  --api-port <port>         PLG API port (default: 8006)"
    echo "  --db-container <name>     Podman container name for Postgres (default: plg-postgresdb)"
    echo "  --db-name <name>          PLG database name (default: plg_db)"
    echo "  --db-user <user>          PLG database user (default: plg)"
    echo "  --db-port <port>          PLG Postgres port (default: 5432)"
    echo "  --db-pass <pass>          Database password"
    echo "  --clip-model <model>      CLIP model name (default: ViT-L-14)"
    echo "  --app-dir <path>          App install directory"
    echo "  --venv-dir <path>         Python venv directory"
    echo "  --github-token <token>    GitHub token for private repo access"
    echo "  --log-days <n>            Log retention in days (default: 7)"
    echo "  --restore                 Restore from backup"
    echo "  --backup-db <path>        Path to DB backup .sql.gz"
    echo "  --dev-mode                Enable developer/debug mode"
    echo "  --clean                   Remove existing PLG installation before deploying"
    echo "  --config <path>           Path to config.env file"
    echo "  --local                   Run setup locally (no SSH)"
    echo "  --help                    Show this help"
    exit 0
}

LOCAL_MODE=false
CLEAN_INSTALL=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pem)              PEM_FILE="$2"; shift 2 ;;
        --server)           PLG_SERVER="$2"; shift 2 ;;
        --user)             PLG_SSH_USER="$2"; shift 2 ;;
        --service-user)     PLG_SERVICE_USER="$2"; shift 2 ;;
        --branch)           PLG_BRANCH="$2"; shift 2 ;;
        --repo)             PLG_REPO="$2"; shift 2 ;;
        --api-port)         PLG_API_PORT="$2"; shift 2 ;;
        --db-container)     PLG_DB_CONTAINER="$2"; shift 2 ;;
        --db-name)          PLG_DB_NAME="$2"; shift 2 ;;
        --db-user)          PLG_DB_USER="$2"; shift 2 ;;
        --db-port)          PLG_DB_PORT="$2"; shift 2 ;;
        --db-pass)          DB_PASS="$2"; shift 2 ;;
        --clip-model)       PLG_CLIP_MODEL="$2"; shift 2 ;;
        --app-dir)          PLG_APP_DIR="$2"; shift 2 ;;
        --venv-dir)         PLG_VENV_DIR="$2"; shift 2 ;;
        --github-token)     GITHUB_TOKEN="$2"; shift 2 ;;
        --log-days)         LOG_RETENTION_DAYS="$2"; shift 2 ;;
        --restore)          RESTORE_BACKUP=true; shift ;;
        --backup-db)        BACKUP_DB_PATH="$2"; shift 2 ;;
        --dev-mode)         ENABLE_DEV_MODE=true; shift ;;
        --clean)            CLEAN_INSTALL=true; shift ;;
        --config)           CONFIG_FILE="$2"; source "$CONFIG_FILE"; shift 2 ;;
        --local)            LOCAL_MODE=true; shift ;;
        --help)             usage ;;
        *)                  echo "Unknown option: $1"; usage ;;
    esac
done

PLG_SERVICE_USER="${PLG_SERVICE_USER:-${PLG_SSH_USER}}"
PLG_APP_DIR="${PLG_APP_DIR:-/home/${PLG_SERVICE_USER}/tap_plg}"
PLG_VENV_DIR="${PLG_VENV_DIR:-/home/${PLG_SERVICE_USER}/tap_plg/venv}"

if [[ -z "$DB_PASS" ]]; then
    echo -n "Enter password for PLG database user '${PLG_DB_USER}': "
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
    chmod 600 "$PEM_FILE"
    if [[ -z "$PLG_SERVER" ]]; then
        echo "Error: PLG_SERVER is not set. Use --server or config.env."
        exit 1
    fi
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30"
if [[ "$LOCAL_MODE" == false ]]; then
    SSH_OPTS="$SSH_OPTS -i ${PEM_FILE}"
fi

run_remote() {
    local cmd="$1"
    if [[ "$LOCAL_MODE" == true ]]; then
        bash -c "$cmd"
    else
        ssh $SSH_OPTS "${PLG_SSH_USER}@${PLG_SERVER}" "$cmd"
    fi
}

run_as_plg() {
    local script="$1"
    local full_script="
export HOME=/home/${PLG_SERVICE_USER}
export PATH=\$PATH:/usr/local/bin
export XDG_RUNTIME_DIR=/run/user/\$(id -u)
export DBUS_SESSION_BUS_ADDRESS=unix:path=\${XDG_RUNTIME_DIR}/bus
${script}"
    if [[ "$LOCAL_MODE" == true ]]; then
        sudo -u "${PLG_SERVICE_USER}" bash <(echo "$full_script")
    else
        echo "$full_script" | ssh $SSH_OPTS "${PLG_SSH_USER}@${PLG_SERVER}" "sudo -u ${PLG_SERVICE_USER} bash"
    fi
}

copy_to_remote() {
    local src="$1"
    local dst="$2"
    if [[ "$LOCAL_MODE" == false ]]; then
        scp $SSH_OPTS "$src" "${PLG_SSH_USER}@${PLG_SERVER}:${dst}"
    else
        cp "$src" "$dst"
    fi
}

echo "==> [0/10] Purging previous PLG installation and freeing disk space"

run_remote "sudo -u ${PLG_SERVICE_USER} bash -c '
    export XDG_RUNTIME_DIR=/run/user/\$(id -u)
    export DBUS_SESSION_BUS_ADDRESS=unix:path=\${XDG_RUNTIME_DIR}/bus
    systemctl --user stop container-${PLG_DB_CONTAINER}.service plg_app.service 2>/dev/null || true
    systemctl --user disable container-${PLG_DB_CONTAINER}.service plg_app.service 2>/dev/null || true
    podman stop ${PLG_DB_CONTAINER} 2>/dev/null || true
    podman rm -f -v ${PLG_DB_CONTAINER} 2>/dev/null || true
    podman system prune -af --volumes 2>/dev/null || true
'"

run_remote "
sudo rm -rf ${PLG_APP_DIR}
sudo rm -rf /home/${PLG_SSH_USER}/.cache/pip
sudo rm -rf /home/${PLG_SSH_USER}/.cache/huggingface
sudo rm -rf /home/${PLG_SSH_USER}/.cache/torch
sudo rm -rf /home/${PLG_SERVICE_USER}/.cache/pip
sudo rm -rf /home/${PLG_SERVICE_USER}/.cache/huggingface
sudo rm -rf /home/${PLG_SERVICE_USER}/.cache/torch
sudo rm -rf /root/.cache/pip
sudo rm -f /home/${PLG_SERVICE_USER}/.config/systemd/user/container-${PLG_DB_CONTAINER}.service
sudo rm -f /home/${PLG_SERVICE_USER}/.config/systemd/user/plg_app.service
sudo rm -f /home/${PLG_SERVICE_USER}/.config/cni/net.d/tap_plg_plg-network.conflist
sudo find /tmp -mindepth 1 -delete 2>/dev/null || true
sudo find /var/tmp -mindepth 1 -delete 2>/dev/null || true
sudo apt-get clean -y
sudo apt-get autoremove -y
sudo journalctl --vacuum-size=50M 2>/dev/null || true
sudo find /var/log -type f \( -name '*.gz' -o -name '*.1' -o -name '*.2' \) -delete 2>/dev/null || true
"

run_remote "df -h /"

echo "==> [1/10] Updating packages and installing dependencies"
run_remote "sudo apt-get update -y"
run_remote "sudo apt-get install -y podman vim git python${PYTHON_VERSION}-venv python3-pip"

echo "==> [2/10] Configuring systemd user service delegation"
run_remote "sudo mkdir -p /etc/systemd/system/user@.service.d/"
run_remote "sudo tee /etc/systemd/system/user@.service.d/delegate.conf > /dev/null <<EOF
[Service]
Delegate=cpu cpuset io memory pids
EOF"
run_remote "sudo systemctl daemon-reload"

echo "==> [3/10] Enabling linger for service user"
run_remote "sudo loginctl enable-linger ${PLG_SERVICE_USER}"

echo "==> [4/10] Removing stale CNI network config"
run_as_plg "rm -f \$HOME/.config/cni/net.d/tap_plg_plg-network.conflist 2>/dev/null || true"

echo "==> [5/10] Cloning PLG repository"
PLG_CLONE_URL="$PLG_REPO"
if [[ -n "$GITHUB_TOKEN" ]]; then
    PLG_CLONE_URL="${PLG_REPO/https:\/\//https:\/\/${GITHUB_TOKEN}@}"
fi

run_as_plg "
rm -rf ${PLG_APP_DIR}
git clone --branch ${PLG_BRANCH} ${PLG_CLONE_URL} ${PLG_APP_DIR}
cd ${PLG_APP_DIR}
git checkout ${PLG_BRANCH}
"

echo "==> [6/10] Setting up Python virtual environment and installing dependencies"
run_as_plg "
cd ${PLG_APP_DIR}
python${PYTHON_VERSION} -m venv ${PLG_VENV_DIR}
${PLG_VENV_DIR}/bin/pip install --no-cache-dir --upgrade pip
${PLG_VENV_DIR}/bin/pip install --no-cache-dir podman-compose

if [ -f ${PLG_APP_DIR}/requirements.txt ]; then
    ${PLG_VENV_DIR}/bin/pip install --no-cache-dir -r ${PLG_APP_DIR}/requirements.txt --progress-bar on
elif [ -f ${PLG_APP_DIR}/pyproject.toml ]; then
    ${PLG_VENV_DIR}/bin/pip install --no-cache-dir -e ${PLG_APP_DIR} --progress-bar on
fi
"

echo "==> [7/10] Starting Postgres container via Podman and generating systemd unit"
run_as_plg "
mkdir -p \$HOME/.config/systemd/user/
cd ${PLG_APP_DIR}

${PLG_VENV_DIR}/bin/podman-compose -f docker-postgres.yml up -d 2>/dev/null || true

podman generate systemd --new --files --name ${PLG_DB_CONTAINER}

UNIT_FILE=\"\$(pwd)/container-${PLG_DB_CONTAINER}.service\"
if [ -f \"\$UNIT_FILE\" ]; then
    sed -i '/--pod/d; /--network/d' \"\$UNIT_FILE\"
    sed -i 's/--cpus/-p ${PLG_DB_PORT}:5432 --cpus/' \"\$UNIT_FILE\"
    mv \"\$UNIT_FILE\" \$HOME/.config/systemd/user/
fi

${PLG_VENV_DIR}/bin/podman-compose -f docker-postgres.yml down 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable --now container-${PLG_DB_CONTAINER}.service
"

echo "  Waiting for Postgres to be ready..."
run_as_plg "
for i in \$(seq 1 30); do
    if podman exec ${PLG_DB_CONTAINER} pg_isready -U ${PLG_DB_USER} -d ${PLG_DB_NAME} &>/dev/null; then
        echo 'Postgres is ready'
        break
    fi
    sleep 2
done
"

echo "==> [8/10] Writing PLG environment config"
run_as_plg "
cat > ${PLG_APP_DIR}/.env <<APP_ENV_EOF
DATABASE_URL=postgresql://${PLG_DB_USER}:${DB_PASS}@127.0.0.1:${PLG_DB_PORT}/${PLG_DB_NAME}
DB_HOST=127.0.0.1
DB_PORT=${PLG_DB_PORT}
DB_NAME=${PLG_DB_NAME}
DB_USER=${PLG_DB_USER}
DB_PASS=${DB_PASS}
API_PORT=${PLG_API_PORT}
CLIP_MODEL=${PLG_CLIP_MODEL}
DEBUG=${ENABLE_DEV_MODE}
APP_ENV_EOF
chmod 640 ${PLG_APP_DIR}/.env
"

echo "==> [9/10] Running database migrations"
run_as_plg "
cd ${PLG_APP_DIR}
if [ -f manage.py ]; then
    ${PLG_VENV_DIR}/bin/python manage.py migrate --noinput 2>&1 || echo 'Django migrate failed or not applicable'
elif [ -f alembic.ini ]; then
    ${PLG_VENV_DIR}/bin/alembic upgrade head 2>&1 || echo 'Alembic migrate failed or not applicable'
else
    echo 'No migration runner detected, skipping migrations'
fi
"

if [[ "$RESTORE_BACKUP" == "true" && -n "$BACKUP_DB_PATH" ]]; then
    echo "==> Restoring database backup"
    if [[ "$LOCAL_MODE" == false ]]; then
        remote_db="/home/${PLG_SSH_USER}/plg_restore_db.sql.gz"
        copy_to_remote "$BACKUP_DB_PATH" "$remote_db"
    else
        remote_db="$BACKUP_DB_PATH"
    fi
    run_as_plg "gunzip -c ${remote_db} | podman exec -i ${PLG_DB_CONTAINER} psql -U ${PLG_DB_USER} -d ${PLG_DB_NAME}"
fi

echo "==> Downloading CLIP model"
run_as_plg "
cd ${PLG_APP_DIR}
if [ -f scripts/download_clip_model.py ]; then
    ${PLG_VENV_DIR}/bin/python scripts/download_clip_model.py --model ${PLG_CLIP_MODEL}
else
    echo 'CLIP download script not found, skipping'
fi
"

echo "==> [10/10] Configuring and starting PLG API systemd user service"
run_as_plg "
cat > \$HOME/.config/systemd/user/plg_app.service <<SVCEOF
[Unit]
Description=PLG App
After=container-${PLG_DB_CONTAINER}.service
Requires=container-${PLG_DB_CONTAINER}.service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${PLG_APP_DIR}
ExecStart=${PLG_VENV_DIR}/bin/python3 ${PLG_APP_DIR}/app.py
Restart=always
RestartSec=10
Environment=HOME=/home/${PLG_SERVICE_USER}
Environment=PATH=${PLG_VENV_DIR}/bin:/usr/local/bin:/usr/bin:/bin
Environment=DB_HOST=127.0.0.1
Environment=DB_PORT=${PLG_DB_PORT}
Environment=DB_NAME=${PLG_DB_NAME}
Environment=DB_USER=${PLG_DB_USER}
Environment=DB_PASS=${DB_PASS}
Environment=API_PORT=${PLG_API_PORT}
Environment=CLIP_MODEL=${PLG_CLIP_MODEL}
Environment=DEBUG=${ENABLE_DEV_MODE}

[Install]
WantedBy=default.target
SVCEOF

systemctl --user daemon-reload
systemctl --user enable --now plg_app.service
"

run_as_plg "systemctl --user status plg_app.service --no-pager || true"

run_as_plg "find /home/${PLG_SERVICE_USER} -name '*.log' -mtime +${LOG_RETENTION_DAYS} -delete 2>/dev/null || true"

echo ""
echo "========================================"
echo " PLG Deployment complete"
echo "========================================"
echo " App dir:      ${PLG_APP_DIR}"
echo " Service user: ${PLG_SERVICE_USER}"
echo " Branch:       ${PLG_BRANCH}"
echo " API port:     ${PLG_API_PORT}  ->  http://${PLG_SERVER:-localhost}:${PLG_API_PORT}"
echo " DB container: ${PLG_DB_CONTAINER} (Postgres on 127.0.0.1:${PLG_DB_PORT})"
echo " DB name:      ${PLG_DB_NAME}"
echo " CLIP model:   ${PLG_CLIP_MODEL}"
echo "========================================"