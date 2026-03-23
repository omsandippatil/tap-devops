#!/bin/bash
set -euo pipefail
echo "=== setup-plg.sh started: $(date) ==="
source /tmp/deploy-secrets.env
echo "=== env loaded: PLG_USER=${PLG_USER} ==="

PLG_HOME="/home/${PLG_USER}"
PLG_DIR="${PLG_HOME}/tap_plg"
VENV="${PLG_DIR}/venv"
XDG_RUNTIME_DIR_VAL="/run/user/$(id -u ${PLG_USER} 2>/dev/null || echo 1000)"

step() { echo ""; echo "===[ $* ]==="; }
ok()   { echo "  OK: $*"; }
info() { echo "  ..: $*"; }
die()  { echo "  FATAL: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

step "A — system packages"
apt-get update -qq
apt-get install -y podman vim git python3-pip python3.10-venv python3-dev >/dev/null 2>&1
apt-get clean
ok "packages installed"

step "B — systemd delegate config"
mkdir -p /etc/systemd/system/user@.service.d/
cat > /etc/systemd/system/user@.service.d/delegate.conf << EOF
[Service]
Delegate=cpu cpuset io memory pids
EOF
systemctl daemon-reload
loginctl enable-linger "${PLG_USER}" 2>/dev/null || true
ok "delegate config set, linger enabled"

step "C — wipe previous install"
set +e
sudo -u "${PLG_USER}" -H bash << SUBSH 2>/dev/null || true
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR_VAL}
systemctl --user stop plg_app.service 2>/dev/null || true
systemctl --user stop container-${PLG_DB_CONTAINER}.service 2>/dev/null || true
systemctl --user disable plg_app.service 2>/dev/null || true
systemctl --user disable container-${PLG_DB_CONTAINER}.service 2>/dev/null || true
podman stop ${PLG_DB_CONTAINER} 2>/dev/null || true
podman rm -f ${PLG_DB_CONTAINER} 2>/dev/null || true
SUBSH
set -e
rm -rf "${PLG_DIR}" 2>/dev/null || true
rm -f "${PLG_HOME}/.config/cni/net.d/tap_plg_plg-network.conflist" 2>/dev/null || true
rm -f "${PLG_HOME}/.config/systemd/user/plg_app.service" 2>/dev/null || true
rm -f "${PLG_HOME}/.config/systemd/user/container-${PLG_DB_CONTAINER}.service" 2>/dev/null || true
ok "wiped"

step "D — clone repo"
sudo -u "${PLG_USER}" -H bash << SUBSH || die "git clone failed"
set -e
export HOME=${PLG_HOME}
cd ${PLG_HOME}
git clone ${PLG_REPO} tap_plg
cd tap_plg
git checkout ${PLG_BRANCH}
SUBSH
ok "repo cloned"

step "E — Python venv and podman-compose"
sudo -u "${PLG_USER}" -H bash << SUBSH || die "venv failed"
set -e
export HOME=${PLG_HOME}
python3 -m venv ${VENV}
${VENV}/bin/pip install --quiet --upgrade pip
${VENV}/bin/pip install --quiet podman-compose
if [ -f "${PLG_DIR}/requirements.txt" ]; then
  ${VENV}/bin/pip install --quiet -r "${PLG_DIR}/requirements.txt"
fi
if [ -f "${PLG_DIR}/api/requirements.txt" ]; then
  ${VENV}/bin/pip install --quiet -r "${PLG_DIR}/api/requirements.txt"
fi
SUBSH
ok "venv ready"

step "F — PostgreSQL container"
mkdir -p "${PLG_HOME}/.config/systemd/user/"
chown -R "${PLG_USER}:${PLG_USER}" "${PLG_HOME}/.config"

sudo -u "${PLG_USER}" -H bash << SUBSH || die "container start failed"
set -e
export HOME=${PLG_HOME}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR_VAL}
cd ${PLG_DIR}

podman stop ${PLG_DB_CONTAINER} 2>/dev/null || true
podman rm -f ${PLG_DB_CONTAINER} 2>/dev/null || true

if [ -f "docker-postgres.yml" ]; then
  ${VENV}/bin/podman-compose -f docker-postgres.yml up -d 2>/dev/null || true
fi

