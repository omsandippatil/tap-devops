#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()    { echo -e "${DIM}${CYAN}  ›${RESET} $*"; }
success() { echo -e "${GREEN}  ✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${RESET}  $*"; }
error()   { echo -e "${RED}  ✗${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}  ══  $*  ══${RESET}"; }

RAG_CONFIG_FILE="${RAG_CONFIG_FILE:-./tap-devops/config.env}"
RAG_DRY_RUN="${RAG_DRY_RUN:-false}"
RAG_STEPS="${RAG_STEPS:-}"
RAG_CLEAN="${RAG_CLEAN:-false}"
RAG_CLEAN_ONLY="${RAG_CLEAN_ONLY:-false}"
RAG_RESTART_ONLY="${RAG_RESTART_ONLY:-false}"
RAG_STOP_ONLY="${RAG_STOP_ONLY:-false}"
RAG_STATUS_ONLY="${RAG_STATUS_ONLY:-false}"
RAG_UPDATE_ONLY="${RAG_UPDATE_ONLY:-false}"
RAG_CLEAN_SERVICES="${RAG_CLEAN_SERVICES:-false}"
RAG_CLEAN_BENCH="${RAG_CLEAN_BENCH:-false}"
RAG_FORCE="${RAG_FORCE:-false}"
RAG_VERBOSE="${RAG_VERBOSE:-false}"
RAG_NO_WAIT="${RAG_NO_WAIT:-false}"
RAG_SETUP_NGINX="${RAG_SETUP_NGINX:-false}"
RAG_DEPLOY_DOMAIN="${RAG_DEPLOY_DOMAIN:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)           RAG_CONFIG_FILE="$2"; shift 2 ;;
    --dry-run)          RAG_DRY_RUN=true; shift ;;
    --steps)            RAG_STEPS="$2"; shift 2 ;;
    --clean)            RAG_CLEAN=true; shift ;;
    --clean-only)       RAG_CLEAN=true; RAG_CLEAN_ONLY=true; shift ;;
    --restart)          RAG_RESTART_ONLY=true; shift ;;
    --stop)             RAG_STOP_ONLY=true; shift ;;
    --status)           RAG_STATUS_ONLY=true; shift ;;
    --update)           RAG_UPDATE_ONLY=true; shift ;;
    --clean-services)   RAG_CLEAN_SERVICES=true; shift ;;
    --clean-bench)      RAG_CLEAN_BENCH=true; shift ;;
    --force)            RAG_FORCE=true; shift ;;
    --verbose)          RAG_VERBOSE=true; shift ;;
    --no-wait)          RAG_NO_WAIT=true; shift ;;
    --setup-nginx)      RAG_SETUP_NGINX=true; shift ;;
    --deploy-to-domain) RAG_DEPLOY_DOMAIN=true; RAG_SETUP_NGINX=true; shift ;;
    --help)
      echo "Usage: $0 [--config FILE] [--steps N,N-N] [--clean] [--clean-only]"
      echo "          [--restart] [--stop] [--status] [--update]"
      echo "          [--clean-services] [--clean-bench] [--dry-run] [--setup-nginx]"
      echo "          [--deploy-to-domain] [--force] [--verbose] [--no-wait]"
      echo ""
      echo "  --deploy-to-domain  Serve via Nginx on port 80."
      echo "  --clean-bench       Wipe entire Frappe bench and redeploy from scratch."
      echo "  --clean-services    Remove supervisor config only."
      echo "  --update            git pull + bench migrate + bench restart."
      echo "  --restart           bench restart + rag-app restart."
      echo "  --stop              supervisorctl stop all."
      echo "  --status            Show full service health."
      echo ""
      echo "All flags can also be set as environment variables (e.g. RAG_DEPLOY_DOMAIN=true)."
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -f "$RAG_CONFIG_FILE" ]] || die "Config file not found: $RAG_CONFIG_FILE"
source "$RAG_CONFIG_FILE"
success "Loaded config: $RAG_CONFIG_FILE"

RAG_LOG_DIR="${RAG_LOG_DIR:-./tap-devops/logs}"
RAG_LOG_MAX_MB="${RAG_LOG_MAX_MB:-10}"
RAG_LOG_BACKUP_COUNT="${RAG_LOG_BACKUP_COUNT:-5}"
RAG_DEPLOY_DOMAIN="${RAG_DEPLOY_DOMAIN:-false}"
RAG_DOMAIN_NAME="${RAG_DOMAIN_NAME:-}"
RAG_REDIS_CACHE_PORT="${RAG_REDIS_CACHE_PORT:-13100}"
RAG_REDIS_QUEUE_PORT="${RAG_REDIS_QUEUE_PORT:-11100}"
RAG_PG_HOST="${RAG_PG_HOST:-127.0.0.1}"
RAG_PG_PORT="${RAG_PG_PORT:-5435}"
RAG_PYTHON_VERSION="${RAG_PYTHON_VERSION:-python3.10}"
RAG_FRAPPE_BRANCH="${RAG_FRAPPE_BRANCH:-version-14}"
RAG_NODE_VERSION="${RAG_NODE_VERSION:-16.15.0}"
RAG_TAP_RAG_DIR="${RAG_TAP_RAG_DIR:-/home/azureuser/tap_rag}"
RAG_SERVICE_OWNER="${RAG_SERVICE_OWNER:-azureuser}"
RAG_LLM_PROVIDER="${RAG_LLM_PROVIDER:-openai}"
RAG_LLM_MODEL="${RAG_LLM_MODEL:-gpt-3.5-turbo}"
RAG_LLM_TEMPERATURE="${RAG_LLM_TEMPERATURE:-0.7}"
RAG_LLM_MAX_TOKENS="${RAG_LLM_MAX_TOKENS:-2000}"
RAG_OPENAI_API_KEY="${RAG_OPENAI_API_KEY:-}"
RAG_RABBITMQ_HOST="${RAG_RABBITMQ_HOST:-127.0.0.1}"
RAG_RABBITMQ_PORT="${RAG_RABBITMQ_PORT:-5673}"
RAG_RABBITMQ_USER="${RAG_RABBITMQ_USER:-guest}"
RAG_RABBITMQ_PASSWORD="${RAG_RABBITMQ_PASSWORD:-guest}"
RAG_RABBITMQ_VHOST="${RAG_RABBITMQ_VHOST:-/}"
RAG_LANGCHAIN_VERSION="${RAG_LANGCHAIN_VERSION:-0.1.20}"
RAG_LANGCHAIN_OPENAI_VERSION="${RAG_LANGCHAIN_OPENAI_VERSION:-0.1.8}"

