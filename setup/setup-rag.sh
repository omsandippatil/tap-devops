#!/bin/bash
set -euo pipefail
echo "=== setup-rag.sh started: $(date) ==="
source /tmp/deploy-secrets.env
echo "=== env loaded: RAG_FRAPPE_USER=${RAG_FRAPPE_USER} ==="

FRAPPE_USER="${RAG_FRAPPE_USER}"
FRAPPE_HOME="/home/${FRAPPE_USER}"
BENCH_DIR="${FRAPPE_HOME}/frappe-bench"
BENCH_VENV="${BENCH_DIR}/env"

step() { echo ""; echo "===[ $* ]==="; }
ok()   { echo "  OK: $*"; }
info() { echo "  ..: $*"; }
die()  { echo "  FATAL: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

step "A — system packages"
apt-get update -qq
apt-get install -y \
  build-essential curl git sudo vim virtualenv software-properties-common \
  postgresql postgresql-contrib postgresql-client \
  supervisor redis-server nginx \
  xvfb libfontconfig wkhtmltopdf \
  fail2ban cron npm python3 python3-pip python3-dev python3-venv
apt-get clean
ok "packages installed"

step "B — frappe user"
id -u "${FRAPPE_USER}" &>/dev/null || useradd -ms /bin/bash "${FRAPPE_USER}"
grep -q "${FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL" /etc/sudoers 2>/dev/null \
  || echo "${FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers
ok "user ready"

step "C — stop services and wipe"
set +e
supervisorctl stop all 2>/dev/null
systemctl stop supervisor 2>/dev/null
pkill -9 -f "gunicorn|frappe" 2>/dev/null
sleep 3
set -e
for target in \
  "${BENCH_DIR}" \
  "${FRAPPE_HOME}/venv" \
  /etc/nginx/conf.d/frappe-rag.conf \
  /etc/nginx/sites-available/rag.conf \
  /etc/nginx/sites-enabled/rag.conf \
  /etc/supervisor/conf.d/frappe-rag.conf; do
  if [ -e "$target" ] || [ -L "$target" ]; then
    chmod -R 777 "$target" 2>/dev/null || true
    rm -rf "$target"
    info "removed $target"
  fi
done
ok "wiped"

step "D — PostgreSQL"
systemctl enable postgresql
systemctl start postgresql
sleep 5
sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${RAG_DB_PASS}';" 2>/dev/null || true
ok "PostgreSQL running"

step "E — Node.js via nvm + yarn"
sudo -u "${FRAPPE_USER}" -H bash << 'SUBSH' || true
export HOME=/home/${FRAPPE_USER:-frappe}
curl -s https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash >/dev/null 2>&1
source ~/.profile 2>/dev/null || true
source ~/.nvm/nvm.sh 2>/dev/null || true
nvm install 16.15.0 >/dev/null 2>&1 || true
SUBSH
npm install -g yarn >/dev/null 2>&1 || true
ok "node/yarn ready"

step "F — install frappe-bench CLI"
pip3 install frappe-bench >/dev/null 2>&1
ok "frappe-bench CLI installed"

step "G — bench init Frappe v14"
sudo -u "${FRAPPE_USER}" -H bash << SUBSH || die "bench init failed"
set -e
export HOME=${FRAPPE_HOME}
cd ${FRAPPE_HOME}
pip3 install frappe-bench 2>/dev/null || pip install frappe-bench 2>/dev/null
bench init frappe-bench --frappe-branch version-14 --python python3 --no-procfile
SUBSH
[ -d "${BENCH_DIR}" ] || die "bench dir missing"
ok "bench initialised"

step "H — Redis"
systemctl enable redis-server
systemctl restart redis-server
sleep 3
ok "Redis running"

step "I — common_site_config.json"
cat > "${BENCH_DIR}/sites/common_site_config.json" << EOF
{
  "redis_cache":   "redis://127.0.0.1:6379",
  "redis_queue":   "redis://127.0.0.1:6379",
  "redis_socketio":"redis://127.0.0.1:6379"
}
EOF
chown -R "${FRAPPE_USER}:${FRAPPE_USER}" "${BENCH_DIR}/sites"
ok "common_site_config.json written"

step "J — new-site, apps, migrate, build"
sudo -u "${FRAPPE_USER}" -H bash << SUBSH || die "site setup failed"
set -e
export PATH=${BENCH_VENV}/bin:/usr/local/bin:/usr/bin:/bin
export HOME=${FRAPPE_HOME}
cd ${BENCH_DIR}
bench new-site '${RAG_SITE}' \
  --db-type postgres \
  --db-host 127.0.0.1 \
  --db-port 5432 \
  --db-root-username postgres \
  --db-root-password '${RAG_DB_PASS}' \
  --admin-password '${RAG_ADMIN_PASS}'
bench use '${RAG_SITE}'
bench get-app '${RAG_REPO}' --branch '${RAG_BRANCH}'
bench --site '${RAG_SITE}' install-app '${RAG_APP}'
bench get-app '${RAG_EXTRA_REPO}'
bench --site '${RAG_SITE}' install-app '${RAG_EXTRA_APP}'
bench migrate
bench build 2>/dev/null || true
SUBSH
ok "site ready"

step "K — site host config"
sudo -u "${FRAPPE_USER}" -H bash << SUBSH
set -e
export PATH=${BENCH_VENV}/bin:/usr/local/bin:/usr/bin:/bin
export HOME=${FRAPPE_HOME}
cd ${BENCH_DIR}
bench --site '${RAG_SITE}' set-config host_name 'http://${RAG_PUBLIC_DOMAIN}'
SUBSH
ok "host config set"

step "L — supervisor config"
mkdir -p "${BENCH_DIR}/logs"
chown -R "${FRAPPE_USER}:${FRAPPE_USER}" "${BENCH_DIR}"

cat > /etc/supervisor/conf.d/frappe-rag.conf << EOF
[program:frappe-rag-web]
command=${BENCH_VENV}/bin/gunicorn --chdir=${BENCH_DIR}/sites --bind=127.0.0.1:8000 --workers=2 --worker-class=sync --timeout=120 frappe.app:application
directory=${BENCH_DIR}/sites
autostart=true
autorestart=true
startretries=5
user=${FRAPPE_USER}
stdout_logfile=${BENCH_DIR}/logs/web.log
stderr_logfile=${BENCH_DIR}/logs/web.error.log
environment=HOME="${FRAPPE_HOME}",USER="${FRAPPE_USER}",PATH="${BENCH_VENV}/bin:/usr/local/bin:/usr/bin:/bin"

[program:frappe-rag-schedule]
command=${BENCH_VENV}/bin/python3 -m frappe.utils.scheduler
directory=${BENCH_DIR}/sites
autostart=true
autorestart=true
user=${FRAPPE_USER}
stdout_logfile=${BENCH_DIR}/logs/schedule.log
stderr_logfile=${BENCH_DIR}/logs/schedule.error.log
environment=HOME="${FRAPPE_HOME}",USER="${FRAPPE_USER}",FRAPPE_SITE="${RAG_SITE}",PATH="${BENCH_VENV}/bin:/usr/local/bin:/usr/bin:/bin"

[program:frappe-rag-worker]
command=${BENCH_VENV}/bin/python3 -m frappe.utils.background_jobs --queue short
directory=${BENCH_DIR}/sites
autostart=true
autorestart=true
user=${FRAPPE_USER}
stdout_logfile=${BENCH_DIR}/logs/worker.log
stderr_logfile=${BENCH_DIR}/logs/worker.error.log
environment=HOME="${FRAPPE_HOME}",USER="${FRAPPE_USER}",FRAPPE_SITE="${RAG_SITE}",PATH="${BENCH_VENV}/bin:/usr/local/bin:/usr/bin:/bin"

[group:frappe-rag]
programs=frappe-rag-web,frappe-rag-schedule,frappe-rag-worker
EOF

step "M — start supervisor"
sudo chmod 755 "${FRAPPE_HOME}"
sudo usermod -a -G "${FRAPPE_USER}" www-data 2>/dev/null || true
systemctl enable supervisor
systemctl restart supervisor
sleep 8
supervisorctl reread
supervisorctl update
supervisorctl start frappe-rag: 2>/dev/null || true
sleep 15

if ! ss -tlnp 2>/dev/null | grep -q ":8000 "; then
  info "fallback: starting gunicorn manually"
  sudo -u "${FRAPPE_USER}" -H bash << SUBSH
export PATH=${BENCH_VENV}/bin:/usr/local/bin:/usr/bin:/bin
export HOME=${FRAPPE_HOME}
nohup ${BENCH_VENV}/bin/gunicorn \
  --chdir=${BENCH_DIR}/sites \
  --bind=127.0.0.1:8000 \
  --workers=2 --worker-class=sync --timeout=120 \
  frappe.app:application &
disown
SUBSH
  sleep 12
fi
ss -tlnp 2>/dev/null | grep -q ":8000 " || die "Gunicorn failed"
ok "gunicorn on :8000"

step "N — nginx"
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
cat > /etc/nginx/sites-available/rag.conf << EOF
server {
  listen 80;
  server_name ${RAG_PUBLIC_DOMAIN};
  client_max_body_size 50M;
  location / {
    proxy_pass http://127.0.0.1:8000;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_redirect off;
  }
  location /assets {
    alias ${BENCH_DIR}/sites/assets;
    expires 1y;
    try_files \$uri =404;
  }
}
EOF
ln -sf /etc/nginx/sites-available/rag.conf /etc/nginx/sites-enabled/rag.conf
nginx -t || die "nginx config invalid"
systemctl enable nginx
systemctl reload nginx
ok "nginx configured"

systemctl enable postgresql redis-server nginx supervisor 2>/dev/null || true

echo ""
HTTP=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 8 "http://127.0.0.1:8000/" 2>/dev/null || echo 000)
echo "  Smoke: http://127.0.0.1:8000 => HTTP $HTTP"
supervisorctl status 2>/dev/null || true
echo "  RAG Service done: http://${RAG_PUBLIC_DOMAIN}  login: Administrator / ${RAG_ADMIN_PASS}"