if ! podman ps | grep -q "${PLG_DB_CONTAINER}"; then
  podman run -d --name "${PLG_DB_CONTAINER}" \
    -e POSTGRES_PASSWORD="${PLG_DB_PASS}" \
    -e POSTGRES_DB=plg_db \
    -p 5432:5432 \
    postgres:14
fi
sleep 10
podman ps | grep -q "${PLG_DB_CONTAINER}" || exit 1
SUBSH
ok "DB container running"

step "G — systemd unit for DB container"
sudo -u "${PLG_USER}" -H bash << SUBSH || true
set -e
export HOME=${PLG_HOME}
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR_VAL}
cd ${PLG_HOME}

podman generate systemd --new --files --name "${PLG_DB_CONTAINER}" 2>/dev/null || true

if [ -f "container-${PLG_DB_CONTAINER}.service" ]; then
  sed -i '/-pod\|-network/d' "container-${PLG_DB_CONTAINER}.service"
  sed -i "s|ExecStart=.*podman run|ExecStart=podman run -p 5432:5432|" "container-${PLG_DB_CONTAINER}.service" 2>/dev/null || true
  mv "container-${PLG_DB_CONTAINER}.service" "${PLG_HOME}/.config/systemd/user/"
fi

${VENV}/bin/podman-compose -f ${PLG_DIR}/docker-postgres.yml down 2>/dev/null || podman stop "${PLG_DB_CONTAINER}" 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable --now "container-${PLG_DB_CONTAINER}.service"
sleep 8
podman ps | grep -q "${PLG_DB_CONTAINER}" || exit 1
SUBSH
ok "DB container service enabled"

step "H — download CLIP model"
sudo -u "${PLG_USER}" -H bash << SUBSH || true
set -e
export HOME=${PLG_HOME}
if [ -f "${PLG_DIR}/scripts/download_clip_model.py" ]; then
  ${VENV}/bin/python3 "${PLG_DIR}/scripts/download_clip_model.py" --model "${PLG_CLIP_MODEL}" 2>/dev/null || true
fi
SUBSH
ok "model step done"

step "I — detect app entrypoint"
APP_CMD=""
if [ -f "${PLG_DIR}/api/api.py" ]; then
  APP_CMD="${VENV}/bin/uvicorn api:app --host 0.0.0.0 --port ${PLG_API_PORT}"
  APP_WORKDIR="${PLG_DIR}/api"
elif [ -f "${PLG_DIR}/api/main.py" ]; then
  APP_CMD="${VENV}/bin/uvicorn main:app --host 0.0.0.0 --port ${PLG_API_PORT}"
  APP_WORKDIR="${PLG_DIR}/api"
elif [ -f "${PLG_DIR}/app.py" ]; then
  APP_CMD="${VENV}/bin/python3 ${PLG_DIR}/app.py"
  APP_WORKDIR="${PLG_DIR}"
else
  APP_CMD="${VENV}/bin/python3 ${PLG_DIR}/app.py"
  APP_WORKDIR="${PLG_DIR}"
fi
info "entrypoint: $APP_CMD"

step "J — plg_app systemd service"
mkdir -p "${PLG_HOME}/.config/systemd/user/"
cat > "${PLG_HOME}/.config/systemd/user/plg_app.service" << EOF
[Unit]
Description=PLG App
After=container-${PLG_DB_CONTAINER}.service
Requires=container-${PLG_DB_CONTAINER}.service
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${APP_WORKDIR}
Environment=PLG_DB_PASS=${PLG_DB_PASS}
Environment=DATABASE_URL=postgresql://postgres:${PLG_DB_PASS}@localhost:5432/plg_db
ExecStart=${APP_CMD}
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF

chown -R "${PLG_USER}:${PLG_USER}" "${PLG_HOME}/.config/systemd"

sudo -u "${PLG_USER}" -H bash << SUBSH || die "plg_app service failed"
set -e
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR_VAL}
systemctl --user daemon-reload
systemctl --user enable --now plg_app.service
sleep 12
systemctl --user is-active --quiet plg_app.service
SUBSH
ok "plg_app service running"

echo ""
HTTP=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 8 "http://127.0.0.1:${PLG_API_PORT}/" 2>/dev/null || echo 000)
echo "  Smoke: http://127.0.0.1:${PLG_API_PORT} => HTTP $HTTP"
echo "  PLG App done: http://${PLG_SERVER}:${PLG_API_PORT}"