mkdir -p "${RAG_LOG_DIR}"

_rotate_log() {
  local logfile="$1"
  local max_bytes=$(( RAG_LOG_MAX_MB * 1024 * 1024 ))
  local actual_size=0
  [[ -f "$logfile" ]] && actual_size=$(stat -c%s "$logfile" 2>/dev/null || stat -f%z "$logfile" 2>/dev/null || echo 0)
  if (( actual_size >= max_bytes )); then
    local i
    for (( i=RAG_LOG_BACKUP_COUNT-1; i>=1; i-- )); do
      [[ -f "${logfile}.${i}" ]] && mv "${logfile}.${i}" "${logfile}.$((i+1))"
    done
    mv "$logfile" "${logfile}.1"
  fi
}

_log_to_file() {
  local logfile="$1"; shift
  _rotate_log "$logfile"
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$logfile"
}

RAG_DEPLOY_LOG="${RAG_LOG_DIR}/rag-deploy.log"
RAG_APPID_LOG="${RAG_LOG_DIR}/rag-appid-deploy.log"
_deploy_log() { _log_to_file "$RAG_DEPLOY_LOG" "$*"; }
_appid_log()  { _log_to_file "$RAG_APPID_LOG"  "$*"; }
_tee_deploy_log() {
  while IFS= read -r line; do
    echo "$line"
    _log_to_file "$RAG_DEPLOY_LOG" "$line"
  done
}

_effective_url() {
  if $RAG_DEPLOY_DOMAIN; then
    echo "http://${RAG_DOMAIN_NAME:-${RAG_SERVER_HOST}}/"
  else
    echo "http://${RAG_SERVER_HOST}:${RAG_API_PORT:-8009}/"
  fi
}

$RAG_DRY_RUN && warn "DRY RUN — SSH commands printed, not executed."

REQUIRED_VARS=(
  RAG_SERVER_USER RAG_SERVER_HOST RAG_SSH_KEY_PATH
  RAG_GIT_REPO RAG_GIT_BRANCH
  RAG_POSTGRES_PASSWORD
  RAG_FRAPPE_BENCH_DIR RAG_FRAPPE_SITE RAG_FRAPPE_USER RAG_FRAPPE_ADMIN_PASSWORD
  RAG_DEPLOY_SECRET_KEY
)
for v in "${REQUIRED_VARS[@]}"; do
  [[ -n "${!v:-}" ]] || die "Required config var \$$v not set in $RAG_CONFIG_FILE"
done

RAG_SSH_PORT="${RAG_SSH_PORT:-22}"
SSH_OPTS="-i ${RAG_SSH_KEY_PATH} -p ${RAG_SSH_PORT} -o StrictHostKeyChecking=no -o ConnectTimeout=15"
TARGET="${RAG_SERVER_USER}@${RAG_SERVER_HOST}"

RAG_WAIT() { local s="$1"; $RAG_NO_WAIT || sleep "$s"; }

step_enabled() {
  local n="$1"
  [[ -z "$RAG_STEPS" ]] && return 0
  local token lo hi
  local IFS=','
  read -ra _tokens <<< "$RAG_STEPS"
  for token in "${_tokens[@]}"; do
    if [[ "$token" == *-* ]]; then
      lo="${token%-*}"; hi="${token#*-}"
      [[ "$n" -ge "$lo" && "$n" -le "$hi" ]] && return 0
    else
      [[ "$n" == "$token" ]] && return 0
    fi
  done
  return 1
}

run_remote() {
  local desc="$1"; shift
  info "Remote: $desc"
  _deploy_log "Remote: $desc"
  if $RAG_DRY_RUN; then echo -e "  ${YELLOW}$ $*${RESET}"; return 0; fi
  ssh $SSH_OPTS "$TARGET" "$@" 2>&1 | _tee_deploy_log
}

run_remote_heredoc() {
  local desc="$1" body="$2"
  info "Remote: $desc"
  _deploy_log "Remote: $desc"
  if $RAG_DRY_RUN; then echo -e "  ${YELLOW}[heredoc: $desc]${RESET}"; return 0; fi
  local flags="set -euo pipefail"
  $RAG_VERBOSE && flags="${flags}\nset -x"
  ssh $SSH_OPTS "$TARGET" "sudo bash --login -s" 2>&1 <<EOF | _tee_deploy_log
${flags}
${body}
EOF
}

