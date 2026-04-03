#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
info()    { echo -e "${DIM}${CYAN}  ›${RESET} $*"; }
success() { echo -e "${GREEN}  ✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${RESET}  $*"; }
error()   { echo -e "${RED}  ✗${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}  ══  $*  ══${RESET}"; }

LMS_CONFIG_FILE="${LMS_CONFIG_FILE:-./tap-devops/config.env}"
LMS_DRY_RUN="${LMS_DRY_RUN:-false}"
LMS_STEPS="${LMS_STEPS:-}"
LMS_CLEAN="${LMS_CLEAN:-false}"
LMS_CLEAN_ONLY="${LMS_CLEAN_ONLY:-false}"
LMS_RESTART_ONLY="${LMS_RESTART_ONLY:-false}"
LMS_STOP_ONLY="${LMS_STOP_ONLY:-false}"
LMS_STATUS_ONLY="${LMS_STATUS_ONLY:-false}"
LMS_UPDATE_ONLY="${LMS_UPDATE_ONLY:-false}"
LMS_UPDATE_CONFIG="${LMS_UPDATE_CONFIG:-false}"
LMS_CLEAN_SERVICES="${LMS_CLEAN_SERVICES:-false}"
LMS_CLEAN_BENCH="${LMS_CLEAN_BENCH:-false}"
LMS_FORCE="${LMS_FORCE:-false}"
LMS_VERBOSE="${LMS_VERBOSE:-false}"
LMS_NO_WAIT="${LMS_NO_WAIT:-false}"
LMS_DEPLOY_DOMAIN="${LMS_DEPLOY_DOMAIN:-false}"
LMS_TLS_CERT="${LMS_TLS_CERT:-}"
LMS_TLS_KEY="${LMS_TLS_KEY:-}"
LMS_ENABLE_HTTPS="${LMS_ENABLE_HTTPS:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)           LMS_CONFIG_FILE="$2"; shift 2 ;;
    --dry-run)          LMS_DRY_RUN=true; shift ;;
    --steps)            LMS_STEPS="$2"; shift 2 ;;
    --clean)            LMS_CLEAN=true; LMS_FORCE=true; shift ;;
    --clean-only)       LMS_CLEAN=true; LMS_CLEAN_ONLY=true; LMS_FORCE=true; shift ;;
    --restart)          LMS_RESTART_ONLY=true; shift ;;
    --stop)             LMS_STOP_ONLY=true; shift ;;
    --status)           LMS_STATUS_ONLY=true; shift ;;
    --update)           LMS_UPDATE_ONLY=true; shift ;;
    --update-config)    LMS_UPDATE_CONFIG=true; shift ;;
    --clean-services)   LMS_CLEAN_SERVICES=true; shift ;;
    --clean-bench)      LMS_CLEAN_BENCH=true; LMS_FORCE=true; shift ;;
    --force)            LMS_FORCE=true; shift ;;
    --verbose)          LMS_VERBOSE=true; shift ;;
    --no-wait)          LMS_NO_WAIT=true; shift ;;
    --deploy-to-domain) LMS_DEPLOY_DOMAIN=true; shift ;;
    --enable-https)     LMS_ENABLE_HTTPS=true; shift ;;
    --help)
      cat <<'HELP'
Usage: setup-lms.sh [--config FILE] [OPTIONS]

Deployment modes:
  (no flags)          Full fresh deploy (steps 1-16)
  --update            git pull + bench migrate + restart
  --update-config     Sync Python deps, site config, and DB settings then restart
  --restart           Restart all LMS services
  --stop              Stop all LMS services
  --status            Show full health status
  --clean             Deep wipe then redeploy
  --clean-only        Deep wipe and exit
  --clean-services    Stop containers, volumes, and supervisor config for this bench
  --clean-bench       Wipe bench dir + site DB only

Step control:
  --steps N           Run only step N
  --steps N-M         Run steps N through M
  --steps N,M,X-Y     Comma-separated list/ranges

Options:
  --config FILE       Path to lms-config.env
  --dry-run           Print SSH commands without executing
  --force             Skip confirmation prompts
  --verbose           Enable set -x on remote scripts
  --no-wait           Skip sleep delays
  --deploy-to-domain  Serve via nginx on LMS_NGINX_PORT using LMS_DOMAIN_NAME
  --enable-https      Configure HTTPS

Required config vars:
  LMS_SERVER_USER  LMS_SERVER_HOST  LMS_SSH_KEY_PATH
  LMS_GIT_REPO  LMS_GIT_BRANCH
  LMS_POSTGRES_PASSWORD
  LMS_FRAPPE_BENCH_DIR  LMS_FRAPPE_SITE  LMS_FRAPPE_USER  LMS_FRAPPE_ADMIN_PASSWORD
  LMS_DEPLOY_SECRET_KEY
HELP
      exit 0 ;;
    *) die "Unknown argument: $1. Use --help for usage." ;;
  esac
done

[[ -f "$LMS_CONFIG_FILE" ]] || die "Config file not found: $LMS_CONFIG_FILE"
source "$LMS_CONFIG_FILE"
success "Loaded config: $LMS_CONFIG_FILE"

LMS_LOG_DIR="${LMS_LOG_DIR:-./tap-devops/logs}"
LMS_LOG_MAX_MB="${LMS_LOG_MAX_MB:-10}"
LMS_LOG_BACKUP_COUNT="${LMS_LOG_BACKUP_COUNT:-5}"
LMS_SSH_PORT="${LMS_SSH_PORT:-22}"
LMS_PG_HOST="${LMS_PG_HOST:-127.0.0.1}"
LMS_PG_PORT="${LMS_PG_PORT:-5437}"
LMS_PYTHON_VERSION="${LMS_PYTHON_VERSION:-python3.11}"
LMS_FRAPPE_BRANCH="${LMS_FRAPPE_BRANCH:-version-14}"
LMS_BUSINESS_THEME_BRANCH="${LMS_BUSINESS_THEME_BRANCH:-main}"
LMS_NODE_VERSION="${LMS_NODE_VERSION:-16.15.0}"
LMS_REDIS_CACHE_PORT="${LMS_REDIS_CACHE_PORT:-13200}"
LMS_REDIS_QUEUE_PORT="${LMS_REDIS_QUEUE_PORT:-11200}"
LMS_REDIS_SOCKETIO_PORT="${LMS_REDIS_SOCKETIO_PORT:-9003}"
LMS_REDIS_MAXMEMORY="${LMS_REDIS_MAXMEMORY:-256mb}"
LMS_REDIS_MAXMEMORY_POLICY="${LMS_REDIS_MAXMEMORY_POLICY:-allkeys-lru}"
LMS_GUNICORN_PORT="${LMS_GUNICORN_PORT:-8003}"
LMS_SOCKETIO_PORT="${LMS_SOCKETIO_PORT:-9003}"
LMS_WEB_PORT="${LMS_WEB_PORT:-8081}"
LMS_NGINX_PORT="${LMS_NGINX_PORT:-80}"
LMS_NGINX_HTTPS_PORT="${LMS_NGINX_HTTPS_PORT:-443}"
LMS_NGINX_MAX_BODY_MB="${LMS_NGINX_MAX_BODY_MB:-50}"
LMS_NGINX_PROXY_TIMEOUT="${LMS_NGINX_PROXY_TIMEOUT:-120}"
LMS_DOMAIN_NAME="${LMS_DOMAIN_NAME:-}"
LMS_OPEN_FIREWALL_PORT="${LMS_OPEN_FIREWALL_PORT:-false}"
LMS_SERVICE_OWNER="${LMS_SERVICE_OWNER:-${LMS_SERVER_USER}}"
LMS_FRAPPE_SHORT_WORKERS="${LMS_FRAPPE_SHORT_WORKERS:-1}"
LMS_FRAPPE_LONG_WORKERS="${LMS_FRAPPE_LONG_WORKERS:-1}"
LMS_NVM_INSTALL_URL="${LMS_NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh}"
LMS_BUSINESS_THEME_REPO="${LMS_BUSINESS_THEME_REPO:-https://github.com/Midocean-Technologies/business_theme_v14.git}"
LMS_TLS_CERT="${LMS_TLS_CERT:-/etc/ssl/lms/lms.crt}"
LMS_TLS_KEY="${LMS_TLS_KEY:-/etc/ssl/lms/lms.key}"
LMS_POSTGRES_IMAGE="${LMS_POSTGRES_IMAGE:-docker.io/library/postgres:15-alpine}"
LMS_REDIS_IMAGE="${LMS_REDIS_IMAGE:-docker.io/library/redis:7-alpine}"

REQUIRED_VARS=(
  LMS_SERVER_USER LMS_SERVER_HOST LMS_SSH_KEY_PATH
  LMS_GIT_REPO LMS_GIT_BRANCH
  LMS_POSTGRES_PASSWORD
  LMS_FRAPPE_BENCH_DIR LMS_FRAPPE_SITE LMS_FRAPPE_USER LMS_FRAPPE_ADMIN_PASSWORD
  LMS_DEPLOY_SECRET_KEY
)
for v in "${REQUIRED_VARS[@]}"; do
  [[ -n "${!v:-}" ]] || die "Required config var \$$v not set in $LMS_CONFIG_FILE"
done

_BENCH_ID=$(basename "${LMS_FRAPPE_BENCH_DIR}")

LMS_POSTGRES_CONTAINER="${LMS_POSTGRES_CONTAINER:-lms-${_BENCH_ID}-postgres}"
LMS_REDIS_CACHE_CONTAINER="${LMS_REDIS_CACHE_CONTAINER:-lms-${_BENCH_ID}-redis-cache}"
LMS_REDIS_QUEUE_CONTAINER="${LMS_REDIS_QUEUE_CONTAINER:-lms-${_BENCH_ID}-redis-queue}"

_SUPERVISOR_CONF_NAME="lms-bench-${_BENCH_ID}"
_NGINX_CONF_NAME="lms-bench-${_BENCH_ID}"
_SERVICE_NAME="lms-app-${_BENCH_ID}"
_WRAPPER_SCRIPT="/usr/local/bin/lms-app-${_BENCH_ID}"
_SYSTEMD_UNIT="/etc/systemd/system/${_SERVICE_NAME}.service"

