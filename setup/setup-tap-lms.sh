#!/bin/bash
set -euo pipefail
trap 'echo "  FATAL: script died at line $LINENO (exit $?)" >&2' ERR
echo "=== setup-tap.sh started: $(date) ==="

if [[ -n "${CONFIG_ENV:-}" && "${CONFIG_ENV}" != /* ]]; then
  CONFIG_ENV="$(pwd)/${CONFIG_ENV}"
fi
CONFIG_ENV="${CONFIG_ENV:-/etc/tap/tap-config.env}"
[[ -f "$CONFIG_ENV" ]] || { echo "FATAL: config not found at $CONFIG_ENV"; exit 1; }
echo "  Loading config: $CONFIG_ENV"
source "$CONFIG_ENV"

step() { echo ""; echo "===[ $* ]==="; }
ok()   { echo "  OK: $*"; }
info() { echo "  ..: $*"; }
warn() { echo "  WARN: $*"; }
die()  { echo "  FATAL: $*" >&2; exit 1; }

export DEBIAN_FRONTEND=noninteractive

TAP_DB_NAME="${TAP_SITE//./_}"; TAP_DB_NAME="${TAP_DB_NAME//-/_}"; TAP_DB_NAME="${TAP_DB_NAME##_}"
COMPOSE_DIR="/opt/tap"
CRED_DIR="$([[ $EUID -eq 0 ]] && echo /etc/tap || echo /opt/tap/secrets)"
CRED_FILE="${CRED_DIR}/credentials.env"

step "0 — credential vault"
mkdir -p "$CRED_DIR" && chmod 700 "$CRED_DIR"

gen_pass() {
  python3 -c "import secrets,string; a=string.ascii_letters+string.digits+'!@#%^&*'; print(''.join(secrets.choice(a) for _ in range(24)),end='')"
}

if [[ -f "$CRED_FILE" ]] && grep -q "TAP_DB_PASS=" "$CRED_FILE" 2>/dev/null; then
  source "$CRED_FILE"
  info "Loaded existing credentials from $CRED_FILE"
else
  TAP_DB_PASS="$(gen_pass)"; TAP_ADMIN_PASS="$(gen_pass)"; TAP_DB_PG_SUPERPASS="$(gen_pass)"
  printf '# TAP credentials — %s\nTAP_DB_PASS=%s\nTAP_ADMIN_PASS=%s\nTAP_DB_PG_SUPERPASS=%s\n' \
    "$(date)" "$TAP_DB_PASS" "$TAP_ADMIN_PASS" "$TAP_DB_PG_SUPERPASS" > "$CRED_FILE"
  chmod 600 "$CRED_FILE"
  ok "New credentials saved to $CRED_FILE"
fi

step "A — Docker engine"
if ! command -v docker &>/dev/null; then
  apt-get update -qq
  apt-get install -y ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  _ARCH="$(dpkg --print-architecture)"; _CS="$(lsb_release -cs)"
  echo "deb [arch=${_ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${_CS} stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  if systemctl is-system-running &>/dev/null; then
    systemctl enable docker && systemctl start docker
  else
    nohup dockerd > /var/log/dockerd.log 2>&1 & sleep 8
  fi
  ok "Docker installed"
else
  ok "Docker present: $(docker --version)"
fi
if ! docker compose version &>/dev/null 2>&1; then
  for _p in /usr/libexec/docker/cli-plugins/docker-compose /usr/lib/docker/cli-plugins/docker-compose; do
    [[ -f "$_p" ]] && ln -sf "$_p" /usr/local/bin/docker-compose && break
  done
fi
docker compose version &>/dev/null || die "docker compose plugin not found"

step "B — working directory $COMPOSE_DIR"
mkdir -p "${COMPOSE_DIR}"/{postgres-init,nginx,scripts}
ok "dirs created"

step "C — postgres init"
cat > "${COMPOSE_DIR}/postgres-init/01-tap.sql" << SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${TAP_DB_NAME}') THEN
    CREATE ROLE "${TAP_DB_NAME}" WITH LOGIN PASSWORD '${TAP_DB_PASS}';
  ELSE
    ALTER ROLE "${TAP_DB_NAME}" WITH PASSWORD '${TAP_DB_PASS}';
  END IF;
END
\$\$;
SELECT 'CREATE DATABASE "${TAP_DB_NAME}" OWNER "${TAP_DB_NAME}"'
  WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${TAP_DB_NAME}') \gexec
GRANT ALL PRIVILEGES ON DATABASE "${TAP_DB_NAME}" TO "${TAP_DB_NAME}";
SQL
ok "postgres init SQL written"

step "D — frappe-init script"
cat > "${COMPOSE_DIR}/scripts/frappe-init.sh" << INITEOF
#!/bin/bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
TOOL_VENV="\${BENCH_DIR}/.tool-venv"
SENTINEL="\${BENCH_DIR}/.setup-complete"

export HOME="/home/frappe"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

log()      { echo "[init] \$*"; }
log_step() { echo ""; echo "[init] ══ \$* ══"; }

log_step "Waiting for PostgreSQL"
until pg_isready -h postgres -p 5432 -U postgres -q; do
  log "postgres not ready, retrying in 3s..."
  sleep 3
done
log "PostgreSQL ready"

log_step "Waiting for Redis"
for _host in redis-cache redis-queue redis-socketio; do
  until redis-cli -h "\${_host}" -p 6379 ping 2>/dev/null | grep -q PONG; do
    log "\${_host} not ready, retrying..."
    sleep 2
  done
  log "\${_host} ready"
done

if [[ -f "\$SENTINEL" ]]; then
  log "Sentinel found — setup already complete. Exiting."
  exit 0
fi

log_step "Tool venv + bench CLI"
mkdir -p "\${BENCH_DIR}"
if [[ ! -f "\${TOOL_VENV}/bin/bench" ]]; then
  python3 -m venv "\${TOOL_VENV}"
  "\${TOOL_VENV}/bin/pip" install --upgrade pip setuptools wheel -q
  "\${TOOL_VENV}/bin/pip" install frappe-bench psycopg2-binary -q
  log "bench CLI installed"
else
  log "bench CLI already present"
fi

export PATH="\${TOOL_VENV}/bin:\${PATH}"

log_step "bench init frappe v15"
if [[ -d "\${BENCH_DIR}/apps/frappe" ]] && [[ ! -f "\${BENCH_DIR}/env/bin/pip" ]]; then
  log "Detected broken partial bench install — removing and reinitialising"
  rm -rf "\${BENCH_DIR}/apps" "\${BENCH_DIR}/env" "\${BENCH_DIR}/logs" "\${BENCH_DIR}/config"
fi
if [[ ! -d "\${BENCH_DIR}/apps/frappe" ]]; then
  cd /home/frappe
  "\${TOOL_VENV}/bin/bench" init frappe-bench \
    --frappe-branch version-15 \
    --python python3 \
    --no-procfile \
    --verbose
  "\${BENCH_DIR}/env/bin/pip" install psycopg2-binary -q
  log "bench init done"
else
  log "bench already initialised"
fi

log_step "common_site_config"
mkdir -p "\${BENCH_DIR}/sites"
python3 -c "
import json, os
cfg = {
  'redis_cache':                  'redis://redis-cache:6379',
  'redis_queue':                  'redis://redis-queue:6379',
  'redis_socketio':               'redis://redis-socketio:6379',
  'restart_supervisor_on_update': False,
  'socketio_port':                int(os.environ['TAP_SOCKETIO_PORT']),
  'webserver_port':               int(os.environ['TAP_GUNICORN_PORT']),
  'serve_default_site':           True,
  'default_site':                 os.environ['TAP_SITE'],
}
json.dump(cfg, open(os.environ['HOME'] + '/frappe-bench/sites/common_site_config.json', 'w'), indent=2)
"
printf 'frappe\n%s\n' "\${TAP_APP}" > "\${BENCH_DIR}/sites/apps.txt"

log_step "Clone \${TAP_APP}"
if [[ ! -d "\${BENCH_DIR}/apps/\${TAP_APP}" ]]; then
  cd "\${BENCH_DIR}"
  GIT_TERMINAL_PROMPT=0 git clone \
    --depth=1 --single-branch --no-tags \
    -b "\${TAP_BRANCH}" "\${TAP_REPO}" "apps/\${TAP_APP}"

  while IFS= read -r f; do
    if grep -q 'frappe\.Model' "\$f" 2>/dev/null; then
      grep -q 'from frappe.model.document import Document' "\$f" \
        || sed -i \$'1s/^/from frappe.model.document import Document\n/' "\$f"
      sed -i 's/class \([^(]*\)(frappe\.Model)/class \1(Document)/g' "\$f"
    fi
  done < <(find "apps/\${TAP_APP}" -name '*.py')

  "\${BENCH_DIR}/env/bin/pip" install -e "apps/\${TAP_APP}" -q
  log "\${TAP_APP} cloned and installed"
else
  log "\${TAP_APP} already cloned"
fi

log_step "new-site \${TAP_SITE}"
cd "\${BENCH_DIR}"
if [[ ! -f "\${BENCH_DIR}/sites/\${TAP_SITE}/site_config.json" ]]; then
  "\${BENCH_DIR}/env/bin/bench" new-site "\${TAP_SITE}" \
    --admin-password "\${TAP_ADMIN_PASS}" \
    --db-type postgres \
    --db-host postgres \
    --db-port 5432 \
    --db-root-username postgres \
    --db-root-password "\${TAP_DB_PG_SUPERPASS}" \
    --force
  log "site created"
else
  log "site already exists"
fi

log_step "install-app + migrate"
"\${BENCH_DIR}/env/bin/bench" --site "\${TAP_SITE}" install-app "\${TAP_APP}" 2>/dev/null || log "app may already be installed"
"\${BENCH_DIR}/env/bin/bench" --site "\${TAP_SITE}" migrate
"\${BENCH_DIR}/env/bin/bench" setup socketio
"\${BENCH_DIR}/env/bin/bench" --site "\${TAP_SITE}" set-admin-password "\${TAP_ADMIN_PASS}"
"\${BENCH_DIR}/env/bin/bench" --site "\${TAP_SITE}" clear-cache

log_step "site_config update"
echo "\${TAP_SITE}" > "\${BENCH_DIR}/sites/currentsite.txt"
python3 -c "
import json, os
p = os.environ['HOME'] + '/frappe-bench/sites/' + os.environ['TAP_SITE'] + '/site_config.json'
c = json.load(open(p))
c.update({
  'developer_mode':     0,
  'serve_default_site': True,
  'host_name':          'http://' + os.environ['TAP_PUBLIC_DOMAIN'],
  'db_host':            'postgres',
  'db_port':            5432,
  'allow_cors':         '*',
})
json.dump(c, open(p, 'w'), indent=2)
"

log_step "build assets"
"\${BENCH_DIR}/env/bin/bench" build || log "bench build returned non-zero — continuing"

log_step "Writing sentinel"
echo "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "\${SENTINEL}"
log "Setup complete. Sentinel written to \${SENTINEL}"
log ""
log "┌─────────────────────────────────────────┐"
log "│  TAP LMS init finished successfully      │"
log "│  Site   : \${TAP_SITE}"
log "│  Domain : http://\${TAP_PUBLIC_DOMAIN}"
log "└─────────────────────────────────────────┘"
INITEOF

chmod +x "${COMPOSE_DIR}/scripts/frappe-init.sh"
sed -i 's/\r//' "${COMPOSE_DIR}/scripts/frappe-init.sh"
ok "frappe-init.sh written"

step "E — frappe-web entrypoint"
cat > "${COMPOSE_DIR}/scripts/frappe-web-entrypoint.sh" << WEBEOF
#!/bin/bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
SENTINEL="\${BENCH_DIR}/.setup-complete"

export HOME="/home/frappe"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\${BENCH_DIR}/env/bin"

echo "[web] Checking for setup sentinel..."
_waited=0
until [[ -f "\$SENTINEL" ]]; do
  echo "[web] Waiting for frappe-init to complete... (\${_waited}s)"
  sleep 5
  _waited=\$((_waited + 5))
  [[ \$_waited -ge 600 ]] && { echo "[web] FATAL: timed out waiting for sentinel"; exit 1; }
done
echo "[web] Sentinel found (\$(cat "\$SENTINEL")). Starting gunicorn..."

exec "\${BENCH_DIR}/env/bin/gunicorn" \
  --bind=0.0.0.0:\${TAP_GUNICORN_PORT} \
  --workers=4 \
  --worker-class=sync \
  --timeout=120 \
  --chdir="\${BENCH_DIR}/sites" \
  --log-level=info \
  frappe.app:application
WEBEOF

chmod +x "${COMPOSE_DIR}/scripts/frappe-web-entrypoint.sh"
sed -i 's/\r//' "${COMPOSE_DIR}/scripts/frappe-web-entrypoint.sh"
ok "frappe-web-entrypoint.sh written"

step "F — worker entrypoint"
cat > "${COMPOSE_DIR}/scripts/frappe-worker-entrypoint.sh" << WEOF
#!/bin/bash
set -euo pipefail

BENCH_DIR="/home/frappe/frappe-bench"
SENTINEL="\${BENCH_DIR}/.setup-complete"

export HOME="/home/frappe"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\${BENCH_DIR}/env/bin"

_waited=0
until [[ -f "\$SENTINEL" ]]; do
  echo "[worker] Waiting for setup sentinel... (\${_waited}s)"
  sleep 5
  _waited=\$((_waited + 5))
  [[ \$_waited -ge 600 ]] && { echo "[worker] FATAL: timeout waiting for sentinel"; exit 1; }
done

exec "\$@"
WEOF

chmod +x "${COMPOSE_DIR}/scripts/frappe-worker-entrypoint.sh"
sed -i 's/\r//' "${COMPOSE_DIR}/scripts/frappe-worker-entrypoint.sh"
ok "frappe-worker-entrypoint.sh written"

step "G — Dockerfile"
cat > "${COMPOSE_DIR}/Dockerfile" << 'DOCKERFILE'
FROM python:3.11-slim-bookworm

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      bash \
      git curl build-essential \
      libpq-dev libffi-dev libssl-dev \
      postgresql-client \
      redis-tools \
      xvfb libfontconfig1 libxrender1 libxext6 \
      fonts-liberation \
    && curl -fsSL https://deb.nodesource.com/setup_18.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g yarn \
    && pip install --upgrade pip -q \
    && useradd -ms /bin/bash frappe \
    && mkdir -p /home/frappe/frappe-bench \
    && chown -R frappe:frappe /home/frappe \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

COPY scripts/frappe-init.sh              /usr/local/bin/frappe-init
COPY scripts/frappe-web-entrypoint.sh    /usr/local/bin/frappe-web-start
COPY scripts/frappe-worker-entrypoint.sh /usr/local/bin/frappe-worker-start

RUN sed -i 's/\r//' /usr/local/bin/frappe-init \
                     /usr/local/bin/frappe-web-start \
                     /usr/local/bin/frappe-worker-start \
    && chmod 0755 /usr/local/bin/frappe-init \
                  /usr/local/bin/frappe-web-start \
                  /usr/local/bin/frappe-worker-start \
    && chown root:root /usr/local/bin/frappe-init \
                       /usr/local/bin/frappe-web-start \
                       /usr/local/bin/frappe-worker-start

ENV PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

USER frappe
WORKDIR /home/frappe
DOCKERFILE
ok "Dockerfile written"

step "H — docker-compose.yml"
cat > "${COMPOSE_DIR}/docker-compose.yml" << EOF
x-frappe-env: &frappe-env
  TAP_SITE:             "${TAP_SITE}"
  TAP_APP:              "${TAP_APP}"
  TAP_REPO:             "${TAP_REPO}"
  TAP_BRANCH:           "${TAP_BRANCH}"
  TAP_PUBLIC_DOMAIN:    "${TAP_PUBLIC_DOMAIN}"
  TAP_GUNICORN_PORT:    "${TAP_GUNICORN_PORT}"
  TAP_SOCKETIO_PORT:    "${TAP_SOCKETIO_PORT}"
  TAP_DB_NAME:          "${TAP_DB_NAME}"
  TAP_DB_PASS:          "${TAP_DB_PASS}"
  TAP_DB_PG_SUPERPASS:  "${TAP_DB_PG_SUPERPASS}"
  TAP_ADMIN_PASS:       "${TAP_ADMIN_PASS}"

x-frappe-volumes: &frappe-volumes
  - frappe-bench:/home/frappe/frappe-bench

services:

  postgres:
    image: postgres:15-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER:     postgres
      POSTGRES_PASSWORD: "${TAP_DB_PG_SUPERPASS}"
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./postgres-init:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 20

  redis-cache:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --save "" --loglevel notice
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      retries: 10

  redis-queue:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --save "" --loglevel notice
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      retries: 10

  redis-socketio:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --save "" --loglevel notice
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      retries: 10

  frappe-init:
    build:
      context: .
      dockerfile: Dockerfile
    restart: "no"
    entrypoint: ["/bin/bash", "/usr/local/bin/frappe-init"]
    command: []
    environment: *frappe-env
    volumes: *frappe-volumes
    depends_on:
      postgres:
        condition: service_healthy
      redis-cache:
        condition: service_healthy
      redis-queue:
        condition: service_healthy
      redis-socketio:
        condition: service_healthy

  frappe-web:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    entrypoint: ["/bin/bash", "/usr/local/bin/frappe-web-start"]
    command: []
    environment:
      <<: *frappe-env
      FRAPPE_SITE: "${TAP_SITE}"
    volumes: *frappe-volumes
    depends_on:
      frappe-init:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "curl", "-sf", "-H", "Host: ${TAP_SITE}", "http://localhost:${TAP_GUNICORN_PORT}/api/method/ping"]
      interval: 15s
      timeout: 10s
      retries: 10
      start_period: 30s

  frappe-socketio:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    entrypoint: ["/bin/bash", "/usr/local/bin/frappe-worker-start"]
    command: ["node", "/home/frappe/frappe-bench/apps/frappe/socketio.js"]
    environment: *frappe-env
    volumes: *frappe-volumes
    depends_on:
      frappe-init:
        condition: service_completed_successfully

  frappe-schedule:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    entrypoint: ["/bin/bash", "/usr/local/bin/frappe-worker-start"]
    command: ["/home/frappe/frappe-bench/env/bin/bench", "--site", "${TAP_SITE}", "schedule"]
    environment: *frappe-env
    volumes: *frappe-volumes
    depends_on:
      frappe-init:
        condition: service_completed_successfully

  frappe-worker-short:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    entrypoint: ["/bin/bash", "/usr/local/bin/frappe-worker-start"]
    command: ["/home/frappe/frappe-bench/env/bin/bench", "worker", "--queue", "short"]
    environment: *frappe-env
    volumes: *frappe-volumes
    depends_on:
      frappe-init:
        condition: service_completed_successfully

  frappe-worker-long:
    build:
      context: .
      dockerfile: Dockerfile
    restart: unless-stopped
    entrypoint: ["/bin/bash", "/usr/local/bin/frappe-worker-start"]
    command: ["/home/frappe/frappe-bench/env/bin/bench", "worker", "--queue", "long"]
    environment: *frappe-env
    volumes: *frappe-volumes
    depends_on:
      frappe-init:
        condition: service_completed_successfully

  nginx:
    image: nginx:alpine
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./nginx/frappe-tap.conf:/etc/nginx/conf.d/default.conf:ro
      - frappe-bench:/home/frappe/frappe-bench:ro
    depends_on:
      frappe-web:
        condition: service_healthy

volumes:
  postgres-data:
  frappe-bench:
EOF
ok "docker-compose.yml written"

step "I — nginx config"
cat > "${COMPOSE_DIR}/nginx/frappe-tap.conf" << EOF
upstream frappe_tap_g { server frappe-web:${TAP_GUNICORN_PORT}; keepalive 16; }
upstream frappe_tap_s { server frappe-socketio:${TAP_SOCKETIO_PORT}; }

server {
  listen 80;
  server_name ${TAP_PUBLIC_DOMAIN} _;
  client_max_body_size 50m;

  proxy_set_header Host               "${TAP_SITE}";
  proxy_set_header X-Real-IP          \$remote_addr;
  proxy_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto  http;
  proxy_set_header X-Frappe-Site-Name "${TAP_SITE}";

  location /assets {
    alias /home/frappe/frappe-bench/sites/assets;
    expires 1y;
    add_header Cache-Control "public, immutable";
    try_files \$uri =404;
  }
  location /files {
    alias /home/frappe/frappe-bench/sites/${TAP_SITE}/public/files;
    try_files \$uri =404;
  }
  location /socket.io {
    proxy_pass http://frappe_tap_s;
    proxy_http_version 1.1;
    proxy_set_header Upgrade    \$http_upgrade;
    proxy_set_header Connection "upgrade";
  }
  location / {
    proxy_pass         http://frappe_tap_g;
    proxy_http_version 1.1;
    proxy_read_timeout 120s;
    gzip on;
    gzip_types text/plain text/css application/json application/javascript;
  }
}
EOF
ok "nginx config written"

step "J — tap-ctl helper"
cat > /usr/local/bin/tap-ctl << 'CTLEOF'
#!/usr/bin/env bash
COMPOSE_DIR="/opt/tap"
cd "${COMPOSE_DIR}"

case "${1:-help}" in
  up)        docker compose up -d --build ;;
  down)      docker compose down ;;
  restart)   docker compose restart "${2:-}" ;;
  logs)      docker compose logs -f --tail=100 "${2:-}" ;;
  status)    docker compose ps ;;
  init-logs) docker compose logs -f frappe-init ;;
  bench)     shift; docker compose exec frappe-web /home/frappe/frappe-bench/env/bin/bench "$@" ;;
  shell)     docker compose exec frappe-web bash ;;
  reinit)
    echo "Removing sentinel and re-running init container..."
    docker compose run --rm --entrypoint /bin/bash frappe-init -c "rm -f /home/frappe/frappe-bench/.setup-complete"
    docker compose up -d --build
    ;;
  reset)
    echo "WARNING: destroys ALL data. Type 'yes': "
    read -r c; [[ "$c" == "yes" ]] || { echo "Aborted."; exit 1; }
    docker compose down -v
    docker compose up -d --build
    ;;
  diagnose)
    echo "=== frappe-init last 80 lines ==="
    docker compose logs --no-log-prefix --tail=80 frappe-init
    echo "=== container states ==="
    docker compose ps
    echo "=== frappe-init exit code ==="
    docker compose ps frappe-init --format json \
      | python3 -c "import sys,json; [print('ExitCode:', o.get('ExitCode','?'), '| State:', o.get('State','?')) for l in sys.stdin for o in [json.loads(l)]]"
    ;;
  *)
    echo "tap-ctl {up|down|restart|logs|init-logs|status|bench|shell|reinit|reset|diagnose}"
    ;;
esac
CTLEOF
chmod +x /usr/local/bin/tap-ctl
ok "tap-ctl installed"

step "K — verify scripts on disk before build"
for _f in \
  "${COMPOSE_DIR}/scripts/frappe-init.sh" \
  "${COMPOSE_DIR}/scripts/frappe-web-entrypoint.sh" \
  "${COMPOSE_DIR}/scripts/frappe-worker-entrypoint.sh"; do
  [[ -f "$_f" ]]       || die "Missing script: $_f"
  [[ -x "$_f" ]]       || die "Not executable: $_f"
  head -1 "$_f" | grep -q '^#!/bin/bash' || die "Bad or missing shebang in: $_f"
  ok "Verified: $_f"
done

step "L — deploy"
cd "${COMPOSE_DIR}"

docker compose down -v 2>/dev/null || true
docker builder prune -f --filter until=1h 2>/dev/null || true

docker compose build --no-cache --pull
ok "images built"

docker compose up -d || true

step "Following frappe-init logs (setup will take 5-15 min on first run)"
echo "  Ctrl+C is safe — containers keep running in background"
echo ""
docker compose logs -f frappe-init &
LOG_PID=$!

MAX_WAIT=1200
WAITED=0
while true; do
  STATUS=$(docker compose ps frappe-init --format json 2>/dev/null \
    | python3 -c "import sys,json; [print(o.get('State','')) for l in sys.stdin for o in [json.loads(l)]]" \
    2>/dev/null | head -1 || echo "unknown")
  if [[ "$STATUS" == "exited" ]]; then
    EXIT_CODE=$(docker compose ps frappe-init --format json 2>/dev/null \
      | python3 -c "import sys,json; [print(o.get('ExitCode','1')) for l in sys.stdin for o in [json.loads(l)]]" \
      2>/dev/null | head -1 || echo "1")
    kill $LOG_PID 2>/dev/null || true
    if [[ "$EXIT_CODE" == "0" ]]; then
      echo ""
      ok "frappe-init completed successfully"
      break
    else
      echo ""
      echo "  === frappe-init container logs ==="
      docker compose logs --no-log-prefix frappe-init 2>&1 | tail -80
      echo "  =================================="
      die "frappe-init exited with code ${EXIT_CODE}"
    fi
  fi
  [[ $WAITED -ge $MAX_WAIT ]] && { kill $LOG_PID 2>/dev/null || true; die "Timed out waiting for frappe-init"; }
  sleep 10
  WAITED=$((WAITED + 10))
done

echo ""
docker compose ps
echo ""
echo "  Credentials : ${CRED_FILE}"
echo "  TAP LMS     : http://${TAP_PUBLIC_DOMAIN}"
echo "  Admin login : Administrator / [see ${CRED_FILE}]"
echo ""
echo "  Management  : tap-ctl {up|down|logs|init-logs|status|bench|shell|reinit|reset|diagnose}"
echo "=== setup-tap.sh finished: $(date) ==="