run_remote_as_frappe() {
  local desc="$1" body="$2"
  info "Remote (frappe): $desc"
  _deploy_log "Remote (frappe): $desc"
  if $RAG_DRY_RUN; then echo -e "  ${YELLOW}[frappe heredoc: $desc]${RESET}"; return 0; fi
  local preamble="
export HOME=/home/${RAG_FRAPPE_USER}
export NVM_DIR=\"/home/${RAG_FRAPPE_USER}/.nvm\"
[[ -s \"\${NVM_DIR}/nvm.sh\" ]] && source \"\${NVM_DIR}/nvm.sh\"
nvm use ${RAG_NODE_VERSION} 2>/dev/null || true
export PATH=\"\${HOME}/.local/bin:\${PATH}\"
hash -r 2>/dev/null || true
"
  local flags="set -euo pipefail"
  $RAG_VERBOSE && flags="${flags}\nset -x"
  ssh $SSH_OPTS "$TARGET" "sudo -i -u ${RAG_FRAPPE_USER} bash --login -s" 2>&1 <<EOF | _tee_deploy_log
${preamble}
${flags}
${body}
EOF
}

run_remote_as_owner() {
  local desc="$1" body="$2"
  info "Remote (${RAG_SERVICE_OWNER}): $desc"
  _deploy_log "Remote (${RAG_SERVICE_OWNER}): $desc"
  if $RAG_DRY_RUN; then echo -e "  ${YELLOW}[owner heredoc: $desc]${RESET}"; return 0; fi
  local flags="set -euo pipefail"
  $RAG_VERBOSE && flags="${flags}\nset -x"
  ssh $SSH_OPTS "$TARGET" "sudo -i -u ${RAG_SERVICE_OWNER} bash --login -s" 2>&1 <<EOF | _tee_deploy_log
${flags}
${body}
EOF
}

header "Pre-flight"
_deploy_log "=== RAG Deploy session started ==="
_appid_log  "=== RAG Deploy session started ==="
[[ -f "$RAG_SSH_KEY_PATH" ]] || die "SSH key not found: $RAG_SSH_KEY_PATH"
chmod 600 "$RAG_SSH_KEY_PATH"
success "SSH key OK"

if ! $RAG_DRY_RUN; then
  ssh $SSH_OPTS "$TARGET" "echo 'SSH OK'" > /dev/null || die "Cannot connect to ${TARGET}."
fi
success "SSH connection verified"
_deploy_log "SSH connection verified to ${TARGET}"

$RAG_DEPLOY_DOMAIN && info "Deploy mode: DOMAIN → $(_effective_url)" || info "Deploy mode: PORT → $(_effective_url)"

do_stop() {
  header "Stop RAG"
  _deploy_log "Action: stop"
  run_remote_heredoc "Stop all services" "
set +e
supervisorctl stop all 2>/dev/null || true
supervisorctl status 2>/dev/null || true
echo 'All processes stopped'
"
  success "RAG stopped"
  _deploy_log "RAG stopped"
}

do_restart() {
  header "Restart RAG"
  _deploy_log "Action: restart"
  run_remote_as_frappe "bench restart" "
cd ${RAG_FRAPPE_BENCH_DIR}
bench restart || true
sleep 5
sudo supervisorctl status 2>/dev/null || true
"
  run_remote_as_owner "restart rag-app service" "
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user reset-failed rag-app 2>/dev/null || true
systemctl --user restart rag-app 2>/dev/null || true
sleep 3
systemctl --user status rag-app --no-pager || true
"
  success "RAG restarted"
  _deploy_log "RAG restarted"
}

do_status() {
  header "RAG Health check"
  _deploy_log "Action: status"
  run_remote_heredoc "Full status" "
set +e
echo '=== Supervisor processes ==='
supervisorctl status 2>/dev/null || echo 'supervisor not running'

echo ''
echo '=== System services ==='
for svc in nginx supervisor; do
  printf '  %-20s %s\n' \"\${svc}\" \"\$(systemctl is-active \${svc} 2>/dev/null || echo inactive)\"
done

echo ''
echo '=== Podman containers ==='
sudo -u ${RAG_SERVICE_OWNER} podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null \
  || docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null \
  || echo 'no container runtime found'

echo ''
echo '=== User systemd rag-* services ==='
sudo -u ${RAG_SERVICE_OWNER} systemctl --user status \
  rag-app rag-postgres rag-rabbitmq rag-redis-cache rag-redis-queue \
  --no-pager -l 2>/dev/null || true

echo ''
echo '=== Redis ==='
redis-cli -h 127.0.0.1 -p ${RAG_REDIS_CACHE_PORT} ping 2>/dev/null | grep -q PONG \
  && echo 'redis-cache (${RAG_REDIS_CACHE_PORT}): OK' || echo 'redis-cache (${RAG_REDIS_CACHE_PORT}): not responding'
redis-cli -h 127.0.0.1 -p ${RAG_REDIS_QUEUE_PORT} ping 2>/dev/null | grep -q PONG \
  && echo 'redis-queue (${RAG_REDIS_QUEUE_PORT}): OK' || echo 'redis-queue (${RAG_REDIS_QUEUE_PORT}): not responding'

echo ''
echo '=== Postgres ==='
PGPASSWORD='${RAG_POSTGRES_PASSWORD}' psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres -c 'SELECT 1' >/dev/null 2>&1 \
  && echo 'postgres (${RAG_PG_HOST}:${RAG_PG_PORT}): OK' \
  || echo 'postgres (${RAG_PG_HOST}:${RAG_PG_PORT}): not responding'

echo ''
echo '=== Frappe bench HTTP ==='
curl -sf --max-time 10 -H 'Host: ${RAG_FRAPPE_SITE}' http://127.0.0.1:8000 -o /dev/null \
  && echo 'bench HTTP: OK' || echo 'bench HTTP: not responding'

echo ''
echo '=== Disk ==='
df -h /
"
}

do_clean_services() {
  header "Clean: supervisor services"
  _deploy_log "Action: clean services"
  run_remote_heredoc "Clear supervisor config" "
set +e
supervisorctl stop all 2>/dev/null || true
rm -f /etc/supervisor/conf.d/frappe-bench.conf
supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true
echo 'supervisor config cleared'
"
  success "Supervisor services cleaned"
  _deploy_log "Supervisor services cleaned"
}

do_clean_bench() {
  header "Full clean: wipe Frappe bench"
  _deploy_log "Action: full bench clean"
  run_remote_heredoc "Wipe Frappe bench" "
set +e
supervisorctl stop all 2>/dev/null || true
systemctl stop nginx 2>/dev/null || true

rm -rf ${RAG_FRAPPE_BENCH_DIR}
rm -f /etc/nginx/conf.d/frappe-bench.conf
rm -f /etc/nginx/sites-enabled/frappe-bench.conf
rm -f /etc/supervisor/conf.d/frappe-bench.conf

SITE_DB=\$(echo '${RAG_FRAPPE_SITE}' | tr '.' '_')
PGPASSWORD='${RAG_POSTGRES_PASSWORD}' psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
  -c \"DROP DATABASE IF EXISTS \\\"\${SITE_DB}\\\";\" 2>/dev/null || true

supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true
systemctl start nginx 2>/dev/null || true

echo 'Bench wiped.'
df -h /
"
  success "Frappe bench wiped"
  _deploy_log "Frappe bench wiped"
}

do_update() {
  header "Update: pull latest + migrate + restart"
  _deploy_log "Action: update"
  run_remote_as_frappe "git pull + migrate + restart" "
cd ${RAG_FRAPPE_BENCH_DIR}/apps/rag_service
git remote get-url origin >/dev/null 2>&1 \
  || git remote add origin ${RAG_GIT_REPO}
git remote set-url origin ${RAG_GIT_REPO}
git fetch --all
git checkout ${RAG_GIT_BRANCH} 2>/dev/null \
  || git checkout -b ${RAG_GIT_BRANCH} origin/${RAG_GIT_BRANCH}
git pull origin ${RAG_GIT_BRANCH}
echo \"HEAD: \$(git log --oneline -1)\"
cd ${RAG_FRAPPE_BENCH_DIR}
bench --site ${RAG_FRAPPE_SITE} migrate
bench restart || true
"
  run_remote_as_owner "restart rag-app after update" "
systemctl --user reset-failed rag-app 2>/dev/null || true
systemctl --user restart rag-app 2>/dev/null || true
sleep 5
systemctl --user status rag-app --no-pager || true
"
  success "RAG update complete"
  _deploy_log "RAG update complete"
}

if $RAG_STOP_ONLY;    then do_stop;    _deploy_log "=== Session end ==="; exit 0; fi
if $RAG_RESTART_ONLY; then do_restart; _deploy_log "=== Session end ==="; exit 0; fi
if $RAG_STATUS_ONLY;  then do_status;  _deploy_log "=== Session end ==="; exit 0; fi
if $RAG_UPDATE_ONLY;  then do_update;  _deploy_log "=== Session end ==="; exit 0; fi

if $RAG_CLEAN_SERVICES; then
  do_clean_services
  $RAG_CLEAN_ONLY && { _deploy_log "=== Session end ==="; exit 0; }
fi

if $RAG_CLEAN_BENCH || $RAG_CLEAN; then
  do_clean_bench
  $RAG_CLEAN_ONLY && { _deploy_log "=== Session end ==="; exit 0; }
fi

if step_enabled 1; then
  header "Step 1 — System packages"
  _deploy_log "Step 1: system packages"
  run_remote "apt install" "sudo bash --login -s" <<'ENDSSH'
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  build-essential curl git vim \
  virtualenv software-properties-common \
  postgresql-client redis-tools \
  supervisor \
  xvfb libfontconfig wkhtmltopdf \
  nginx fail2ban cron npm \
  2>&1 | tail -5

add-apt-repository ppa:deadsnakes/ppa -y 2>/dev/null || true
apt-get update -qq
apt-get install -y -qq \
  python3.10 python3.10-dev python3.10-venv python3.10-distutils \
  2>&1 | tail -3

apt-get clean
rm -rf /var/lib/apt/lists/*

pip3 install frappe-bench --break-system-packages -q
npm install -g yarn -q

echo "yarn: $(yarn --version)"
echo "frappe-bench: $(bench --version 2>/dev/null || pip3 show frappe-bench | grep Version)"
ENDSSH
  success "System packages installed"
  _deploy_log "Step 1 complete"
fi

if step_enabled 2; then
  header "Step 2 — frappe user + postgres"
  _deploy_log "Step 2: frappe user + postgres"
  run_remote_heredoc "Create frappe user and configure postgres" "
set +e

id ${RAG_FRAPPE_USER} &>/dev/null || useradd -ms /bin/bash ${RAG_FRAPPE_USER}
grep -q '${RAG_FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL' /etc/sudoers \
  || echo '${RAG_FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
chmod 755 /home/${RAG_FRAPPE_USER}
usermod -a -G ${RAG_FRAPPE_USER} www-data 2>/dev/null || true

echo 'Waiting for postgres on ${RAG_PG_HOST}:${RAG_PG_PORT}...'
for i in \$(seq 1 30); do
  PGPASSWORD='${RAG_POSTGRES_PASSWORD}' psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres -c 'SELECT 1' >/dev/null 2>&1 && break
  echo \"  not ready [\${i}/30]\"
  sleep 3
done

PGPASSWORD='${RAG_POSTGRES_PASSWORD}' psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
  -c \"ALTER USER postgres WITH SUPERUSER CREATEDB CREATEROLE PASSWORD '${RAG_POSTGRES_PASSWORD}';\"
PGPASSWORD='${RAG_POSTGRES_PASSWORD}' psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
  -d template1 -c 'GRANT ALL ON SCHEMA public TO PUBLIC;'
PGPASSWORD='${RAG_POSTGRES_PASSWORD}' psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
  -d template1 -c 'ALTER SCHEMA public OWNER TO postgres;'

echo 'frappe user and postgres ready'
id ${RAG_FRAPPE_USER}
"
  success "frappe user and postgres configured"
  _deploy_log "Step 2 complete"
fi

if step_enabled 3; then
  header "Step 3 — NVM + Node for frappe user"
  _deploy_log "Step 3: nvm + node"
  run_remote_as_frappe "Install NVM and Node" "
export HOME=/home/${RAG_FRAPPE_USER}
export NVM_DIR=\"\${HOME}/.nvm\"
if [[ ! -s \"\${NVM_DIR}/nvm.sh\" ]]; then
  curl -s https://raw.githubusercontent.com/creationix/nvm/master/install.sh | bash
fi
source \"\${NVM_DIR}/nvm.sh\"
nvm install ${RAG_NODE_VERSION}
nvm use ${RAG_NODE_VERSION}
nvm alias default ${RAG_NODE_VERSION}
node --version
npm --version
"
  success "NVM and Node ready"
  _deploy_log "Step 3 complete"
fi

if step_enabled 4; then
  header "Step 4 — Frappe bench init"
  _deploy_log "Step 4: bench init"
  run_remote_as_frappe "bench init" "
export HOME=/home/${RAG_FRAPPE_USER}

if [[ -d ${RAG_FRAPPE_BENCH_DIR} ]]; then
  echo 'bench dir exists — skipping init'
else
  bench init ${RAG_FRAPPE_BENCH_DIR} --frappe-branch ${RAG_FRAPPE_BRANCH} --python ${RAG_PYTHON_VERSION}
fi

cat > ${RAG_FRAPPE_BENCH_DIR}/sites/common_site_config.json << 'SITECFG'
{
  \"db_host\": \"${RAG_PG_HOST}\",
  \"db_port\": ${RAG_PG_PORT},
  \"redis_cache\": \"redis://127.0.0.1:${RAG_REDIS_CACHE_PORT}\",
  \"redis_queue\": \"redis://127.0.0.1:${RAG_REDIS_QUEUE_PORT}\",
  \"redis_socketio\": \"redis://127.0.0.1:${RAG_REDIS_QUEUE_PORT}\"
}
SITECFG

echo 'bench init done'
ls ${RAG_FRAPPE_BENCH_DIR}/apps/
"
  success "Frappe bench initialised"
  _deploy_log "Step 4 complete"
fi

if step_enabled 5; then
  header "Step 5 — Create Frappe site"
  _deploy_log "Step 5: new site"
  run_remote_as_frappe "bench new-site" "
export HOME=/home/${RAG_FRAPPE_USER}
cd ${RAG_FRAPPE_BENCH_DIR}

if [[ -d sites/${RAG_FRAPPE_SITE} ]]; then
  echo 'site already exists — skipping'
else
  bench new-site ${RAG_FRAPPE_SITE} \
    --db-type postgres \
    --db-root-username postgres \
    --db-root-password ${RAG_POSTGRES_PASSWORD} \
    --db-host ${RAG_PG_HOST} \
    --admin-password ${RAG_FRAPPE_ADMIN_PASSWORD}
fi

bench use ${RAG_FRAPPE_SITE}
bench --site ${RAG_FRAPPE_SITE} set-config db_host \"${RAG_PG_HOST}\"
bench --site ${RAG_FRAPPE_SITE} set-config db_port ${RAG_PG_PORT}
bench --site ${RAG_FRAPPE_SITE} set-config host_name \"http://${RAG_SERVER_HOST}\"
bench --site ${RAG_FRAPPE_SITE} set-config served_by nginx
echo 'site ready'
"
  success "Frappe site ready"
  _deploy_log "Step 5 complete"
fi

if step_enabled 6; then
  header "Step 6 — Install rag_service app"
  _deploy_log "Step 6: install rag_service"
  run_remote_as_frappe "get-app + install-app rag_service" "
export HOME=/home/${RAG_FRAPPE_USER}
cd ${RAG_FRAPPE_BENCH_DIR}

if [[ -d apps/rag_service ]]; then
  echo 'rag_service present — pulling latest'
  cd apps/rag_service
  git remote get-url origin >/dev/null 2>&1 || git remote add origin ${RAG_GIT_REPO}
  git remote set-url origin ${RAG_GIT_REPO}
  git fetch --all
  git checkout ${RAG_GIT_BRANCH} 2>/dev/null \
    || git checkout -b ${RAG_GIT_BRANCH} origin/${RAG_GIT_BRANCH}
  git pull origin ${RAG_GIT_BRANCH}
  echo \"HEAD: \$(git log --oneline -1)\"
  cd ${RAG_FRAPPE_BENCH_DIR}
else
  bench get-app ${RAG_GIT_REPO} --branch ${RAG_GIT_BRANCH}
  cd apps/rag_service
  git remote get-url origin >/dev/null 2>&1 || git remote add origin ${RAG_GIT_REPO}
  cd ${RAG_FRAPPE_BENCH_DIR}
fi

bench --site ${RAG_FRAPPE_SITE} install-app rag_service 2>/dev/null || echo 'already installed'
echo 'rag_service installed'
"
  success "rag_service app installed"
  _deploy_log "Step 6 complete"
fi

if step_enabled 7; then
  header "Step 7 — Install business_theme_v14"
  _deploy_log "Step 7: install business theme"
  run_remote_as_frappe "get-app + install-app business_theme_v14" "
export HOME=/home/${RAG_FRAPPE_USER}
cd ${RAG_FRAPPE_BENCH_DIR}

if [[ ! -d apps/business_theme_v14 ]]; then
  bench get-app https://github.com/Midocean-Technologies/business_theme_v14.git
fi

bench --site ${RAG_FRAPPE_SITE} install-app business_theme_v14 2>/dev/null || echo 'already installed'
echo 'business_theme_v14 installed'
"
  success "business_theme_v14 installed"
  _deploy_log "Step 7 complete"
fi

if step_enabled 8; then
  header "Step 8 — bench migrate + build"
  _deploy_log "Step 8: migrate and build"
  run_remote_as_frappe "bench migrate + build" "
export HOME=/home/${RAG_FRAPPE_USER}
cd ${RAG_FRAPPE_BENCH_DIR}
bench --site ${RAG_FRAPPE_SITE} migrate
bench build --force
echo 'migrate and build done'
"
  success "Migrations applied and assets built"
  _deploy_log "Step 8 complete"
fi

if step_enabled 9; then
  header "Step 9 — Supervisor + Nginx"
  _deploy_log "Step 9: supervisor and nginx"

  run_remote_as_frappe "bench setup supervisor" "
export HOME=/home/${RAG_FRAPPE_USER}
cd ${RAG_FRAPPE_BENCH_DIR}
bench setup supervisor --yes
echo 'supervisor config generated'
"

  _NGINX_SERVER_NAME="${RAG_DOMAIN_NAME:-${RAG_SERVER_HOST}}"
  $RAG_DEPLOY_DOMAIN && _NGINX_LISTEN="${RAG_NGINX_PORT:-80}" || _NGINX_LISTEN="${RAG_API_PORT:-8009}"

  run_remote_heredoc "Link configs and restart services" "
set +e

sed -i '/\[program:frappe-bench-redis/,/^\s*$/d' ${RAG_FRAPPE_BENCH_DIR}/config/supervisor.conf 2>/dev/null || true
sed -i '/\[group:frappe-bench-redis\]/,/^\s*$/d'  ${RAG_FRAPPE_BENCH_DIR}/config/supervisor.conf 2>/dev/null || true

ln -sf ${RAG_FRAPPE_BENCH_DIR}/config/supervisor.conf /etc/supervisor/conf.d/frappe-bench.conf

rm -f /etc/nginx/sites-enabled/default
rm -f /etc/nginx/conf.d/frappe-bench.conf

cat > /etc/nginx/conf.d/frappe-bench.conf << NGINXCFG
server {
    listen ${_NGINX_LISTEN};
    server_name ${_NGINX_SERVER_NAME};
    client_max_body_size ${RAG_NGINX_MAX_BODY_MB:-50}m;

    location /assets {
        alias ${RAG_FRAPPE_BENCH_DIR}/sites/assets;
        try_files \\\$uri \\\$uri/ =404;
    }

    location /files {
        alias ${RAG_FRAPPE_BENCH_DIR}/sites/${RAG_FRAPPE_SITE}/public/files;
        try_files \\\$uri \\\$uri/ =404;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host ${RAG_FRAPPE_SITE};
        proxy_set_header X-Real-IP \\\$remote_addr;
        proxy_set_header X-Forwarded-For \\\$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \\\$scheme;
        proxy_redirect off;
        proxy_read_timeout ${RAG_NGINX_PROXY_TIMEOUT:-60}s;
        proxy_connect_timeout ${RAG_NGINX_PROXY_TIMEOUT:-60}s;
    }
}
NGINXCFG

python3 - << 'DEDUP'
import pathlib
p = pathlib.Path('/etc/nginx/nginx.conf')
lines = p.read_text().splitlines()
seen = False
out = []
for line in lines:
    if 'log_format' in line and 'main' in line:
        if seen: continue
        seen = True
    out.append(line)
p.write_text('\n'.join(out) + '\n')
DEDUP

nginx -t && systemctl enable nginx && systemctl restart nginx
systemctl enable supervisor
supervisorctl reread
supervisorctl update

echo '=== Supervisor status ==='
supervisorctl status
"
  success "Supervisor and Nginx configured"
  _deploy_log "Step 9 complete"
fi

if step_enabled 10; then
  header "Step 10 — Verify infrastructure services"
  _deploy_log "Step 10: verify infrastructure"

  run_remote_heredoc "Wait for redis and postgres" "
set +e
echo 'Waiting for redis-cache on ${RAG_REDIS_CACHE_PORT}...'
for i in \$(seq 1 20); do
  redis-cli -h 127.0.0.1 -p ${RAG_REDIS_CACHE_PORT} ping 2>/dev/null | grep -q PONG && break
  echo \"  not ready [\${i}/20]\"; sleep 2
done
redis-cli -h 127.0.0.1 -p ${RAG_REDIS_CACHE_PORT} ping 2>/dev/null | grep -q PONG \
  && echo 'redis-cache: OK' || { echo 'redis-cache: FAILED'; exit 1; }

echo 'Waiting for redis-queue on ${RAG_REDIS_QUEUE_PORT}...'
for i in \$(seq 1 20); do
  redis-cli -h 127.0.0.1 -p ${RAG_REDIS_QUEUE_PORT} ping 2>/dev/null | grep -q PONG && break
  echo \"  not ready [\${i}/20]\"; sleep 2
done
redis-cli -h 127.0.0.1 -p ${RAG_REDIS_QUEUE_PORT} ping 2>/dev/null | grep -q PONG \
  && echo 'redis-queue: OK' || { echo 'redis-queue: FAILED'; exit 1; }

echo 'Waiting for postgres on ${RAG_PG_HOST}:${RAG_PG_PORT}...'
for i in \$(seq 1 20); do
  PGPASSWORD='${RAG_POSTGRES_PASSWORD}' psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres -c 'SELECT 1' >/dev/null 2>&1 && break
  echo \"  not ready [\${i}/20]\"; sleep 2
done
PGPASSWORD='${RAG_POSTGRES_PASSWORD}' psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres -c 'SELECT 1' >/dev/null 2>&1 \
  && echo 'postgres: OK' || { echo 'postgres: FAILED'; exit 1; }

echo 'All infrastructure services ready'
"
  success "Infrastructure services verified"
  _deploy_log "Step 10 complete"
fi

if step_enabled 11; then
  header "Step 11 — Install Python deps into frappe bench venv"
  _deploy_log "Step 11: python deps"

  run_remote_heredoc "Install rag deps into frappe venv" "
set +e
FRAPPE_PIP=${RAG_FRAPPE_BENCH_DIR}/env/bin/pip

echo 'Installing core runtime deps...'
sudo -u ${RAG_FRAPPE_USER} \${FRAPPE_PIP} install \
  pika \
  aiohttp \
  python-dotenv \
  -q 2>&1 | tail -3

echo 'Installing langchain stack (pinned)...'
sudo -u ${RAG_FRAPPE_USER} \${FRAPPE_PIP} install \
  'langchain==${RAG_LANGCHAIN_VERSION}' \
  'langchain-openai==${RAG_LANGCHAIN_OPENAI_VERSION}' \
  langchain-core \
  openai \
  tiktoken \
  -q 2>&1 | tail -3

if [[ -f ${RAG_FRAPPE_BENCH_DIR}/apps/rag_service/requirements.txt ]]; then
  echo 'Installing rag_service/requirements.txt...'
  sudo -u ${RAG_FRAPPE_USER} \${FRAPPE_PIP} install \
    -r ${RAG_FRAPPE_BENCH_DIR}/apps/rag_service/requirements.txt \
    -q 2>&1 | tail -3
fi

if [[ -f ${RAG_TAP_RAG_DIR}/requirements.txt ]]; then
  echo 'Installing tap_rag/requirements.txt...'
  sudo -u ${RAG_FRAPPE_USER} \${FRAPPE_PIP} install \
    -r ${RAG_TAP_RAG_DIR}/requirements.txt \
    -q 2>&1 | tail -3
fi

echo 'Verifying imports...'
sudo -u ${RAG_FRAPPE_USER} ${RAG_FRAPPE_BENCH_DIR}/env/bin/python3 -c \
  'import pika, aiohttp, langchain, langchain_openai, dotenv; print(\"All core imports OK\")'

echo 'Python deps complete'
"
  success "Python dependencies installed"
  _deploy_log "Step 11 complete"
fi

if step_enabled 12; then
  header "Step 12 — Patch langchain imports and consumer.py"
  _deploy_log "Step 12: apply code patches"

  run_remote_heredoc "Patch langchain.schema and rewrite consumer.py" "
set +e

echo 'Patching langchain.schema imports...'
for search_dir in \
  '${RAG_FRAPPE_BENCH_DIR}/apps/rag_service' \
  '${RAG_TAP_RAG_DIR}'; do
  if [[ -d \"\${search_dir}\" ]]; then
    find \"\${search_dir}\" -name '*.py' | xargs grep -l 'from langchain\.schema import' 2>/dev/null | while read f; do
      echo \"  Patching: \${f}\"
      sed -i \
        's/from langchain\.schema import HumanMessage, SystemMessage/from langchain_core.messages import HumanMessage, SystemMessage/g' \
        \"\${f}\"
      sed -i \
        's/from langchain\.schema import/from langchain_core.messages import/g' \
        \"\${f}\"
    done
    find \"\${search_dir}\" -name '*.py' | xargs grep -l 'from langchain\.schema\.messages import' 2>/dev/null | while read f; do
      echo \"  Patching messages: \${f}\"
      sed -i \
        's/from langchain\.schema\.messages import/from langchain_core.messages import/g' \
        \"\${f}\"
    done
  fi
done

echo 'Writing consumer.py...'
for consumer_path in \
  '${RAG_TAP_RAG_DIR}/rag_service/scripts/consumer.py' \
  '${RAG_FRAPPE_BENCH_DIR}/apps/rag_service/rag_service/scripts/consumer.py'; do
  if [[ -f \"\${consumer_path}\" ]]; then
    echo \"  Rewriting: \${consumer_path}\"
    cat > \"\${consumer_path}\" << 'CONSUMER'
import sys
import os

sys.path.insert(0, '${RAG_FRAPPE_BENCH_DIR}/apps/frappe')
sys.path.insert(0, '${RAG_FRAPPE_BENCH_DIR}/apps/rag_service')
sys.path.insert(0, '${RAG_TAP_RAG_DIR}')

import frappe
frappe.init(site='${RAG_FRAPPE_SITE}', sites_path='${RAG_FRAPPE_BENCH_DIR}/sites')
frappe.connect()

from rag_service.utils.rabbitmq_consumer import RabbitMQConsumer
consumer = RabbitMQConsumer(debug=True)
if consumer.test_connection():
    consumer.start_consuming()
CONSUMER
  fi
done

echo 'Patches applied'
"
  success "Code patches applied"
  _deploy_log "Step 12 complete"
fi

if step_enabled 13; then
  header "Step 13 — Create log directories with correct permissions"
  _deploy_log "Step 13: log dirs and permissions"

  run_remote_heredoc "Create and fix log directories" "
set +e

mkdir -p /home/${RAG_FRAPPE_USER}/logs
mkdir -p ${RAG_FRAPPE_BENCH_DIR}/logs
mkdir -p ${RAG_FRAPPE_BENCH_DIR}/${RAG_FRAPPE_SITE}/logs 2>/dev/null || true
mkdir -p ${RAG_FRAPPE_BENCH_DIR}/sites/${RAG_FRAPPE_SITE}/logs 2>/dev/null || true

chown ${RAG_FRAPPE_USER}:${RAG_FRAPPE_USER} /home/${RAG_FRAPPE_USER}/logs ${RAG_FRAPPE_BENCH_DIR}/logs 2>/dev/null || true
chmod 755 /home/${RAG_FRAPPE_USER}/logs ${RAG_FRAPPE_BENCH_DIR}/logs 2>/dev/null || true

chmod o+rx /home/${RAG_FRAPPE_USER} 2>/dev/null || true
chmod o+rx ${RAG_FRAPPE_BENCH_DIR} 2>/dev/null || true
chmod o+rx ${RAG_FRAPPE_BENCH_DIR}/sites 2>/dev/null || true
[[ -f ${RAG_FRAPPE_BENCH_DIR}/sites/${RAG_FRAPPE_SITE}/site_config.json ]] && \
  chmod o+r ${RAG_FRAPPE_BENCH_DIR}/sites/${RAG_FRAPPE_SITE}/site_config.json 2>/dev/null || true

echo 'Log dirs ready'
ls -la /home/${RAG_FRAPPE_USER}/logs ${RAG_FRAPPE_BENCH_DIR}/logs
"
  success "Log directories created and permissions set"
  _deploy_log "Step 13 complete"
fi

if step_enabled 14; then
  header "Step 14 — Configure rag-app systemd user service"
  _deploy_log "Step 14: rag-app service unit"

  _CONSUMER_BENCH="${RAG_FRAPPE_BENCH_DIR}/apps/rag_service/rag_service/scripts/consumer.py"
  _CONSUMER_LOCAL="${RAG_TAP_RAG_DIR}/rag_service/scripts/consumer.py"

  if ssh $SSH_OPTS "$TARGET" "test -f ${_CONSUMER_LOCAL}" 2>/dev/null; then
    _CONSUMER_PATH="${_CONSUMER_LOCAL}"
  else
    _CONSUMER_PATH="${_CONSUMER_BENCH}"
  fi

  run_remote_heredoc "Write rag-app.service unit file" "
set +e
SERVICE_DIR=/home/${RAG_SERVICE_OWNER}/.config/systemd/user
mkdir -p \"\${SERVICE_DIR}/default.target.wants\"

cat > \"\${SERVICE_DIR}/rag-app.service\" << UNIT
[Unit]
Description=RAG Worker
After=rag-postgres.service rag-rabbitmq.service network.target
Requires=rag-postgres.service rag-rabbitmq.service

[Service]
Type=simple
WorkingDirectory=${RAG_FRAPPE_BENCH_DIR}
Environment=PYTHONPATH=${RAG_TAP_RAG_DIR}:${RAG_FRAPPE_BENCH_DIR}/apps/frappe:${RAG_FRAPPE_BENCH_DIR}/apps/rag_service
EnvironmentFile=${RAG_TAP_RAG_DIR}/.env
ExecStart=${RAG_FRAPPE_BENCH_DIR}/env/bin/python3 ${_CONSUMER_PATH}
Restart=on-failure
RestartSec=15
StartLimitIntervalSec=120
StartLimitBurst=5

[Install]
WantedBy=default.target
UNIT

ln -sf \"\${SERVICE_DIR}/rag-app.service\" \"\${SERVICE_DIR}/default.target.wants/rag-app.service\" 2>/dev/null || true

chown -R ${RAG_SERVICE_OWNER}:${RAG_SERVICE_OWNER} \"\${SERVICE_DIR}\"
echo 'Service unit written:'
cat \"\${SERVICE_DIR}/rag-app.service\"
"

  run_remote_as_owner "reload and enable rag-app" "
systemctl --user daemon-reload
systemctl --user enable rag-app 2>/dev/null || true
systemctl --user reset-failed rag-app 2>/dev/null || true
systemctl --user restart rag-app
sleep 5
systemctl --user status rag-app --no-pager -l || true
"
  success "rag-app service configured"
  _deploy_log "Step 14 complete"
fi

if step_enabled 15; then
  header "Step 15 — Seed LLM and RabbitMQ Settings in Frappe DB"
  _deploy_log "Step 15: seed Frappe settings"

  run_remote_heredoc "Seed LLM and RabbitMQ settings via frappe API" "
set +e
mkdir -p /home/${RAG_FRAPPE_USER}/logs
chown ${RAG_FRAPPE_USER}:${RAG_FRAPPE_USER} /home/${RAG_FRAPPE_USER}/logs

sudo -u ${RAG_FRAPPE_USER} ${RAG_FRAPPE_BENCH_DIR}/env/bin/python3 - << 'PYEOF'
import sys
sys.path.insert(0, '${RAG_FRAPPE_BENCH_DIR}/apps/frappe')
sys.path.insert(0, '${RAG_FRAPPE_BENCH_DIR}/apps/rag_service')

import frappe
frappe.init(site='${RAG_FRAPPE_SITE}', sites_path='${RAG_FRAPPE_BENCH_DIR}/sites')
frappe.connect()

llm_active = frappe.get_all('LLM Settings', filters={'is_active': 1}, limit=1)
if llm_active:
    print('LLM Settings already active:', llm_active[0].name)
else:
    api_key = '${RAG_OPENAI_API_KEY}'
    if not api_key:
        print('WARNING: RAG_OPENAI_API_KEY not set in config.env')
        print('Go to the Frappe UI → LLM Settings → New to configure manually')
    else:
        try:
            doc = frappe.get_doc({
                'doctype': 'LLM Settings',
                'provider': '${RAG_LLM_PROVIDER}',
                'api_secret': api_key,
                'model_name': '${RAG_LLM_MODEL}',
                'temperature': float('${RAG_LLM_TEMPERATURE}'),
                'max_tokens': int('${RAG_LLM_MAX_TOKENS}'),
                'is_active': 1
            })
            doc.insert(ignore_permissions=True)
            frappe.db.commit()
            print('LLM Settings created:', doc.name)
        except Exception as e:
            print('LLM Settings note:', str(e))

rmq_existing = frappe.get_all('RabbitMQ Settings', limit=1)
if rmq_existing:
    print('RabbitMQ Settings already exist:', rmq_existing[0].name)
else:
    try:
        doc = frappe.get_doc({
            'doctype': 'RabbitMQ Settings',
            'host': '${RAG_RABBITMQ_HOST}',
            'port': int('${RAG_RABBITMQ_PORT}'),
            'username': '${RAG_RABBITMQ_USER}',
            'password': '${RAG_RABBITMQ_PASSWORD}',
            'virtual_host': '${RAG_RABBITMQ_VHOST}'
        })
        doc.insert(ignore_permissions=True)
        frappe.db.commit()
        print('RabbitMQ Settings created:', doc.name)
    except Exception as e:
        print('RabbitMQ Settings note:', str(e))

frappe.destroy()
PYEOF
echo 'Settings seed complete'
"
  success "Frappe settings seeded"
  _deploy_log "Step 15 complete"
fi

if step_enabled 16; then
  header "Step 16 — Final restart and health check"
  _deploy_log "Step 16: final restart and health check"

  run_remote_as_frappe "bench restart" "
export HOME=/home/${RAG_FRAPPE_USER}
cd ${RAG_FRAPPE_BENCH_DIR}
bench restart || true
"

  RAG_WAIT 10

  run_remote_as_owner "restart rag-app and verify" "
systemctl --user daemon-reload
systemctl --user reset-failed rag-app 2>/dev/null || true
systemctl --user restart rag-app
echo 'Waiting for rag-app to reach active state...'
_waited=0
for i in \$(seq 1 30); do
  _state=\$(systemctl --user is-active rag-app 2>/dev/null || echo unknown)
  if [[ \"\${_state}\" == 'active' ]]; then
    echo \"rag-app: active after \${_waited}s\"
    break
  fi
  if [[ \"\${_state}\" == 'failed' ]]; then
    journalctl --user -u rag-app -n 10 --no-pager 2>/dev/null || true
    systemctl --user reset-failed rag-app 2>/dev/null || true
    sleep 3
    systemctl --user start rag-app 2>/dev/null || true
  fi
  echo \"rag-app: \${_state} [\${i}/30]\"
  sleep 3
  _waited=\$(( _waited + 3 ))
done
_final=\$(systemctl --user is-active rag-app 2>/dev/null || echo unknown)
echo \"rag-app final state: \${_final}\"
[[ \"\${_final}\" != 'active' ]] && journalctl --user -u rag-app -n 30 --no-pager 2>/dev/null || true
"

  RAG_WAIT 5
  do_status
  success "Final health check complete"
  _deploy_log "Step 16 complete"
fi

if step_enabled 17; then
  if [[ "${RAG_OPEN_FIREWALL_PORT:-false}" == "true" ]]; then
    header "Step 17 — Firewall"
    _deploy_log "Step 17: open ports"

    $RAG_DEPLOY_DOMAIN && _FW_PORT="${RAG_NGINX_PORT:-80}" || _FW_PORT="${RAG_API_PORT:-8009}"

    run_remote_heredoc "Open firewall ports" "
set +e
if command -v ufw &>/dev/null; then
  ufw allow ${_FW_PORT}/tcp 2>/dev/null || true
  echo 'ufw: opened ${_FW_PORT}'
elif command -v firewall-cmd &>/dev/null; then
  firewall-cmd --permanent --add-port=${_FW_PORT}/tcp 2>/dev/null || true
  firewall-cmd --reload 2>/dev/null || true
  echo 'firewalld: opened ${_FW_PORT}'
else
  echo 'no local firewall found — configure cloud NSG manually'
fi
"
    warn "Also open port ${_FW_PORT} in your cloud NSG / security group."
    _deploy_log "Step 17 complete"
  else
    info "Step 17 — Skipping firewall (RAG_OPEN_FIREWALL_PORT=false)"
    _deploy_log "Step 17: skipped"
  fi
fi

echo ""
success "RAG deployment complete"
info "URL:      $(_effective_url)"
info "Login:    Administrator / ${RAG_FRAPPE_ADMIN_PASSWORD}"
info "Next:     Open the URL → LLM Settings (add API key + set active)"
info "          → RabbitMQ Settings (verify) → Prompt Template (set active)"
_deploy_log "=== RAG Deployment complete ==="
_appid_log  "=== RAG Deployment complete ==="
echo ""