_SITES_DIR="${LMS_FRAPPE_BENCH_DIR}/sites"
_SITE_DIR="${_SITES_DIR}/${LMS_FRAPPE_SITE}"
_SITE_LOGS_DIR="${_SITE_DIR}/logs"
_BENCH_LOGS_DIR="${LMS_FRAPPE_BENCH_DIR}/logs"
_SITE_LOGS_ALT="${LMS_FRAPPE_BENCH_DIR}/${LMS_FRAPPE_SITE}/logs"

if $LMS_DEPLOY_DOMAIN; then
  [[ -n "${LMS_DOMAIN_NAME:-}" ]] || die "--deploy-to-domain requires LMS_DOMAIN_NAME"
fi
if $LMS_ENABLE_HTTPS && ! $LMS_DEPLOY_DOMAIN; then
  [[ -n "${LMS_DOMAIN_NAME:-}" ]] || die "--enable-https requires LMS_DOMAIN_NAME"
  LMS_DEPLOY_DOMAIN=true
fi

mkdir -p "${LMS_LOG_DIR}"

_rotate_log() {
  local logfile="$1"
  local max_bytes=$(( LMS_LOG_MAX_MB * 1024 * 1024 ))
  local actual_size=0
  [[ -f "$logfile" ]] && actual_size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
  if (( actual_size >= max_bytes )); then
    local i
    for (( i=LMS_LOG_BACKUP_COUNT-1; i>=1; i-- )); do
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

LMS_DEPLOY_LOG="${LMS_LOG_DIR}/lms-deploy-${_BENCH_ID}.log"
_deploy_log() { _log_to_file "$LMS_DEPLOY_LOG" "$*"; }
_tee_deploy_log() {
  while IFS= read -r line; do
    echo "$line"
    _log_to_file "$LMS_DEPLOY_LOG" "$line"
  done
}

SSH_CTRL_PATH="/tmp/lms-ssh-${_BENCH_ID}-${LMS_SERVER_USER}@${LMS_SERVER_HOST}:${LMS_SSH_PORT}"
_SC="${LMS_SSH_ACCEPT_NEW:-false}"
_STRICT_OPT="StrictHostKeyChecking=yes"
$_SC && _STRICT_OPT="StrictHostKeyChecking=accept-new"

SSH_BASE_OPTS="-i ${LMS_SSH_KEY_PATH} -p ${LMS_SSH_PORT} \
  -o ${_STRICT_OPT} \
  -o ConnectTimeout=15 \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=10 \
  -o ControlMaster=auto \
  -o ControlPath=${SSH_CTRL_PATH} \
  -o ControlPersist=120"
SCP_OPTS="-i ${LMS_SSH_KEY_PATH} -P ${LMS_SSH_PORT} \
  -o ${_STRICT_OPT} \
  -o ConnectTimeout=15 \
  -o ControlMaster=auto \
  -o ControlPath=${SSH_CTRL_PATH} \
  -o ControlPersist=120"
TARGET="${LMS_SERVER_USER}@${LMS_SERVER_HOST}"

_ssh_master_up() {
  ssh ${SSH_BASE_OPTS} -O check "$TARGET" 2>/dev/null && return 0
  ssh ${SSH_BASE_OPTS} -fN "$TARGET" 2>/dev/null || true
  sleep 1
}

_effective_url() {
  if $LMS_ENABLE_HTTPS; then
    echo "https://${LMS_DOMAIN_NAME}/"
  elif $LMS_DEPLOY_DOMAIN; then
    echo "http://${LMS_DOMAIN_NAME}/"
  else
    echo "http://${LMS_SERVER_HOST}:${LMS_WEB_PORT}/"
  fi
}

_nginx_http_listen() {
  $LMS_DEPLOY_DOMAIN && echo "${LMS_NGINX_PORT}" || echo "${LMS_WEB_PORT}"
}

_nginx_server_name() {
  $LMS_DEPLOY_DOMAIN && echo "${LMS_DOMAIN_NAME}" || echo "_"
}

step_enabled() {
  local n="$1"
  [[ -z "$LMS_STEPS" ]] && return 0
  local token lo hi
  local IFS=','
  read -ra _tokens <<< "$LMS_STEPS"
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

LMS_WAIT() { $LMS_NO_WAIT && return 0; sleep "$1"; }

run_remote() {
  local desc="$1"; shift
  info "Remote: $desc"
  _deploy_log "Remote: $desc"
  if $LMS_DRY_RUN; then echo -e "  ${YELLOW}$ $*${RESET}"; return 0; fi
  ssh ${SSH_BASE_OPTS} "$TARGET" "$@" 2>&1 | _tee_deploy_log
}

run_remote_heredoc() {
  local desc="$1" body="$2"
  info "Remote: $desc"
  _deploy_log "Remote: $desc"
  if $LMS_DRY_RUN; then echo -e "  ${YELLOW}[heredoc: $desc]${RESET}"; return 0; fi
  local flags="set -euo pipefail"
  $LMS_VERBOSE && flags="${flags}; set -x"
  ssh ${SSH_BASE_OPTS} "$TARGET" "sudo bash --login -s" 2>&1 <<EOF | _tee_deploy_log
${flags}
${body}
EOF
}

run_remote_as_frappe() {
  local desc="$1" body="$2"
  info "Remote (${LMS_FRAPPE_USER}): $desc"
  _deploy_log "Remote (${LMS_FRAPPE_USER}): $desc"
  if $LMS_DRY_RUN; then echo -e "  ${YELLOW}[frappe heredoc: $desc]${RESET}"; return 0; fi
  local preamble="
export HOME=/home/${LMS_FRAPPE_USER}
export NVM_DIR=\"/home/${LMS_FRAPPE_USER}/.nvm\"
[[ -s \"\${NVM_DIR}/nvm.sh\" ]] && source \"\${NVM_DIR}/nvm.sh\"
nvm use ${LMS_NODE_VERSION} 2>/dev/null || true
export PATH=\"\${HOME}/.local/bin:\${HOME}/.nvm/versions/node/v${LMS_NODE_VERSION}/bin:\${PATH}\"
hash -r 2>/dev/null || true
cd ${LMS_FRAPPE_BENCH_DIR} 2>/dev/null || cd \${HOME}
"
  local flags="set -euo pipefail"
  $LMS_VERBOSE && flags="${flags}; set -x"
  ssh ${SSH_BASE_OPTS} "$TARGET" "sudo -H -u ${LMS_FRAPPE_USER} bash --login -s" 2>&1 <<EOF | _tee_deploy_log
${preamble}
${flags}
${body}
EOF
}

run_remote_as_owner() {
  local desc="$1" body="$2"
  info "Remote (${LMS_SERVICE_OWNER}): $desc"
  _deploy_log "Remote (${LMS_SERVICE_OWNER}): $desc"
  if $LMS_DRY_RUN; then echo -e "  ${YELLOW}[owner heredoc: $desc]${RESET}"; return 0; fi
  local preamble="
export HOME=/home/${LMS_SERVICE_OWNER}
_uid=\$(id -u)
export XDG_RUNTIME_DIR=/run/user/\${_uid}
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${_uid}/bus
loginctl enable-linger \$(whoami) 2>/dev/null || true
"
  local flags="set -euo pipefail"
  $LMS_VERBOSE && flags="${flags}; set -x"
  ssh ${SSH_BASE_OPTS} "$TARGET" "sudo -H -u ${LMS_SERVICE_OWNER} bash --login -s" 2>&1 <<EOF | _tee_deploy_log
${preamble}
${flags}
${body}
EOF
}

_ensure_all_log_dirs() {
  run_remote_heredoc "Ensure all site log directories exist [${_BENCH_ID}]" "
set +e
for _d in \
  '/home/${LMS_FRAPPE_USER}/logs' \
  '${_BENCH_LOGS_DIR}' \
  '${_SITES_DIR}/logs' \
  '${_SITE_LOGS_DIR}' \
  '${_SITE_LOGS_ALT}'; do
  mkdir -p \"\${_d}\"
  chown -R ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} \"\${_d}\" 2>/dev/null || true
  chmod 755 \"\${_d}\"
done
chmod o+rx '/home/${LMS_FRAPPE_USER}' 2>/dev/null || true
chmod o+rx '${LMS_FRAPPE_BENCH_DIR}' 2>/dev/null || true
chmod o+rx '${_SITES_DIR}' 2>/dev/null || true
[[ -f '${_SITE_DIR}/site_config.json' ]] \
  && chmod o+r '${_SITE_DIR}/site_config.json' 2>/dev/null || true
echo 'All log dirs ensured'
"
}

_write_pgpass_remote() {
  run_remote_heredoc "Write .pgpass for all postgres users [${_BENCH_ID}]" "
set +e

PGLINE_SU='${LMS_PG_HOST}:${LMS_PG_PORT}:*:postgres:${LMS_POSTGRES_PASSWORD}'

_write_pgpass_for_user() {
  local home_dir=\"\$1\"
  local owner=\"\$2\"
  local pgpass=\"\${home_dir}/.pgpass\"

  echo \"\${PGLINE_SU}\" > \"\${pgpass}\"

  if [[ -f '${_SITE_DIR}/site_config.json' ]]; then
    _db_name=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_name',''))\" 2>/dev/null || true)
    _db_pass=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_password',''))\" 2>/dev/null || true)
    if [[ -n \"\${_db_name}\" && -n \"\${_db_pass}\" ]]; then
      echo '${LMS_PG_HOST}:${LMS_PG_PORT}:*:'\"\${_db_name}\"':'\"\${_db_pass}\" >> \"\${pgpass}\"
      echo \"Added site DB entry for \${_db_name} to \${pgpass}\"
    fi
  fi

  chown \"\${owner}\":\"\${owner}\" \"\${pgpass}\"
  chmod 600 \"\${pgpass}\"
  echo \"Written: \${pgpass}\"
}

_write_pgpass_for_user '/root'                      'root'
_write_pgpass_for_user '/home/${LMS_FRAPPE_USER}'   '${LMS_FRAPPE_USER}'

if [[ '${LMS_SERVICE_OWNER}' != '${LMS_FRAPPE_USER}' ]]; then
  _write_pgpass_for_user '/home/${LMS_SERVICE_OWNER}' '${LMS_SERVICE_OWNER}'
fi
echo '.pgpass update complete'
"
}

_restart_lms_app_with_diagnostics() {
  run_remote_heredoc "Restart and verify ${_SERVICE_NAME}" "
set +u
systemctl reset-failed ${_SERVICE_NAME} 2>/dev/null || true
systemctl restart ${_SERVICE_NAME}

echo 'Waiting up to 30s for ${_SERVICE_NAME} to reach active state...'
waited=0
i=0
while [[ \${i} -lt 10 ]]; do
  i=\$(( i + 1 ))
  state=\$(systemctl is-active ${_SERVICE_NAME} 2>/dev/null || echo unknown)
  if [[ \"\${state}\" == 'active' ]]; then
    echo \"lms-app: active after \${waited}s\"
    break
  fi
  if [[ \"\${state}\" == 'failed' ]]; then
    systemctl reset-failed ${_SERVICE_NAME} 2>/dev/null || true
    sleep 3
    systemctl start ${_SERVICE_NAME} 2>/dev/null || true
  fi
  echo \"lms-app: \${state} [\${i}/10]\"
  sleep 3
  waited=\$(( waited + 3 ))
done

echo 'Waiting 15s grace period to detect post-start crashes...'
sleep 15

final=\$(systemctl is-active ${_SERVICE_NAME} 2>/dev/null || echo unknown)
echo \"lms-app final state: \${final}\"
systemctl status ${_SERVICE_NAME} --no-pager -l || true
echo '--- Last 80 journal lines ---'
journalctl -u ${_SERVICE_NAME} -n 80 --no-pager 2>/dev/null || true
"
}

_ensure_tls_cert() {
  run_remote_heredoc "Ensure TLS certificate exists [${_BENCH_ID}]" "
set +e
mkdir -p /etc/ssl/lms
chmod 700 /etc/ssl/lms

if [[ -f '${LMS_TLS_CERT}' && -f '${LMS_TLS_KEY}' ]]; then
  echo 'Existing TLS cert/key found — skipping generation'
  openssl x509 -in '${LMS_TLS_CERT}' -noout -dates 2>/dev/null || true
else
  echo 'Generating self-signed certificate for ${LMS_DOMAIN_NAME:-${LMS_SERVER_HOST}}'
  openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
    -keyout '${LMS_TLS_KEY}' \
    -out '${LMS_TLS_CERT}' \
    -subj '/CN=${LMS_DOMAIN_NAME:-${LMS_SERVER_HOST}}/O=LMS/C=US' \
    -addext 'subjectAltName=DNS:${LMS_DOMAIN_NAME:-${LMS_SERVER_HOST}},IP:${LMS_SERVER_HOST}' \
    2>/dev/null
  chmod 600 '${LMS_TLS_KEY}'
  chmod 644 '${LMS_TLS_CERT}'
  echo 'Self-signed TLS cert generated (valid 10 years)'
fi
"
}

_build_nginx_conf() {
  local listen_http
  listen_http="$(_nginx_http_listen)"
  local server_name
  server_name="$(_nginx_server_name)"

  if $LMS_ENABLE_HTTPS; then
    cat <<NGINXCFG
server {
    listen ${listen_http};
    server_name ${server_name};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${LMS_NGINX_HTTPS_PORT} ssl;
    server_name ${server_name};
    client_max_body_size ${LMS_NGINX_MAX_BODY_MB}m;

    ssl_certificate     ${LMS_TLS_CERT};
    ssl_certificate_key ${LMS_TLS_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:LMS_SSL:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;

    location /assets {
        alias ${LMS_FRAPPE_BENCH_DIR}/sites/assets;
        try_files \$uri \$uri/ =404;
        expires 1d;
        add_header Cache-Control 'public';
    }

    location /files {
        alias ${_SITE_DIR}/public/files;
        try_files \$uri \$uri/ =404;
    }

    location /socket.io {
        proxy_pass http://127.0.0.1:${LMS_SOCKETIO_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host ${LMS_FRAPPE_SITE};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / {
        proxy_pass http://127.0.0.1:${LMS_GUNICORN_PORT};
        proxy_set_header Host ${LMS_FRAPPE_SITE};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Frappe-Site-Name ${LMS_FRAPPE_SITE};
        proxy_redirect off;
        proxy_read_timeout ${LMS_NGINX_PROXY_TIMEOUT}s;
        proxy_connect_timeout ${LMS_NGINX_PROXY_TIMEOUT}s;
        proxy_buffering on;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
    }
}
NGINXCFG
  else
    cat <<NGINXCFG
server {
    listen ${listen_http};
    server_name ${server_name};
    client_max_body_size ${LMS_NGINX_MAX_BODY_MB}m;

    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;

    location /assets {
        alias ${LMS_FRAPPE_BENCH_DIR}/sites/assets;
        try_files \$uri \$uri/ =404;
        expires 1d;
        add_header Cache-Control 'public';
    }

    location /files {
        alias ${_SITE_DIR}/public/files;
        try_files \$uri \$uri/ =404;
    }

    location /socket.io {
        proxy_pass http://127.0.0.1:${LMS_SOCKETIO_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host ${LMS_FRAPPE_SITE};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:${LMS_GUNICORN_PORT};
        proxy_set_header Host ${LMS_FRAPPE_SITE};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Frappe-Site-Name ${LMS_FRAPPE_SITE};
        proxy_redirect off;
        proxy_read_timeout ${LMS_NGINX_PROXY_TIMEOUT}s;
        proxy_connect_timeout ${LMS_NGINX_PROXY_TIMEOUT}s;
        proxy_buffering on;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
    }
}
NGINXCFG
  fi
}

do_stop() {
  header "Stop LMS [${_BENCH_ID}]"
  _deploy_log "Action: stop"
  run_remote_heredoc "Stop bench supervisor processes [${_BENCH_ID}]" "
set +e
supervisorctl stop '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl stop '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
echo 'bench processes stopped'
"
  run_remote_heredoc "Stop lms-app system service [${_BENCH_ID}]" "
set +e
systemctl stop ${_SERVICE_NAME} 2>/dev/null || true
echo 'lms-app stopped'
"
  success "LMS stopped [${_BENCH_ID}]"
  _deploy_log "LMS stopped"
}

do_restart() {
  header "Restart LMS [${_BENCH_ID}]"
  _deploy_log "Action: restart"
  run_remote_heredoc "Restart bench supervisor processes [${_BENCH_ID}]" "
set +e
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5
supervisorctl status 2>/dev/null || true
"
  _restart_lms_app_with_diagnostics
  success "LMS restarted [${_BENCH_ID}]"
  _deploy_log "LMS restarted"
}

do_status() {
  header "LMS Health Check [${_BENCH_ID}]"
  _deploy_log "Action: status"

  _status_listen_port="$(_nginx_http_listen)"
  $LMS_ENABLE_HTTPS && _status_listen_port="${LMS_NGINX_HTTPS_PORT}"

  local _podman_ps_fmt='table {{.Names}}\t{{.Status}}\t{{.Image}}'
  local _enable_https="${LMS_ENABLE_HTTPS}"
  local _https_port="${LMS_NGINX_HTTPS_PORT}"
  local _listen_port="${_status_listen_port}"

  run_remote_heredoc "Full LMS status [${_BENCH_ID}]" "
set +e
echo '=== Supervisor processes ==='
supervisorctl status 2>/dev/null | grep -E '${_SUPERVISOR_CONF_NAME}|^\$' || echo 'supervisor not running'

echo ''
echo '=== System services ==='
for svc in nginx supervisor; do
  printf '  %-20s %s\n' \"\${svc}\" \"\$(systemctl is-active \${svc} 2>/dev/null || echo inactive)\"
done

echo ''
echo '=== Podman containers [${_BENCH_ID}] ==='
sudo -u ${LMS_SERVICE_OWNER} podman ps \
  --format '${_podman_ps_fmt}' 2>/dev/null \
  | grep -E '${_BENCH_ID}|^NAMES' || echo 'no matching containers found'

echo ''
echo '=== Redis [${_BENCH_ID}] ==='
redis-cli -h 127.0.0.1 -p ${LMS_REDIS_CACHE_PORT} ping 2>/dev/null | grep -q PONG \
  && echo 'redis-cache (${LMS_REDIS_CACHE_PORT}): OK' \
  || echo 'redis-cache (${LMS_REDIS_CACHE_PORT}): NOT RESPONDING'
redis-cli -h 127.0.0.1 -p ${LMS_REDIS_QUEUE_PORT} ping 2>/dev/null | grep -q PONG \
  && echo 'redis-queue (${LMS_REDIS_QUEUE_PORT}): OK' \
  || echo 'redis-queue (${LMS_REDIS_QUEUE_PORT}): NOT RESPONDING'

echo ''
echo '=== Postgres [${_BENCH_ID}] ==='
psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
  -c 'SELECT 1' >/dev/null 2>&1 \
  && echo 'postgres (${LMS_PG_HOST}:${LMS_PG_PORT}): OK' \
  || echo 'postgres (${LMS_PG_HOST}:${LMS_PG_PORT}): NOT RESPONDING'

echo ''
echo '=== Site DB user connectivity ==='
if [[ -f '${_SITE_DIR}/site_config.json' ]]; then
  _db_name=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_name',''))\" 2>/dev/null || true)
  _db_pass=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_password',''))\" 2>/dev/null || true)
  PGPASSWORD=\"\${_db_pass}\" psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} \
    -U \"\${_db_name}\" -d \"\${_db_name}\" -c 'SELECT 1' >/dev/null 2>&1 \
    && echo \"site DB user (\${_db_name}): OK\" \
    || echo \"site DB user (\${_db_name}): FAILED — run --update-config to fix\"
fi

echo ''
echo '=== Frappe gunicorn HTTP [${_BENCH_ID}] ==='
curl -sf --max-time 10 \
  -H 'Host: ${LMS_FRAPPE_SITE}' \
  -H 'X-Frappe-Site-Name: ${LMS_FRAPPE_SITE}' \
  http://127.0.0.1:${LMS_GUNICORN_PORT} -o /dev/null \
  && echo 'gunicorn HTTP (${LMS_GUNICORN_PORT}): OK' \
  || echo 'gunicorn HTTP (${LMS_GUNICORN_PORT}): not responding'

echo ''
echo '=== External endpoint [${_BENCH_ID}] ==='
if ${_enable_https}; then
  curl -sf -k --max-time 10 https://127.0.0.1:${_https_port} -o /dev/null \
    && echo 'HTTPS endpoint (${_https_port}): OK' \
    || echo 'HTTPS endpoint (${_https_port}): not responding'
else
  curl -sf --max-time 10 http://127.0.0.1:${_listen_port} -o /dev/null \
    && echo 'HTTP endpoint (${_listen_port}): OK' \
    || echo 'HTTP endpoint (${_listen_port}): not responding'
fi

echo ''
echo '=== lms-app service [${_BENCH_ID}] ==='
systemctl status ${_SERVICE_NAME} --no-pager -l 2>/dev/null || echo 'lms-app service not found or not running'

echo ''
echo '=== Disk ==='
df -h /
"
}

do_clean_services() {
  header "Clean: supervisor, containers, and volumes for bench ${_BENCH_ID}"
  _deploy_log "Action: clean-services"

  run_remote_heredoc "Stop and remove supervisor config for bench ${_BENCH_ID}" "
set +e
supervisorctl stop '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl stop '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
_conf='/etc/supervisor/conf.d/${_SUPERVISOR_CONF_NAME}.conf'
if [[ -f \"\${_conf}\" ]]; then
  rm -f \"\${_conf}\"
  supervisorctl reread 2>/dev/null || true
  supervisorctl update 2>/dev/null || true
  echo \"Removed supervisor config: ${_SUPERVISOR_CONF_NAME}\"
else
  echo 'No supervisor config found for: ${_SUPERVISOR_CONF_NAME}'
fi
"

  local _vol_fmt='{{.Name}}'

  run_remote_as_owner "Stop and remove containers, volumes, and systemd units for bench ${_BENCH_ID}" "
set +e

systemctl stop ${_SERVICE_NAME} 2>/dev/null || true
systemctl disable ${_SERVICE_NAME} 2>/dev/null || true
rm -f ${_SYSTEMD_UNIT} 2>/dev/null || true
rm -f ${_WRAPPER_SCRIPT} 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

for container in \
  ${LMS_POSTGRES_CONTAINER} \
  ${LMS_REDIS_CACHE_CONTAINER} \
  ${LMS_REDIS_QUEUE_CONTAINER}; do
  podman stop \"\${container}\" 2>/dev/null || true
  podman rm -f \"\${container}\" 2>/dev/null || true
  echo \"Removed container: \${container}\"
done

for vol in \$(podman volume ls --format '${_vol_fmt}' 2>/dev/null | grep -E '^lms-${_BENCH_ID}' || true); do
  podman volume rm -f \"\${vol}\" 2>/dev/null || true
  echo \"Removed volume: \${vol}\"
done

echo 'Container, volume, and service cleanup complete for bench ${_BENCH_ID}'
"
  success "Supervisor, containers, and volumes cleaned for bench ${_BENCH_ID}"
  _deploy_log "clean-services complete"
}

do_clean_bench() {
  header "Deep clean: bench ${_BENCH_ID}"
  _deploy_log "Action: deep bench clean"

  warn "This will permanently remove:"
  warn "  Bench dir:   ${LMS_FRAPPE_BENCH_DIR}"
  warn "  Site DB:     ${LMS_FRAPPE_SITE} (postgres port ${LMS_PG_PORT})"
  warn "  Supervisor:  ${_SUPERVISOR_CONF_NAME}.conf"
  warn "  Nginx conf:  ${_NGINX_CONF_NAME}.conf"
  warn "  Systemd:     ${_SERVICE_NAME}"
  warn "  Containers:  ${LMS_POSTGRES_CONTAINER}, ${LMS_REDIS_CACHE_CONTAINER}, ${LMS_REDIS_QUEUE_CONTAINER}"
  warn "  Volumes:     all podman volumes prefixed lms-${_BENCH_ID}"

  if ! $LMS_FORCE; then
    if [[ ! -t 0 ]]; then
      die "Deep clean requires --force or an interactive terminal."
    fi
    read -rp "  Confirm deep wipe of bench '${_BENCH_ID}'? [y/N] " _confirm
    [[ "${_confirm,,}" == "y" ]] || { info "Clean cancelled."; return 0; }
  fi

  run_remote_heredoc "Stop all supervisor processes for bench ${_BENCH_ID}" "
set +e
supervisorctl stop '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl stop '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true

_conf='/etc/supervisor/conf.d/${_SUPERVISOR_CONF_NAME}.conf'
[[ -f \"\${_conf}\" ]] && rm -f \"\${_conf}\" && echo \"Removed: \${_conf}\"

supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true

for _nc in \
  '/etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf' \
  '/etc/nginx/sites-enabled/${_NGINX_CONF_NAME}.conf'; do
  [[ -f \"\${_nc}\" ]] && rm -f \"\${_nc}\" && echo \"Removed nginx conf: \${_nc}\"
done
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

_site_db=\$(echo '${LMS_FRAPPE_SITE}' | tr '.' '_' | tr '-' '_')
psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
  -c \"DROP DATABASE IF EXISTS \\\"\${_site_db}\\\";\" 2>/dev/null \
  && echo \"Dropped DB: \${_site_db}\" || echo 'DB drop failed or already gone'

[[ -d '${LMS_FRAPPE_BENCH_DIR}' ]] \
  && rm -rf '${LMS_FRAPPE_BENCH_DIR}' \
  && echo 'Removed bench dir: ${LMS_FRAPPE_BENCH_DIR}'

df -h /
echo 'Bench deep wipe complete.'
"

  local _vol_fmt='{{.Name}}'

  run_remote_as_owner "Stop, disable, and remove all containers, volumes, and user units for bench ${_BENCH_ID}" "
set +e

systemctl stop ${_SERVICE_NAME} 2>/dev/null || true
systemctl disable ${_SERVICE_NAME} 2>/dev/null || true
rm -f ${_SYSTEMD_UNIT} 2>/dev/null || true
rm -f ${_WRAPPER_SCRIPT} 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

for container in \
  ${LMS_POSTGRES_CONTAINER} \
  ${LMS_REDIS_CACHE_CONTAINER} \
  ${LMS_REDIS_QUEUE_CONTAINER}; do
  podman stop \"\${container}\" 2>/dev/null || true
  podman rm -f \"\${container}\" 2>/dev/null || true
  echo \"Removed container: \${container}\"
done

for vol in \$(podman volume ls --format '${_vol_fmt}' 2>/dev/null | grep -E '^lms-${_BENCH_ID}' || true); do
  podman volume rm -f \"\${vol}\" 2>/dev/null || true
  echo \"Removed volume: \${vol}\"
done

echo 'Container and volume cleanup complete.'
"
  _deploy_log "Deep clean complete"
}

do_update() {
  header "Update: pull + migrate + restart [${_BENCH_ID}]"
  _deploy_log "Action: update"

  if ! $LMS_DRY_RUN; then
    _bench_ok=$(ssh ${SSH_BASE_OPTS} "$TARGET" \
      "test -d '${LMS_FRAPPE_BENCH_DIR}/apps/tap_lms' && echo yes || echo no" 2>/dev/null || echo no)
    if [[ "$_bench_ok" != "yes" ]]; then
      warn "Bench or tap_lms app not found — falling back to full deploy"
      _deploy_log "Update: bench missing, running full deploy"
      LMS_UPDATE_ONLY=false
      return 0
    fi
  fi

  run_remote_as_frappe "git pull + migrate + build [${_BENCH_ID}]" "
cd ${LMS_FRAPPE_BENCH_DIR}/apps/tap_lms
git remote get-url origin >/dev/null 2>&1 || git remote add origin ${LMS_GIT_REPO}
git remote set-url origin ${LMS_GIT_REPO}
git fetch --all --prune
git checkout ${LMS_GIT_BRANCH} 2>/dev/null \
  || git checkout -b ${LMS_GIT_BRANCH} origin/${LMS_GIT_BRANCH}
git reset --hard origin/${LMS_GIT_BRANCH}
echo \"HEAD: \$(git log --oneline -1)\"
cd ${LMS_FRAPPE_BENCH_DIR}
bench --site ${LMS_FRAPPE_SITE} migrate
bench build --app tap_lms --force
"
  run_remote_heredoc "Restart bench supervisor processes after update [${_BENCH_ID}]" "
set +e
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5
supervisorctl status 2>/dev/null || true
"
  _restart_lms_app_with_diagnostics
  success "Update complete [${_BENCH_ID}]"
  _deploy_log "Update complete"
}

do_update_config() {
  header "Update config: site config + DB settings [${_BENCH_ID}]"
  _deploy_log "Action: update-config"

  if ! $LMS_DRY_RUN; then
    _bench_ok=$(ssh ${SSH_BASE_OPTS} "$TARGET" \
      "test -d '${LMS_FRAPPE_BENCH_DIR}/apps/tap_lms' && echo yes || echo no" 2>/dev/null || echo no)
    if [[ "$_bench_ok" != "yes" ]]; then
      die "Bench not found at ${LMS_FRAPPE_BENCH_DIR} — run a full deploy first."
    fi
  fi

  run_remote_as_frappe "Update common_site_config and bench site config [${_BENCH_ID}]" "
cd ${LMS_FRAPPE_BENCH_DIR}
cat > ${_SITES_DIR}/common_site_config.json <<SITECFG
{
  \"background_workers\": 1,
  \"frappe_user\": \"${LMS_FRAPPE_USER}\",
  \"gunicorn_workers\": 4,
  \"live_reload\": false,
  \"redis_cache\": \"redis://127.0.0.1:${LMS_REDIS_CACHE_PORT}\",
  \"redis_queue\": \"redis://127.0.0.1:${LMS_REDIS_QUEUE_PORT}\",
  \"redis_socketio\": \"redis://127.0.0.1:${LMS_REDIS_SOCKETIO_PORT}\",
  \"restart_supervisor_on_update\": false,
  \"restart_systemd_on_update\": false,
  \"serve_default_site\": true,
  \"socketio_port\": ${LMS_SOCKETIO_PORT},
  \"use_redis_auth\": false,
  \"webserver_port\": ${LMS_GUNICORN_PORT},
  \"default_site\": \"${LMS_FRAPPE_SITE}\",
  \"db_host\": \"${LMS_PG_HOST}\",
  \"db_port\": ${LMS_PG_PORT}
}
SITECFG
echo 'common_site_config.json updated'

bench --site ${LMS_FRAPPE_SITE} set-config db_host '${LMS_PG_HOST}'
bench --site ${LMS_FRAPPE_SITE} set-config db_port ${LMS_PG_PORT}

if ${LMS_DEPLOY_DOMAIN}; then
  _host_prefix='http'
  ${LMS_ENABLE_HTTPS} && _host_prefix='https'
  bench --site ${LMS_FRAPPE_SITE} set-config host_name \"\${_host_prefix}://${LMS_DOMAIN_NAME}\"
else
  bench --site ${LMS_FRAPPE_SITE} set-config host_name 'http://${LMS_SERVER_HOST}:${LMS_WEB_PORT}'
fi
echo 'Bench site config updated'
"

  _write_pgpass_remote

  run_remote_heredoc "Restart bench supervisor processes [${_BENCH_ID}]" "
set +e
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5
supervisorctl status 2>/dev/null || true
"

  LMS_WAIT 5
  _restart_lms_app_with_diagnostics

  success "Config update complete [${_BENCH_ID}]"
  _deploy_log "update-config complete"
}

header "Pre-flight [${_BENCH_ID}]"
_deploy_log "=== LMS Deploy session started ==="

[[ -f "$LMS_SSH_KEY_PATH" ]] || die "SSH key not found: $LMS_SSH_KEY_PATH"
chmod 600 "$LMS_SSH_KEY_PATH"
success "SSH key OK"

if ! $LMS_DRY_RUN; then
  _ssh_master_up
  ssh ${SSH_BASE_OPTS} "$TARGET" "echo 'SSH OK'" > /dev/null 2>&1 \
    || die "Cannot connect to ${TARGET} on port ${LMS_SSH_PORT}"
fi
success "SSH connection verified → ${TARGET}"
_deploy_log "SSH verified → ${TARGET}"

$LMS_ENABLE_HTTPS \
  && info "Deploy mode: HTTPS  → $(_effective_url)" \
  || { $LMS_DEPLOY_DOMAIN \
         && info "Deploy mode: DOMAIN → $(_effective_url)" \
         || info "Deploy mode: PORT   → $(_effective_url)"; }

$LMS_DRY_RUN && warn "DRY RUN — SSH commands printed, not executed."

if $LMS_STOP_ONLY;     then do_stop;          _deploy_log "=== Session end ==="; exit 0; fi
if $LMS_RESTART_ONLY;  then do_restart;        _deploy_log "=== Session end ==="; exit 0; fi
if $LMS_STATUS_ONLY;   then do_status;         _deploy_log "=== Session end ==="; exit 0; fi
if $LMS_UPDATE_CONFIG; then do_update_config;  _deploy_log "=== Session end ==="; exit 0; fi

if $LMS_UPDATE_ONLY; then
  do_update
  if $LMS_UPDATE_ONLY; then _deploy_log "=== Session end ==="; exit 0; fi
  warn "--update fell back to full deploy because bench was missing"
fi

if $LMS_CLEAN_SERVICES; then
  do_clean_services
  $LMS_CLEAN_ONLY && { _deploy_log "=== Session end ==="; exit 0; }
fi

if $LMS_CLEAN_BENCH || $LMS_CLEAN; then
  do_clean_bench
  $LMS_CLEAN_ONLY && { _deploy_log "=== Session end ==="; exit 0; }
fi

if step_enabled 1; then
  header "Step 1 — System packages + podman"
  _deploy_log "Step 1: system packages and podman"
  run_remote_heredoc "Install system packages and podman" "
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  build-essential curl git vim netcat-openbsd \
  virtualenv software-properties-common \
  postgresql-client redis-tools \
  supervisor \
  xvfb libfontconfig wkhtmltopdf \
  nginx fail2ban cron npm \
  openssl \
  2>&1 | tail -5

if ! ${LMS_PYTHON_VERSION} --version &>/dev/null 2>&1; then
  add-apt-repository ppa:deadsnakes/ppa -y 2>/dev/null || true
  apt-get update -qq
  _pyver=\$(echo '${LMS_PYTHON_VERSION}' | sed 's/python//')
  apt-get install -y -qq \
    python\${_pyver} python\${_pyver}-dev python\${_pyver}-venv python\${_pyver}-distutils \
    2>&1 | tail -3
fi

if ! command -v podman &>/dev/null; then
  if apt-cache show podman &>/dev/null 2>&1; then
    apt-get install -y -qq podman 2>&1 | tail -3
  else
    apt-get install -y -qq podman-docker 2>&1 | tail -3 || \
    { curl -fsSL https://raw.githubusercontent.com/containers/podman/main/contrib/podmansetup/podman-setup.sh \
        | bash -s -- --quiet 2>&1 | tail -5; } || true
  fi
fi

if ! command -v podman &>/dev/null; then
  echo 'FATAL: podman could not be installed' >&2
  exit 1
fi

loginctl enable-linger '${LMS_SERVICE_OWNER}' 2>/dev/null || true

apt-get clean
rm -rf /var/lib/apt/lists/*

pip3 install frappe-bench --break-system-packages -q 2>&1 | tail -2
npm install -g yarn -q 2>&1 | tail -2

echo \"podman: \$(podman --version)\"
echo \"yarn: \$(yarn --version)\"
echo \"frappe-bench: \$(bench --version 2>/dev/null || pip3 show frappe-bench 2>/dev/null | grep Version)\"
echo \"${LMS_PYTHON_VERSION}: \$(${LMS_PYTHON_VERSION} --version)\"
"
  success "System packages and podman installed"
  _deploy_log "Step 1 complete"
fi

if step_enabled 2; then
  header "Step 2 — Container units + OS user + Postgres bootstrap [${_BENCH_ID}]"
  _deploy_log "Step 2: container units, frappe user, postgres"

  run_remote_as_owner "Start all infrastructure containers [${_BENCH_ID}]" "
_uid=\$(id -u)
export XDG_RUNTIME_DIR=/run/user/\${_uid}
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${_uid}/bus
loginctl enable-linger \$(whoami) 2>/dev/null || true

_start_container() {
  local name=\"\$1\"
  local run_args=\"\$2\"
  podman stop \"\${name}\" 2>/dev/null || true
  podman rm -f \"\${name}\" 2>/dev/null || true
  eval podman run -d --name \"\${name}\" --restart=always \${run_args}
  echo \"Started: \${name}\"
}

podman pull ${LMS_POSTGRES_IMAGE} 2>/dev/null || true
_start_container '${LMS_POSTGRES_CONTAINER}' \
  \"-e POSTGRES_PASSWORD=${LMS_POSTGRES_PASSWORD} -p ${LMS_PG_HOST}:${LMS_PG_PORT}:5432 ${LMS_POSTGRES_IMAGE}\"

podman pull ${LMS_REDIS_IMAGE} 2>/dev/null || true
_start_container '${LMS_REDIS_CACHE_CONTAINER}' \
  \"-p 127.0.0.1:${LMS_REDIS_CACHE_PORT}:6379 ${LMS_REDIS_IMAGE} redis-server --maxmemory ${LMS_REDIS_MAXMEMORY} --maxmemory-policy ${LMS_REDIS_MAXMEMORY_POLICY}\"

_start_container '${LMS_REDIS_QUEUE_CONTAINER}' \
  \"-p 127.0.0.1:${LMS_REDIS_QUEUE_PORT}:6379 ${LMS_REDIS_IMAGE} redis-server --maxmemory ${LMS_REDIS_MAXMEMORY} --maxmemory-policy ${LMS_REDIS_MAXMEMORY_POLICY}\"

echo 'All containers started with --restart=always'

_wait_postgres_ready() {
  local host=\"\$1\" port=\"\$2\"
  echo \"Waiting for postgres to be fully ready on \${host}:\${port}...\"
  local i=0
  while [[ \${i} -lt 60 ]]; do
    i=\$(( i + 1 ))
    local out
    out=\$(PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql \
      -h \"\${host}\" -p \"\${port}\" -U postgres \
      -c 'SELECT 1' 2>&1)
    local rc=\$?
    if [[ \${rc} -eq 0 ]]; then
      echo \"postgres: ready after \$(( i * 3 ))s\"
      return 0
    fi
    if echo \"\${out}\" | grep -qE 'starting up|starting|recovery'; then
      echo \"postgres: initialising [\${i}/60]\"
    elif echo \"\${out}\" | grep -qE 'refused|no route|timeout|Cannot'; then
      echo \"postgres: port not open yet [\${i}/60]\"
    else
      echo \"postgres: \${out} [\${i}/60]\"
    fi
    sleep 3
  done
  echo 'FATAL: postgres not ready after 180s' >&2
  exit 1
}

_wait_redis() {
  local port=\"\$1\" label=\"\$2\"
  echo \"Waiting for \${label} on port \${port}...\"
  local i=0
  while [[ \${i} -lt 40 ]]; do
    i=\$(( i + 1 ))
    redis-cli -h 127.0.0.1 -p \"\${port}\" ping 2>/dev/null | grep -q PONG && echo \"\${label}: OK\" && return 0
    sleep 3
  done
  echo \"FATAL: \${label} not ready after 120s\" >&2; exit 1
}

_wait_postgres_ready ${LMS_PG_HOST} ${LMS_PG_PORT}
_wait_redis ${LMS_REDIS_CACHE_PORT} 'redis-cache'
_wait_redis ${LMS_REDIS_QUEUE_PORT} 'redis-queue'
"

  run_remote_heredoc "Create frappe OS user and configure postgres [${_BENCH_ID}]" "
set +e
id ${LMS_FRAPPE_USER} &>/dev/null || useradd -ms /bin/bash ${LMS_FRAPPE_USER}

grep -qxF '${LMS_FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL' /etc/sudoers \
  || echo '${LMS_FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

chmod 755 /home/${LMS_FRAPPE_USER}
usermod -a -G ${LMS_FRAPPE_USER} www-data 2>/dev/null || true

mkdir -p /home/${LMS_FRAPPE_USER}/logs
chown -R ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} /home/${LMS_FRAPPE_USER}/logs
chmod 755 /home/${LMS_FRAPPE_USER}/logs

echo 'Verifying postgres is accepting connections on ${LMS_PG_HOST}:${LMS_PG_PORT}...'
i=0
while [[ \${i} -lt 40 ]]; do
  i=\$(( i + 1 ))
  out=\$(PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql \
    -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
    -c 'SELECT 1' 2>&1)
  rc=\$?
  if [[ \${rc} -eq 0 ]]; then
    echo 'postgres: OK'
    break
  fi
  echo \"postgres not ready yet [\${i}/40]: \${out}\"
  sleep 3
  if [[ \${i} -eq 40 ]]; then
    echo 'FATAL: postgres not ready' >&2
    exit 1
  fi
done

PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
  -c \"ALTER USER postgres WITH SUPERUSER CREATEDB CREATEROLE PASSWORD '${LMS_POSTGRES_PASSWORD}';\"

PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres -d template1 \
  -c 'GRANT ALL ON SCHEMA public TO PUBLIC;'

PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres -d template1 \
  -c 'ALTER SCHEMA public OWNER TO postgres;'

echo 'frappe user and postgres ready'
id ${LMS_FRAPPE_USER}
"

  _write_pgpass_remote

  success "Containers started, frappe user and postgres configured [${_BENCH_ID}]"
  _deploy_log "Step 2 complete"
fi

if step_enabled 3; then
  header "Step 3 — NVM + Node (${LMS_NODE_VERSION}) for ${LMS_FRAPPE_USER}"
  _deploy_log "Step 3: nvm + node"
  run_remote_as_frappe "Install NVM and Node ${LMS_NODE_VERSION}" "
export NVM_DIR=\"\${HOME}/.nvm\"
if [[ ! -s \"\${NVM_DIR}/nvm.sh\" ]]; then
  curl -fsSL ${LMS_NVM_INSTALL_URL} | bash
fi
source \"\${NVM_DIR}/nvm.sh\"
nvm install ${LMS_NODE_VERSION}
nvm use ${LMS_NODE_VERSION}
nvm alias default ${LMS_NODE_VERSION}
echo \"node: \$(node --version)\"
echo \"npm:  \$(npm --version)\"
npm install -g yarn
echo \"yarn: \$(yarn --version)\"
"
  success "NVM and Node ${LMS_NODE_VERSION} ready"
  _deploy_log "Step 3 complete"
fi

if step_enabled 4; then
  header "Step 4 — Frappe bench init [${_BENCH_ID}]"
  _deploy_log "Step 4: bench init"
  run_remote_as_frappe "bench init ${LMS_FRAPPE_BENCH_DIR}" "
if [[ -d ${LMS_FRAPPE_BENCH_DIR} ]]; then
  echo 'bench dir exists — skipping init'
else
  bench init ${LMS_FRAPPE_BENCH_DIR} \
    --frappe-branch ${LMS_FRAPPE_BRANCH} \
    --python ${LMS_PYTHON_VERSION} \
    --skip-assets \
    --no-procfile \
    --no-backups
fi

mkdir -p ${_BENCH_LOGS_DIR}
mkdir -p ${_SITES_DIR}/logs
chown -R ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} ${_BENCH_LOGS_DIR} 2>/dev/null || true
chown -R ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} ${_SITES_DIR}/logs 2>/dev/null || true

cat > ${_SITES_DIR}/common_site_config.json <<SITECFG
{
  \"background_workers\": 1,
  \"frappe_user\": \"${LMS_FRAPPE_USER}\",
  \"gunicorn_workers\": 4,
  \"live_reload\": false,
  \"redis_cache\": \"redis://127.0.0.1:${LMS_REDIS_CACHE_PORT}\",
  \"redis_queue\": \"redis://127.0.0.1:${LMS_REDIS_QUEUE_PORT}\",
  \"redis_socketio\": \"redis://127.0.0.1:${LMS_REDIS_SOCKETIO_PORT}\",
  \"restart_supervisor_on_update\": false,
  \"restart_systemd_on_update\": false,
  \"serve_default_site\": true,
  \"socketio_port\": ${LMS_SOCKETIO_PORT},
  \"use_redis_auth\": false,
  \"webserver_port\": ${LMS_GUNICORN_PORT},
  \"default_site\": \"${LMS_FRAPPE_SITE}\",
  \"db_host\": \"${LMS_PG_HOST}\",
  \"db_port\": ${LMS_PG_PORT}
}
SITECFG

echo 'bench init done'
ls ${LMS_FRAPPE_BENCH_DIR}/apps/
"
  success "Frappe bench initialised [${_BENCH_ID}]"
  _deploy_log "Step 4 complete"
fi

if step_enabled 5; then
  header "Step 5 — Verify infrastructure containers [${_BENCH_ID}]"
  _deploy_log "Step 5: verify containers"

  _S5_INSPECT_FMT='{{.State.Status}}'

  run_remote_as_owner "Ensure all infrastructure containers are running [${_BENCH_ID}]" "
set +e

_ensure_container() {
  local name=\"\$1\"
  local state
  state=\$(podman inspect --format '${_S5_INSPECT_FMT}' \"\${name}\" 2>/dev/null || echo 'missing')
  if [[ \"\${state}\" != 'running' ]]; then
    echo \"Starting \${name} (state: \${state})\"
    podman start \"\${name}\" 2>/dev/null || true
    sleep 3
  else
    echo \"\${name}: running\"
  fi
}

_ensure_container '${LMS_POSTGRES_CONTAINER}'
_ensure_container '${LMS_REDIS_CACHE_CONTAINER}'
_ensure_container '${LMS_REDIS_QUEUE_CONTAINER}'

_wait_redis() {
  local port=\"\$1\" label=\"\$2\"
  echo \"Verifying \${label} on port \${port}...\"
  local i=0
  while [[ \${i} -lt 30 ]]; do
    i=\$(( i + 1 ))
    redis-cli -h 127.0.0.1 -p \"\${port}\" ping 2>/dev/null | grep -q PONG && echo \"\${label}: OK\" && return 0
    sleep 3
  done
  echo \"FATAL: \${label} not ready\" >&2; exit 1
}

_wait_redis ${LMS_REDIS_CACHE_PORT} 'redis-cache'
_wait_redis ${LMS_REDIS_QUEUE_PORT} 'redis-queue'
echo 'Redis verified'
"

  run_remote_heredoc "Verify postgres connectivity [${_BENCH_ID}]" "
echo 'Verifying postgres on ${LMS_PG_HOST}:${LMS_PG_PORT}...'
i=0
while [[ \${i} -lt 30 ]]; do
  i=\$(( i + 1 ))
  out=\$(PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql \
    -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
    -c 'SELECT 1' 2>&1)
  rc=\$?
  if [[ \${rc} -eq 0 ]]; then
    echo 'postgres: OK'
    break
  fi
  echo \"postgres not ready [\${i}/30]: \${out}\"
  sleep 3
  [[ \${i} -eq 30 ]] && echo 'FATAL: postgres not ready after 90s' >&2 && exit 1
done
echo 'All infrastructure containers verified'
"
  success "Infrastructure containers verified [${_BENCH_ID}]"
  _deploy_log "Step 5 complete"
fi

if step_enabled 6; then
  header "Step 6 — Create Frappe site [${_BENCH_ID}]"
  _deploy_log "Step 6: new site"

  run_remote_heredoc "Verify site DB connectivity and wipe stale site if needed [${_BENCH_ID}]" "
set +e

_site_db=\$(echo '${LMS_FRAPPE_SITE}' | tr '.' '_' | tr '-' '_')

if [[ -d '${_SITE_DIR}' ]]; then
  _db_user=\$(python3 -c \"
import json, sys
try:
    cfg = json.load(open('${_SITE_DIR}/site_config.json'))
    print(cfg.get('db_name',''))
except:
    print('')
\" 2>/dev/null || true)
  _db_pass=\$(python3 -c \"
import json, sys
try:
    cfg = json.load(open('${_SITE_DIR}/site_config.json'))
    print(cfg.get('db_password',''))
except:
    print('')
\" 2>/dev/null || true)

  if [[ -n \"\${_db_user}\" ]]; then
    PGPASSWORD=\"\${_db_pass}\" psql \
      -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} \
      -U \"\${_db_user}\" -d \"\${_db_user}\" \
      -c 'SELECT 1' >/dev/null 2>&1
    _conn_ok=\$?
  else
    _conn_ok=1
  fi

  if [[ \${_conn_ok} -ne 0 ]]; then
    echo 'Site DB unreachable or stale — wiping site dir and dropping DB/role'
    PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
      -c \"DROP DATABASE IF EXISTS \\\"\${_db_user}\\\";\" 2>/dev/null || true
    PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
      -c \"DROP DATABASE IF EXISTS \\\"\${_site_db}\\\";\" 2>/dev/null || true
    PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
      -c \"DROP ROLE IF EXISTS \\\"\${_db_user}\\\";\" 2>/dev/null || true
    rm -rf '${_SITE_DIR}'
    echo 'Stale site wiped — will recreate'
  else
    echo 'Site DB connection OK — site is healthy'
  fi
else
  echo 'No existing site dir found — will create fresh'
fi
"

  run_remote_as_frappe "bench new-site ${LMS_FRAPPE_SITE} [${_BENCH_ID}]" "
cd ${LMS_FRAPPE_BENCH_DIR}

if [[ -d ${_SITE_DIR} ]]; then
  echo 'site already exists and DB is healthy — skipping new-site'
else
  PGPASSWORD='${LMS_POSTGRES_PASSWORD}' \
  bench new-site ${LMS_FRAPPE_SITE} \
    --db-type postgres \
    --db-root-username postgres \
    --db-root-password '${LMS_POSTGRES_PASSWORD}' \
    --db-host ${LMS_PG_HOST} \
    --db-port ${LMS_PG_PORT} \
    --admin-password '${LMS_FRAPPE_ADMIN_PASSWORD}'
fi

bench use ${LMS_FRAPPE_SITE}
bench --site ${LMS_FRAPPE_SITE} set-config db_host '${LMS_PG_HOST}'
bench --site ${LMS_FRAPPE_SITE} set-config db_port ${LMS_PG_PORT}
bench --site ${LMS_FRAPPE_SITE} set-config server_script_enabled true
bench --site ${LMS_FRAPPE_SITE} set-config serve_default_site true

_host_proto='http'
${LMS_ENABLE_HTTPS} && _host_proto='https'

if ${LMS_DEPLOY_DOMAIN}; then
  bench --site ${LMS_FRAPPE_SITE} set-config host_name \"\${_host_proto}://${LMS_DOMAIN_NAME}\"
else
  bench --site ${LMS_FRAPPE_SITE} set-config host_name 'http://${LMS_SERVER_HOST}:${LMS_WEB_PORT}'
fi

echo '${LMS_FRAPPE_SITE}' > ${_SITES_DIR}/currentsite.txt

mkdir -p ${_SITE_LOGS_DIR}
mkdir -p ${_SITE_LOGS_ALT}
chown -R ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} ${_SITE_LOGS_DIR} 2>/dev/null || true
chown -R ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} ${_SITE_LOGS_ALT} 2>/dev/null || true

echo 'site ready'
"

  run_remote_heredoc "Ensure site DB password and .pgpass [${_BENCH_ID}]" "
set +e
if [[ -f '${_SITE_DIR}/site_config.json' ]]; then
  _db_name=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_name',''))\" 2>/dev/null || true)
  _db_pass=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_password',''))\" 2>/dev/null || true)
  if [[ -n \"\${_db_name}\" && -n \"\${_db_pass}\" ]]; then
    PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres <<PGSQL
DO \\\$\\\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '\${_db_name}') THEN
    CREATE ROLE \"\${_db_name}\" WITH LOGIN PASSWORD '\${_db_pass}';
  ELSE
    ALTER ROLE \"\${_db_name}\" WITH LOGIN PASSWORD '\${_db_pass}';
  END IF;
END
\\\$\\\$;
GRANT ALL PRIVILEGES ON DATABASE \"\${_db_name}\" TO \"\${_db_name}\";
PGSQL
    echo \"Postgres role ensured for \${_db_name}\"
  fi
fi
"
  _write_pgpass_remote

  success "Frappe site ready [${_BENCH_ID}]"
  _deploy_log "Step 6 complete"
fi

if step_enabled 7; then
  header "Step 7 — Install tap_lms app [${_BENCH_ID}]"
  _deploy_log "Step 7: install tap_lms"
  run_remote_as_frappe "get-app + install-app tap_lms [${_BENCH_ID}]" "
cd ${LMS_FRAPPE_BENCH_DIR}

if [[ -d apps/tap_lms ]]; then
  echo 'tap_lms present — pulling latest'
  cd apps/tap_lms
  git remote set-url origin ${LMS_GIT_REPO} 2>/dev/null || git remote add origin ${LMS_GIT_REPO}
  git fetch --all --prune
  git checkout ${LMS_GIT_BRANCH} 2>/dev/null \
    || git checkout -b ${LMS_GIT_BRANCH} origin/${LMS_GIT_BRANCH}
  git reset --hard origin/${LMS_GIT_BRANCH}
  echo \"HEAD: \$(git log --oneline -1)\"
  cd ${LMS_FRAPPE_BENCH_DIR}
else
  bench get-app ${LMS_GIT_REPO} --branch ${LMS_GIT_BRANCH}
fi

_lms_installed=\$(bench --site ${LMS_FRAPPE_SITE} list-apps 2>/dev/null | grep -c '^tap_lms\$' || true)
if [[ \${_lms_installed} -gt 0 ]]; then
  echo 'tap_lms already installed — skipping'
else
  bench --site ${LMS_FRAPPE_SITE} install-app tap_lms
  echo 'tap_lms installed'
fi
"
  success "tap_lms installed [${_BENCH_ID}]"
  _deploy_log "Step 7 complete"
fi

if step_enabled 8; then
  header "Step 8 — Install business_theme_v14 [${_BENCH_ID}]"
  _deploy_log "Step 8: install business theme"
  run_remote_as_frappe "get-app + install-app business_theme_v14 [${_BENCH_ID}]" "
cd ${LMS_FRAPPE_BENCH_DIR}

[[ ! -d apps/business_theme_v14 ]] \
  && bench get-app ${LMS_BUSINESS_THEME_REPO} --branch ${LMS_BUSINESS_THEME_BRANCH}

_theme_installed=\$(bench --site ${LMS_FRAPPE_SITE} list-apps 2>/dev/null | grep -c '^business_theme_v14\$' || true)
if [[ \${_theme_installed} -gt 0 ]]; then
  echo 'business_theme_v14 already installed — skipping'
else
  bench --site ${LMS_FRAPPE_SITE} install-app business_theme_v14
  echo 'business_theme_v14 installed'
fi
"
  success "business_theme_v14 installed [${_BENCH_ID}]"
  _deploy_log "Step 8 complete"
fi

if step_enabled 9; then
  header "Step 9 — bench migrate + build + scheduler [${_BENCH_ID}]"
  _deploy_log "Step 9: migrate, build, scheduler"
  run_remote_as_frappe "bench migrate + build + scheduler [${_BENCH_ID}]" "
cd ${LMS_FRAPPE_BENCH_DIR}
bench --site ${LMS_FRAPPE_SITE} migrate
bench build --production --force
bench --site ${LMS_FRAPPE_SITE} enable-scheduler
bench --site ${LMS_FRAPPE_SITE} set-maintenance-mode off
bench clear-cache
bench --site ${LMS_FRAPPE_SITE} clear-website-cache
echo 'migrate and build done'
"
  success "Migrations applied and assets built [${_BENCH_ID}]"
  _deploy_log "Step 9 complete"
fi

if step_enabled 10; then
  header "Step 10 — Supervisor + Nginx [${_BENCH_ID}]"
  _deploy_log "Step 10: supervisor and nginx"

  _NGINX_CONF_CONTENT="$(_build_nginx_conf)"

  if $LMS_ENABLE_HTTPS; then
    _ensure_tls_cert
  fi

  run_remote_as_frappe "bench setup supervisor [${_BENCH_ID}]" "
cd ${LMS_FRAPPE_BENCH_DIR}
bench setup supervisor --yes
echo 'supervisor config generated'
"

  _NGINX_TMP=$(mktemp)
  printf '%s\n' "${_NGINX_CONF_CONTENT}" > "${_NGINX_TMP}"
  _NGINX_REMOTE_TMP="/tmp/lms-nginx-${_BENCH_ID}-$$.conf"

  if ! $LMS_DRY_RUN; then
    scp ${SCP_OPTS} "${_NGINX_TMP}" "${TARGET}:${_NGINX_REMOTE_TMP}"
  fi
  rm -f "${_NGINX_TMP}"

  _PY_STRIP_LOCAL=$(mktemp /tmp/lms-strip-XXXXXX.py)
  _PY_STRIP_REMOTE="/tmp/lms-strip-${_BENCH_ID}-$$.py"

  cat > "${_PY_STRIP_LOCAL}" <<PYEOF
import re, pathlib, sys

src = pathlib.Path('${LMS_FRAPPE_BENCH_DIR}/config/supervisor.conf')
dst = pathlib.Path('/etc/supervisor/conf.d/${_SUPERVISOR_CONF_NAME}.conf')
if not src.exists():
    print('ERROR: supervisor.conf not found', file=sys.stderr)
    sys.exit(1)

txt = src.read_text()

txt = re.sub(
    r'\[(?:program|group):[^\]]*redis[^\]]*\][^\[]*',
    '',
    txt,
    flags=re.DOTALL | re.IGNORECASE,
)

txt = re.sub(r'\[group:[^\]]*-web\]',     '[group:${_SUPERVISOR_CONF_NAME}-web]',     txt)
txt = re.sub(r'\[group:[^\]]*-workers\]', '[group:${_SUPERVISOR_CONF_NAME}-workers]', txt)

txt = re.sub(r'(?m)^programs\s*=.*redis.*\n', '', txt, flags=re.IGNORECASE)

dst.write_text(txt)
print(f'Installed supervisor config: {dst}')
print('Redis sections stripped; web+worker groups renamed.')
PYEOF

  if ! $LMS_DRY_RUN; then
    scp ${SCP_OPTS} "${_PY_STRIP_LOCAL}" "${TARGET}:${_PY_STRIP_REMOTE}"
  else
    info "DRY RUN: would scp supervisor strip script to remote"
  fi
  rm -f "${_PY_STRIP_LOCAL}"

  run_remote_heredoc "Install supervisor config and nginx config [${_BENCH_ID}]" "
set +e

supervisorctl stop 'frappe-bench-web:' 2>/dev/null || true
supervisorctl stop 'frappe-bench-workers:' 2>/dev/null || true

for _old_conf in /etc/supervisor/conf.d/frappe-bench*.conf; do
  [[ -f \"\${_old_conf}\" ]] || continue
  rm -f \"\${_old_conf}\"
  echo \"Removed legacy config: \${_old_conf}\"
done

supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true

_src='${LMS_FRAPPE_BENCH_DIR}/config/supervisor.conf'

if [[ -f \"\${_src}\" ]]; then
  python3 '${_PY_STRIP_REMOTE}'
  rm -f '${_PY_STRIP_REMOTE}'
fi

rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
rm -f /etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/${_NGINX_CONF_NAME}.conf 2>/dev/null || true

if [[ -f '${_NGINX_REMOTE_TMP}' ]]; then
  mv '${_NGINX_REMOTE_TMP}' /etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf
  chown root:root /etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf
  chmod 644 /etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf
else
  echo 'WARNING: nginx temp config not found — nginx may not be correctly configured' >&2
fi

nginx -t \
  && systemctl reload nginx \
  && echo 'nginx reloaded OK' \
  || { echo 'FATAL: nginx config invalid — reverting' >&2; rm -f /etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf; exit 1; }

systemctl enable supervisor
supervisorctl reread 2>&1 || true
supervisorctl update 2>&1 || true

echo '=== Supervisor status ==='
supervisorctl status 2>/dev/null || true
"
  success "Supervisor and Nginx configured [${_BENCH_ID}]"
  _deploy_log "Step 10 complete"
fi

if step_enabled 11; then
  header "Step 11 — Log directories + permissions [${_BENCH_ID}]"
  _deploy_log "Step 11: log dirs"
  _ensure_all_log_dirs
  success "Log directories ready [${_BENCH_ID}]"
  _deploy_log "Step 11 complete"
fi

if step_enabled 12; then
  header "Step 12 — Gunicorn systemd service [${_BENCH_ID}]"
  _deploy_log "Step 12: gunicorn service"

  _S12_GUNICORN_CONF_LOCAL=$(mktemp /tmp/lms-gunicorn-XXXXXX.conf.py)
  _S12_UNIT_LOCAL=$(mktemp /tmp/lms-unit-XXXXXX.service)
  _S12_GUNICORN_CONF_REMOTE="/tmp/lms-gunicorn-${_BENCH_ID}-$$.conf.py"
  _S12_UNIT_REMOTE="/tmp/lms-unit-${_BENCH_ID}-$$.service"

  cat > "${_S12_GUNICORN_CONF_LOCAL}" <<GCONF
bind = "127.0.0.1:${LMS_GUNICORN_PORT}"
workers = 4
timeout = 120
graceful_timeout = 30
GCONF

  cat > "${_S12_UNIT_LOCAL}" <<UNIT_EOF
[Unit]
Description=LMS Gunicorn (${_BENCH_ID}) on port ${LMS_GUNICORN_PORT}
After=network.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
User=${LMS_FRAPPE_USER}
Group=${LMS_FRAPPE_USER}
WorkingDirectory=${LMS_FRAPPE_BENCH_DIR}
Environment=HOME=/home/${LMS_FRAPPE_USER}
Environment=SITES_PATH=${LMS_FRAPPE_BENCH_DIR}/sites
Environment=FRAPPE_SITE_NAME_HEADER=${LMS_FRAPPE_SITE}
Environment=BENCH_PATH=${LMS_FRAPPE_BENCH_DIR}
ExecStart=${LMS_FRAPPE_BENCH_DIR}/env/bin/gunicorn \
  --chdir ${LMS_FRAPPE_BENCH_DIR} \
  -c ${LMS_FRAPPE_BENCH_DIR}/gunicorn.conf.py \
  frappe.app:application
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF

  if ! $LMS_DRY_RUN; then
    scp ${SCP_OPTS} "${_S12_GUNICORN_CONF_LOCAL}" "${TARGET}:${_S12_GUNICORN_CONF_REMOTE}"
    scp ${SCP_OPTS} "${_S12_UNIT_LOCAL}" "${TARGET}:${_S12_UNIT_REMOTE}"
  else
    info "DRY RUN: would scp gunicorn conf and unit files to remote"
  fi
  rm -f "${_S12_GUNICORN_CONF_LOCAL}" "${_S12_UNIT_LOCAL}"

  run_remote_heredoc "Install gunicorn conf and ${_SERVICE_NAME} systemd unit" "
mv '${_S12_GUNICORN_CONF_REMOTE}' '${LMS_FRAPPE_BENCH_DIR}/gunicorn.conf.py'
chown ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} '${LMS_FRAPPE_BENCH_DIR}/gunicorn.conf.py'

mv '${_S12_UNIT_REMOTE}' '${_SYSTEMD_UNIT}'
chown root:root '${_SYSTEMD_UNIT}'
chmod 644 '${_SYSTEMD_UNIT}'
systemctl daemon-reload
systemctl enable ${_SERVICE_NAME}
echo 'Service unit written: ${_SERVICE_NAME}.service'
"

  _restart_lms_app_with_diagnostics

  success "Gunicorn service configured [${_BENCH_ID}]"
  _deploy_log "Step 12 complete"
fi

if step_enabled 13; then
  header "Step 13 — Start Frappe workers [${_BENCH_ID}]"
  _deploy_log "Step 13: start workers"

  run_remote_heredoc "Fix asset manifest permissions [${_BENCH_ID}]" "
set +e
chmod -R o+rX '${LMS_FRAPPE_BENCH_DIR}/sites/assets' 2>/dev/null || true
chmod -R o+rX '${LMS_FRAPPE_BENCH_DIR}/apps/frappe/frappe/public' 2>/dev/null || true
find '${LMS_FRAPPE_BENCH_DIR}/sites/assets' -name 'manifest.json' -exec chmod o+r {} + 2>/dev/null || true
echo 'Asset permissions fixed'
"

  _PY_STRIP13_LOCAL=$(mktemp /tmp/lms-strip13-XXXXXX.py)
  _PY_STRIP13_REMOTE="/tmp/lms-strip13-${_BENCH_ID}-$$.py"

  cat > "${_PY_STRIP13_LOCAL}" <<'PYEOF13'
import re, pathlib, sys
conf = sys.argv[1]
p = pathlib.Path(conf)
t = p.read_text()
t = re.sub(r'\[(?:program|group):[^\]]*redis[^\]]*\][^\[]*', '', t, flags=re.DOTALL|re.IGNORECASE)
t = re.sub(r'(?m)^programs\s*=.*redis.*\n', '', t, flags=re.IGNORECASE)
p.write_text(t)
print('Stripped.')
PYEOF13

  if ! $LMS_DRY_RUN; then
    scp ${SCP_OPTS} "${_PY_STRIP13_LOCAL}" "${TARGET}:${_PY_STRIP13_REMOTE}"
  else
    info "DRY RUN: would scp strip13 python script to remote"
  fi
  rm -f "${_PY_STRIP13_LOCAL}"

  run_remote_heredoc "Verify supervisor config is clean then start LMS workers [${_BENCH_ID}]" "
set +e

_conf='/etc/supervisor/conf.d/${_SUPERVISOR_CONF_NAME}.conf'
if [[ ! -f \"\${_conf}\" ]]; then
  echo 'ERROR: supervisor config missing' >&2
  exit 1
fi

if grep -qi 'redis' \"\${_conf}\"; then
  echo 'WARNING: redis references still present — stripping now'
  python3 '${_PY_STRIP13_REMOTE}' \"\${_conf}\"
fi
rm -f '${_PY_STRIP13_REMOTE}' 2>/dev/null || true

supervisorctl reread 2>&1 || true
supervisorctl update 2>&1 || true

supervisorctl start '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl start '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true

sleep 8

echo '=== Supervisor status after start ==='
supervisorctl status 2>/dev/null || true

supervisorctl status '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null   && echo 'LMS web group: OK'   || echo 'WARNING: LMS web group not running'
"

  _ensure_all_log_dirs

  success "Frappe workers started [${_BENCH_ID}]"
  _deploy_log "Step 13 complete"
fi

if step_enabled 14; then
  header "Step 14 — Final restart + health check [${_BENCH_ID}]"
  _deploy_log "Step 14: final restart"

  run_remote_heredoc "Restart bench supervisor processes [${_BENCH_ID}]" "
set +e
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5
supervisorctl status 2>/dev/null || true
"

  LMS_WAIT 10
  _restart_lms_app_with_diagnostics
  LMS_WAIT 5
  do_status

  success "Final health check complete [${_BENCH_ID}]"
  _deploy_log "Step 14 complete"
fi

if step_enabled 15; then
  header "Step 15 — Firewall [${_BENCH_ID}]"
  _deploy_log "Step 15: firewall"

  if [[ "${LMS_OPEN_FIREWALL_PORT:-false}" == "true" ]]; then
    _FW_HTTP="$(_nginx_http_listen)"

    run_remote_heredoc "Open firewall ports [${_BENCH_ID}]" "
set +e
_open_port() {
  local port=\"\$1\"
  if command -v ufw &>/dev/null; then
    ufw allow \"\${port}\"/tcp 2>/dev/null || true
    echo \"ufw: opened \${port}\"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=\"\${port}\"/tcp 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    echo \"firewalld: opened \${port}\"
  else
    echo \"No local firewall found — open port \${port} in your cloud security group manually\"
  fi
}

_open_port ${_FW_HTTP}
${LMS_ENABLE_HTTPS} && _open_port ${LMS_NGINX_HTTPS_PORT}
"
    warn "Also open port ${_FW_HTTP} in your cloud NSG / security group."
    $LMS_ENABLE_HTTPS && warn "Also open port ${LMS_NGINX_HTTPS_PORT} (HTTPS) in your cloud NSG / security group."
    _deploy_log "Step 15 complete: opened ${_FW_HTTP}${LMS_ENABLE_HTTPS:+ and ${LMS_NGINX_HTTPS_PORT}}"
  else
    info "Step 15 — Skipping firewall (LMS_OPEN_FIREWALL_PORT=false)"
    _deploy_log "Step 15: skipped"
  fi
fi

ssh ${SSH_BASE_OPTS} -O exit "$TARGET" 2>/dev/null || true

echo ""
success "LMS deployment complete [${_BENCH_ID}]"
info "URL:      $(_effective_url)"
info "Login:    Administrator / ${LMS_FRAPPE_ADMIN_PASSWORD}"
info "Logs:     ${LMS_DEPLOY_LOG}"
$LMS_ENABLE_HTTPS && warn "HTTPS uses a self-signed cert — install a CA-signed cert for production."
echo ""