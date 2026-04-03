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

RAG_CONFIG_FILE="${RAG_CONFIG_FILE:-./tap-devops/config.env}"
RAG_DRY_RUN="${RAG_DRY_RUN:-false}"
RAG_STEPS="${RAG_STEPS:-}"
RAG_CLEAN="${RAG_CLEAN:-false}"
RAG_CLEAN_ONLY="${RAG_CLEAN_ONLY:-false}"
RAG_RESTART_ONLY="${RAG_RESTART_ONLY:-false}"
RAG_STOP_ONLY="${RAG_STOP_ONLY:-false}"
RAG_STATUS_ONLY="${RAG_STATUS_ONLY:-false}"
RAG_UPDATE_ONLY="${RAG_UPDATE_ONLY:-false}"
RAG_UPDATE_CONFIG="${RAG_UPDATE_CONFIG:-false}"
RAG_CLEAN_SERVICES="${RAG_CLEAN_SERVICES:-false}"
RAG_CLEAN_BENCH="${RAG_CLEAN_BENCH:-false}"
RAG_FORCE="${RAG_FORCE:-false}"
RAG_VERBOSE="${RAG_VERBOSE:-false}"
RAG_NO_WAIT="${RAG_NO_WAIT:-false}"
RAG_DEPLOY_DOMAIN="${RAG_DEPLOY_DOMAIN:-false}"
RAG_TLS_CERT="${RAG_TLS_CERT:-}"
RAG_TLS_KEY="${RAG_TLS_KEY:-}"
RAG_ENABLE_HTTPS="${RAG_ENABLE_HTTPS:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)           RAG_CONFIG_FILE="$2"; shift 2 ;;
    --dry-run)          RAG_DRY_RUN=true; shift ;;
    --steps)            RAG_STEPS="$2"; shift 2 ;;
    --clean)            RAG_CLEAN=true; RAG_FORCE=true; shift ;;
    --clean-only)       RAG_CLEAN=true; RAG_CLEAN_ONLY=true; RAG_FORCE=true; shift ;;
    --restart)          RAG_RESTART_ONLY=true; shift ;;
    --stop)             RAG_STOP_ONLY=true; shift ;;
    --status)           RAG_STATUS_ONLY=true; shift ;;
    --update)           RAG_UPDATE_ONLY=true; shift ;;
    --update-config)    RAG_UPDATE_CONFIG=true; shift ;;
    --clean-services)   RAG_CLEAN_SERVICES=true; shift ;;
    --clean-bench)      RAG_CLEAN_BENCH=true; RAG_FORCE=true; shift ;;
    --force)            RAG_FORCE=true; shift ;;
    --verbose)          RAG_VERBOSE=true; shift ;;
    --no-wait)          RAG_NO_WAIT=true; shift ;;
    --deploy-to-domain) RAG_DEPLOY_DOMAIN=true; shift ;;
    --enable-https)     RAG_ENABLE_HTTPS=true; shift ;;
    --help)
      cat <<'HELP'
Usage: setup-rag.sh [--config FILE] [OPTIONS]

Deployment modes:
  (no flags)          Full fresh deploy (steps 1-18)
  --update            git pull + bench migrate + restart
  --update-config     Sync Python deps, site config, and DB settings then restart
  --restart           Restart all RAG services
  --stop              Stop all RAG services
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
  --config FILE       Path to config.env
  --dry-run           Print SSH commands without executing
  --force             Skip confirmation prompts
  --verbose           Enable set -x on remote scripts
  --no-wait           Skip sleep delays
  --deploy-to-domain  Serve via nginx on RAG_NGINX_PORT using RAG_DOMAIN_NAME
  --enable-https      Configure HTTPS

Required config vars:
  RAG_SERVER_USER  RAG_SERVER_HOST  RAG_SSH_KEY_PATH
  RAG_GIT_REPO  RAG_GIT_BRANCH
  RAG_POSTGRES_PASSWORD
  RAG_FRAPPE_BENCH_DIR  RAG_FRAPPE_SITE  RAG_FRAPPE_USER  RAG_FRAPPE_ADMIN_PASSWORD
  RAG_DEPLOY_SECRET_KEY  RAG_TAP_RAG_DIR  RAG_VENV_NAME

LLM config:
  RAG_LLM_PROVIDER    groq | openai | anthropic | together ai | custom
  RAG_LLM_MODEL       e.g. meta-llama/llama-4-scout-17b-16e-instruct
  RAG_LLM_API_KEY     your provider API key
  RAG_OPENAI_API_KEY  legacy alias accepted if RAG_LLM_API_KEY not set
HELP
      exit 0 ;;
    *) die "Unknown argument: $1. Use --help for usage." ;;
  esac
done

[[ -f "$RAG_CONFIG_FILE" ]] || die "Config file not found: $RAG_CONFIG_FILE"
source "$RAG_CONFIG_FILE"
success "Loaded config: $RAG_CONFIG_FILE"

RAG_LOG_DIR="${RAG_LOG_DIR:-./tap-devops/logs}"
RAG_LOG_MAX_MB="${RAG_LOG_MAX_MB:-10}"
RAG_LOG_BACKUP_COUNT="${RAG_LOG_BACKUP_COUNT:-5}"
RAG_SSH_PORT="${RAG_SSH_PORT:-22}"
RAG_PG_HOST="${RAG_PG_HOST:-127.0.0.1}"
RAG_PG_PORT="${RAG_PG_PORT:-5435}"
RAG_PYTHON_VERSION="${RAG_PYTHON_VERSION:-python3.10}"
RAG_FRAPPE_BRANCH="${RAG_FRAPPE_BRANCH:-version-14}"
RAG_BUSINESS_THEME_BRANCH="${RAG_BUSINESS_THEME_BRANCH:-main}"
RAG_NODE_VERSION="${RAG_NODE_VERSION:-16.15.0}"

RAG_LLM_PROVIDER="${RAG_LLM_PROVIDER:-openai}"
RAG_LLM_MODEL="${RAG_LLM_MODEL:-gpt-4o-mini}"
RAG_LLM_TEMPERATURE="${RAG_LLM_TEMPERATURE:-0.7}"
RAG_LLM_MAX_TOKENS="${RAG_LLM_MAX_TOKENS:-2000}"
RAG_LLM_API_KEY="${RAG_LLM_API_KEY:-${RAG_OPENAI_API_KEY:-}}"

_LLM_PROVIDER_NORM="$(echo "${RAG_LLM_PROVIDER}" | tr '[:upper:]' '[:lower:]' | xargs)"

_map_provider_to_doctype_value() {
  local p="$1"
  case "$p" in
    openai)      echo "OpenAI" ;;
    anthropic)   echo "Anthropic" ;;
    "together ai"|togetherai|together_ai) echo "Together AI" ;;
    groq|*)      echo "Custom" ;;
  esac
}

_LLM_DOCTYPE_PROVIDER="$(_map_provider_to_doctype_value "${_LLM_PROVIDER_NORM}")"

RAG_RABBITMQ_HOST="${RAG_RABBITMQ_HOST:-127.0.0.1}"
RAG_RABBITMQ_PORT="${RAG_RABBITMQ_PORT:-5673}"
RAG_RABBITMQ_MANAGEMENT_PORT="${RAG_RABBITMQ_MANAGEMENT_PORT:-15673}"
RAG_RABBITMQ_USER="${RAG_RABBITMQ_USER:-raguser}"
RAG_RABBITMQ_PASSWORD="${RAG_RABBITMQ_PASSWORD:-ragpass}"
RAG_RABBITMQ_VHOST="${RAG_RABBITMQ_VHOST:-/}"
RAG_REDIS_CACHE_PORT="${RAG_REDIS_CACHE_PORT:-13100}"
RAG_REDIS_QUEUE_PORT="${RAG_REDIS_QUEUE_PORT:-11100}"
RAG_REDIS_MAXMEMORY="${RAG_REDIS_MAXMEMORY:-256mb}"
RAG_REDIS_MAXMEMORY_POLICY="${RAG_REDIS_MAXMEMORY_POLICY:-allkeys-lru}"
RAG_NGINX_PORT="${RAG_NGINX_PORT:-80}"
RAG_NGINX_HTTPS_PORT="${RAG_NGINX_HTTPS_PORT:-443}"
RAG_API_PORT="${RAG_API_PORT:-8009}"
RAG_NGINX_MAX_BODY_MB="${RAG_NGINX_MAX_BODY_MB:-50}"
RAG_NGINX_PROXY_TIMEOUT="${RAG_NGINX_PROXY_TIMEOUT:-60}"
RAG_DOMAIN_NAME="${RAG_DOMAIN_NAME:-}"
RAG_OPEN_FIREWALL_PORT="${RAG_OPEN_FIREWALL_PORT:-false}"
RAG_SERVICE_OWNER="${RAG_SERVICE_OWNER:-${RAG_SERVER_USER}}"
RAG_FRAPPE_SHORT_WORKERS="${RAG_FRAPPE_SHORT_WORKERS:-1}"
RAG_FRAPPE_LONG_WORKERS="${RAG_FRAPPE_LONG_WORKERS:-1}"
RAG_NVM_INSTALL_URL="${RAG_NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh}"
RAG_BUSINESS_THEME_REPO="${RAG_BUSINESS_THEME_REPO:-https://github.com/Midocean-Technologies/business_theme_v14.git}"
RAG_LANGCHAIN_VERSION="${RAG_LANGCHAIN_VERSION:-0.2.16}"
RAG_LANGCHAIN_CORE_VERSION="${RAG_LANGCHAIN_CORE_VERSION:-0.2.43}"
RAG_LANGCHAIN_OPENAI_VERSION="${RAG_LANGCHAIN_OPENAI_VERSION:-0.1.25}"
RAG_LANGCHAIN_COMMUNITY_VERSION="${RAG_LANGCHAIN_COMMUNITY_VERSION:-0.2.17}"
RAG_LANGCHAIN_TEXTSPLIT_VERSION="${RAG_LANGCHAIN_TEXTSPLIT_VERSION:-0.2.4}"
RAG_LANGSMITH_VERSION="${RAG_LANGSMITH_VERSION:-0.1.17}"
RAG_TLS_CERT="${RAG_TLS_CERT:-/etc/ssl/rag/rag.crt}"
RAG_TLS_KEY="${RAG_TLS_KEY:-/etc/ssl/rag/rag.key}"
RAG_VENV_NAME="${RAG_VENV_NAME:-rag-env}"

REQUIRED_VARS=(
  RAG_SERVER_USER RAG_SERVER_HOST RAG_SSH_KEY_PATH
  RAG_GIT_REPO RAG_GIT_BRANCH
  RAG_POSTGRES_PASSWORD
  RAG_FRAPPE_BENCH_DIR RAG_FRAPPE_SITE RAG_FRAPPE_USER RAG_FRAPPE_ADMIN_PASSWORD
  RAG_DEPLOY_SECRET_KEY RAG_TAP_RAG_DIR RAG_VENV_NAME
)
for v in "${REQUIRED_VARS[@]}"; do
  [[ -n "${!v:-}" ]] || die "Required config var \$$v not set in $RAG_CONFIG_FILE"
done

_BENCH_ID=$(basename "${RAG_FRAPPE_BENCH_DIR}")

RAG_POSTGRES_CONTAINER="${RAG_POSTGRES_CONTAINER:-rag-${_BENCH_ID}-postgres}"
RAG_REDIS_CACHE_CONTAINER="${RAG_REDIS_CACHE_CONTAINER:-rag-${_BENCH_ID}-redis-cache}"
RAG_REDIS_QUEUE_CONTAINER="${RAG_REDIS_QUEUE_CONTAINER:-rag-${_BENCH_ID}-redis-queue}"
RAG_RABBITMQ_CONTAINER="${RAG_RABBITMQ_CONTAINER:-rag-${_BENCH_ID}-rabbitmq}"
RAG_POSTGRES_IMAGE="${RAG_POSTGRES_IMAGE:-docker.io/ankane/pgvector:latest}"
RAG_REDIS_IMAGE="${RAG_REDIS_IMAGE:-docker.io/library/redis:7-alpine}"
RAG_RABBITMQ_IMAGE="${RAG_RABBITMQ_IMAGE:-docker.io/library/rabbitmq:3-management-alpine}"

_SUPERVISOR_CONF_NAME="rag-bench-${_BENCH_ID}"
_NGINX_CONF_NAME="rag-bench-${_BENCH_ID}"
_SERVICE_NAME="rag-app-${_BENCH_ID}"
_WRAPPER_SCRIPT="/usr/local/bin/rag-app-${_BENCH_ID}"
_SYSTEMD_UNIT="/etc/systemd/system/${_SERVICE_NAME}.service"

_SITES_DIR="${RAG_FRAPPE_BENCH_DIR}/sites"
_SITE_DIR="${_SITES_DIR}/${RAG_FRAPPE_SITE}"
_SITE_LOGS_DIR="${_SITE_DIR}/logs"
_BENCH_LOGS_DIR="${RAG_FRAPPE_BENCH_DIR}/logs"
_SITE_LOGS_ALT="${RAG_FRAPPE_BENCH_DIR}/${RAG_FRAPPE_SITE}/logs"

if $RAG_DEPLOY_DOMAIN; then
  [[ -n "${RAG_DOMAIN_NAME:-}" ]] || die "--deploy-to-domain requires RAG_DOMAIN_NAME"
fi
if $RAG_ENABLE_HTTPS && ! $RAG_DEPLOY_DOMAIN; then
  [[ -n "${RAG_DOMAIN_NAME:-}" ]] || die "--enable-https requires RAG_DOMAIN_NAME"
  RAG_DEPLOY_DOMAIN=true
fi

mkdir -p "${RAG_LOG_DIR}"

_rotate_log() {
  local logfile="$1"
  local max_bytes=$(( RAG_LOG_MAX_MB * 1024 * 1024 ))
  local actual_size=0
  [[ -f "$logfile" ]] && actual_size=$(stat -c%s "$logfile" 2>/dev/null || echo 0)
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

RAG_DEPLOY_LOG="${RAG_LOG_DIR}/rag-deploy-${_BENCH_ID}.log"
RAG_APPID_LOG="${RAG_LOG_DIR}/rag-appid-deploy-${_BENCH_ID}.log"
_deploy_log() { _log_to_file "$RAG_DEPLOY_LOG" "$*"; }
_appid_log()  { _log_to_file "$RAG_APPID_LOG"  "$*"; }
_tee_deploy_log() {
  while IFS= read -r line; do
    echo "$line"
    _log_to_file "$RAG_DEPLOY_LOG" "$line"
  done
}

SSH_CTRL_PATH="/tmp/rag-ssh-${_BENCH_ID}-${RAG_SERVER_USER}@${RAG_SERVER_HOST}:${RAG_SSH_PORT}"
_SC="${RAG_SSH_ACCEPT_NEW:-false}"
_STRICT_OPT="StrictHostKeyChecking=yes"
$_SC && _STRICT_OPT="StrictHostKeyChecking=accept-new"

SSH_BASE_OPTS="-i ${RAG_SSH_KEY_PATH} -p ${RAG_SSH_PORT} \
  -o ${_STRICT_OPT} \
  -o ConnectTimeout=15 \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=10 \
  -o ControlMaster=auto \
  -o ControlPath=${SSH_CTRL_PATH} \
  -o ControlPersist=120"
SCP_OPTS="-i ${RAG_SSH_KEY_PATH} -P ${RAG_SSH_PORT} \
  -o ${_STRICT_OPT} \
  -o ConnectTimeout=15 \
  -o ControlMaster=auto \
  -o ControlPath=${SSH_CTRL_PATH} \
  -o ControlPersist=120"
TARGET="${RAG_SERVER_USER}@${RAG_SERVER_HOST}"

_ssh_master_up() {
  ssh ${SSH_BASE_OPTS} -O check "$TARGET" 2>/dev/null && return 0
  ssh ${SSH_BASE_OPTS} -fN "$TARGET" 2>/dev/null || true
  sleep 1
}

_effective_url() {
  if $RAG_ENABLE_HTTPS; then
    echo "https://${RAG_DOMAIN_NAME}/"
  elif $RAG_DEPLOY_DOMAIN; then
    echo "http://${RAG_DOMAIN_NAME}/"
  else
    echo "http://${RAG_SERVER_HOST}:${RAG_API_PORT}/"
  fi
}

_nginx_http_listen() {
  $RAG_DEPLOY_DOMAIN && echo "${RAG_NGINX_PORT}" || echo "${RAG_API_PORT}"
}

_nginx_server_name() {
  $RAG_DEPLOY_DOMAIN && echo "${RAG_DOMAIN_NAME}" || echo "_"
}

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

RAG_WAIT() { $RAG_NO_WAIT && return 0; sleep "$1"; }

run_remote() {
  local desc="$1"; shift
  info "Remote: $desc"
  _deploy_log "Remote: $desc"
  if $RAG_DRY_RUN; then echo -e "  ${YELLOW}$ $*${RESET}"; return 0; fi
  ssh ${SSH_BASE_OPTS} "$TARGET" "$@" 2>&1 | _tee_deploy_log
}

run_remote_heredoc() {
  local desc="$1" body="$2"
  info "Remote: $desc"
  _deploy_log "Remote: $desc"
  if $RAG_DRY_RUN; then echo -e "  ${YELLOW}[heredoc: $desc]${RESET}"; return 0; fi
  local flags="set -euo pipefail"
  $RAG_VERBOSE && flags="${flags}; set -x"
  ssh ${SSH_BASE_OPTS} "$TARGET" "sudo bash --login -s" 2>&1 <<EOF | _tee_deploy_log
${flags}
${body}
EOF
}

run_remote_as_frappe() {
  local desc="$1" body="$2"
  info "Remote (${RAG_FRAPPE_USER}): $desc"
  _deploy_log "Remote (${RAG_FRAPPE_USER}): $desc"
  if $RAG_DRY_RUN; then echo -e "  ${YELLOW}[frappe heredoc: $desc]${RESET}"; return 0; fi
  local preamble="
export HOME=/home/${RAG_FRAPPE_USER}
export NVM_DIR=\"/home/${RAG_FRAPPE_USER}/.nvm\"
[[ -s \"\${NVM_DIR}/nvm.sh\" ]] && source \"\${NVM_DIR}/nvm.sh\"
nvm use ${RAG_NODE_VERSION} 2>/dev/null || true
export PATH=\"\${HOME}/.local/bin:\${HOME}/.nvm/versions/node/v${RAG_NODE_VERSION}/bin:\${PATH}\"
hash -r 2>/dev/null || true
cd ${RAG_FRAPPE_BENCH_DIR} 2>/dev/null || cd \${HOME}
"
  local flags="set -euo pipefail"
  $RAG_VERBOSE && flags="${flags}; set -x"
  ssh ${SSH_BASE_OPTS} "$TARGET" "sudo -H -u ${RAG_FRAPPE_USER} bash --login -s" 2>&1 <<EOF | _tee_deploy_log
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
  local preamble="
export HOME=/home/${RAG_SERVICE_OWNER}
_uid=\$(id -u)
export XDG_RUNTIME_DIR=/run/user/\${_uid}
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${_uid}/bus
loginctl enable-linger \$(whoami) 2>/dev/null || true
"
  local flags="set -euo pipefail"
  $RAG_VERBOSE && flags="${flags}; set -x"
  ssh ${SSH_BASE_OPTS} "$TARGET" "sudo -H -u ${RAG_SERVICE_OWNER} bash --login -s" 2>&1 <<EOF | _tee_deploy_log
${preamble}
${flags}
${body}
EOF
}

_ensure_all_log_dirs() {
  run_remote_heredoc "Ensure all site log directories exist [${_BENCH_ID}]" "
set +e
for _d in \
  '/home/${RAG_FRAPPE_USER}/logs' \
  '${_BENCH_LOGS_DIR}' \
  '${_SITES_DIR}/logs' \
  '${_SITE_LOGS_DIR}' \
  '${_SITE_LOGS_ALT}'; do
  mkdir -p \"\${_d}\"
  chown -R ${RAG_FRAPPE_USER}:${RAG_FRAPPE_USER} \"\${_d}\" 2>/dev/null || true
  chmod 755 \"\${_d}\"
done
chmod o+rx '/home/${RAG_FRAPPE_USER}' 2>/dev/null || true
chmod o+rx '${RAG_FRAPPE_BENCH_DIR}' 2>/dev/null || true
chmod o+rx '${_SITES_DIR}' 2>/dev/null || true
[[ -f '${_SITE_DIR}/site_config.json' ]] \
  && chmod o+r '${_SITE_DIR}/site_config.json' 2>/dev/null || true
echo 'All log dirs ensured'
"
}

_write_pgpass_remote() {
  run_remote_heredoc "Write .pgpass for all postgres users [${_BENCH_ID}]" "
set +e

PGLINE_SU='${RAG_PG_HOST}:${RAG_PG_PORT}:*:postgres:${RAG_POSTGRES_PASSWORD}'

_write_pgpass_for_user() {
  local home_dir=\"\$1\"
  local owner=\"\$2\"
  local pgpass=\"\${home_dir}/.pgpass\"

  echo \"\${PGLINE_SU}\" > \"\${pgpass}\"

  if [[ -f '${_SITE_DIR}/site_config.json' ]]; then
    _db_name=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_name',''))\" 2>/dev/null || true)
    _db_pass=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_password',''))\" 2>/dev/null || true)
    if [[ -n \"\${_db_name}\" && -n \"\${_db_pass}\" ]]; then
      echo '${RAG_PG_HOST}:${RAG_PG_PORT}:*:'\"\${_db_name}\"':'\"\${_db_pass}\" >> \"\${pgpass}\"
      echo \"Added site DB entry for \${_db_name} to \${pgpass}\"
    fi
  fi

  chown \"\${owner}\":\"\${owner}\" \"\${pgpass}\"
  chmod 600 \"\${pgpass}\"
  echo \"Written: \${pgpass}\"
}

_write_pgpass_for_user '/root'                       'root'
_write_pgpass_for_user '/home/${RAG_FRAPPE_USER}'    '${RAG_FRAPPE_USER}'

if [[ '${RAG_SERVICE_OWNER}' != '${RAG_FRAPPE_USER}' ]]; then
  _write_pgpass_for_user '/home/${RAG_SERVICE_OWNER}' '${RAG_SERVICE_OWNER}'
fi
echo '.pgpass update complete'
"
}

_patch_source_imports() {
  run_remote_heredoc "Patch langchain.schema imports in source files only [${_BENCH_ID}]" "
set +e
for search_dir in \
  '${RAG_FRAPPE_BENCH_DIR}/apps/rag_service' \
  '${RAG_TAP_RAG_DIR}'; do
  [[ -d \"\${search_dir}\" ]] || continue
  while IFS= read -r -d '' f; do
    if grep -q 'langchain\.schema' \"\${f}\" 2>/dev/null; then
      echo \"Patching: \${f}\"
      sed -i \
        's|from langchain\.schema import HumanMessage.*|from langchain_core.messages import HumanMessage, SystemMessage|g' \
        \"\${f}\"
      sed -i \
        's|from langchain\.schema\.messages import|from langchain_core.messages import|g' \
        \"\${f}\"
      sed -i \
        's|from langchain\.schema import|from langchain_core.messages import|g' \
        \"\${f}\"
    fi
  done < <(find \"\${search_dir}\" -name '*.py' -not -path '*/site-packages/*' -print0 2>/dev/null)
done
echo 'Source import patches applied'
"
}

_write_consumer_script() {
  run_remote_heredoc "Rewrite consumer.py in all locations [${_BENCH_ID}]" "
set +e

_write_consumer() {
  local path=\"\$1\"
  [[ -f \"\${path}\" ]] || return 0
  echo \"Rewriting: \${path}\"
  cat > \"\${path}\" <<'CONSUMER_EOF'
import os
import sys
import time
import traceback

os.environ['HOME'] = '/home/${RAG_FRAPPE_USER}'

os.chdir('${RAG_FRAPPE_BENCH_DIR}')

sys.path.insert(0, '${RAG_FRAPPE_BENCH_DIR}/apps/frappe')
sys.path.insert(0, '${RAG_FRAPPE_BENCH_DIR}/apps/rag_service')
sys.path.insert(0, '${RAG_TAP_RAG_DIR}')

for _log_dir in [
    '${_SITE_LOGS_ALT}',
    '${_SITE_LOGS_DIR}',
    '${_BENCH_LOGS_DIR}',
    '/home/${RAG_FRAPPE_USER}/logs',
]:
    os.makedirs(_log_dir, exist_ok=True)

import frappe

frappe.init(
    site='${RAG_FRAPPE_SITE}',
    sites_path='${_SITES_DIR}',
)

for _log_dir in [
    os.path.join(frappe.local.site_path, 'logs'),
    '${_SITE_LOGS_ALT}',
    '${_SITE_LOGS_DIR}',
]:
    os.makedirs(_log_dir, exist_ok=True)

frappe.connect()

def _wait_for_doctype(dt, attempts=20, delay=5):
    for i in range(attempts):
        try:
            result = frappe.db.sql(
                'SELECT name FROM "tabDocType" WHERE name=%s', [dt], as_dict=True
            )
            if result:
                return True
        except Exception:
            pass
        print(f'Waiting for {dt} schema ({i+1}/{attempts})...', flush=True)
        frappe.db.close()
        time.sleep(delay)
        frappe.connect()
    return False

if not _wait_for_doctype('RabbitMQ Settings'):
    print('FATAL: RabbitMQ Settings DocType never appeared — aborting', flush=True)
    sys.exit(1)

print('RabbitMQ Settings DocType found — starting consumer loop', flush=True)

while True:
    try:
        from rag_service.utils.rabbitmq_consumer import RabbitMQConsumer
        consumer = RabbitMQConsumer(debug=True)
        if consumer.test_connection():
            print('RabbitMQ connection OK — starting consuming', flush=True)
            consumer.start_consuming()
        else:
            print('RabbitMQ connection test failed — retrying in 15s', flush=True)
    except Exception as exc:
        exc_str = str(exc)
        if 'Password not found' in exc_str or 'api_secret' in exc_str or 'api_key' in exc_str:
            print('RAG Settings not configured yet — waiting for API key setup (retrying in 30s)', flush=True)
            time.sleep(30)
        else:
            print(f'Consumer error: {exc}', flush=True)
            traceback.print_exc()
            time.sleep(15)
    try:
        frappe.db.close()
        frappe.connect()
    except Exception:
        pass
CONSUMER_EOF
}

_write_consumer '${RAG_TAP_RAG_DIR}/rag_service/scripts/consumer.py'
_write_consumer '${RAG_FRAPPE_BENCH_DIR}/apps/rag_service/rag_service/scripts/consumer.py'

echo 'consumer.py rewrite complete'
"
}

_restart_rag_app_with_diagnostics() {
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
    echo \"rag-app: active after \${waited}s\"
    break
  fi
  if [[ \"\${state}\" == 'failed' ]]; then
    systemctl reset-failed ${_SERVICE_NAME} 2>/dev/null || true
    sleep 3
    systemctl start ${_SERVICE_NAME} 2>/dev/null || true
  fi
  echo \"rag-app: \${state} [\${i}/10]\"
  sleep 3
  waited=\$(( waited + 3 ))
done

echo 'Waiting 15s grace period to detect post-start crashes...'
sleep 15

final=\$(systemctl is-active ${_SERVICE_NAME} 2>/dev/null || echo unknown)
echo \"rag-app final state: \${final}\"
systemctl status ${_SERVICE_NAME} --no-pager -l || true
echo '--- Last 80 journal lines ---'
journalctl -u ${_SERVICE_NAME} -n 80 --no-pager 2>/dev/null || true
"
}

_install_python_deps() {
  run_remote_heredoc "Install all Python dependencies into bench venv [${_BENCH_ID}]" "
set +e
FRAPPE_PIP=${RAG_FRAPPE_BENCH_DIR}/env/bin/pip
FRAPPE_PYTHON=${RAG_FRAPPE_BENCH_DIR}/env/bin/python3

echo '=== Upgrading pip/setuptools/wheel ==='
sudo -u ${RAG_FRAPPE_USER} \${FRAPPE_PIP} install --quiet --upgrade \
  pip setuptools wheel 2>&1 | tail -2

echo '=== Installing core dependencies ==='
sudo -u ${RAG_FRAPPE_USER} \${FRAPPE_PIP} install --quiet \
  'packaging>=23.2,<25' \
  pika \
  'aiohttp>=3.8,<4' \
  python-dotenv \
  'openai>=1.10.0,<2.0' \
  'tiktoken>=0.5.0' \
  'httpx>=0.23.0,<0.28' \
  'pydantic>=1.10,<3' \
  'dataclasses-json>=0.5.7' \
  'marshmallow<4.0' \
  'jsonpatch<2' \
  'PyYAML>=5.3' \
  'requests>=2,<3' \
  'requests-toolbelt>=0.10.1' \
  'SQLAlchemy>=1.4,<3' \
  'numpy>=1,<2' \
  'orjson>=3.9,<4' \
  'groq>=0.9.0' \
  'langchain-groq>=0.1.6' \
  2>&1 | tail -5

echo '=== Installing LangChain suite at pinned versions ==='
sudo -u ${RAG_FRAPPE_USER} \${FRAPPE_PIP} install --quiet --no-deps \
  'langchain==${RAG_LANGCHAIN_VERSION}' \
  'langchain-core==${RAG_LANGCHAIN_CORE_VERSION}' \
  'langchain-openai==${RAG_LANGCHAIN_OPENAI_VERSION}' \
  'langchain-community==${RAG_LANGCHAIN_COMMUNITY_VERSION}' \
  'langchain-text-splitters==${RAG_LANGCHAIN_TEXTSPLIT_VERSION}' \
  'langsmith>=${RAG_LANGSMITH_VERSION},<0.2.0' \
  'tenacity>=8.1.0,<9.0.0' \
  2>&1 | tail -3

if [[ -f ${RAG_FRAPPE_BENCH_DIR}/apps/rag_service/requirements.txt ]]; then
  echo '=== Installing rag_service/requirements.txt ==='
  sudo -u ${RAG_FRAPPE_USER} \${FRAPPE_PIP} install --quiet --no-deps \
    -r ${RAG_FRAPPE_BENCH_DIR}/apps/rag_service/requirements.txt 2>&1 | tail -3
fi

if [[ -r ${RAG_TAP_RAG_DIR}/requirements.txt ]]; then
  echo '=== Installing tap_rag/requirements.txt ==='
  sudo -u ${RAG_FRAPPE_USER} \${FRAPPE_PIP} install --quiet --no-deps \
    -r ${RAG_TAP_RAG_DIR}/requirements.txt 2>&1 | tail -3
else
  echo 'tap_rag/requirements.txt not readable — skipping'
fi

echo '=== Final version pin enforcement ==='
sudo -u ${RAG_FRAPPE_USER} \${FRAPPE_PIP} install --quiet --no-deps --force-reinstall \
  'langchain==${RAG_LANGCHAIN_VERSION}' \
  'langchain-core==${RAG_LANGCHAIN_CORE_VERSION}' \
  'langchain-openai==${RAG_LANGCHAIN_OPENAI_VERSION}' \
  'langchain-community==${RAG_LANGCHAIN_COMMUNITY_VERSION}' \
  'langchain-text-splitters==${RAG_LANGCHAIN_TEXTSPLIT_VERSION}' \
  'langsmith>=${RAG_LANGSMITH_VERSION},<0.2.0' \
  'tenacity>=8.1.0,<9.0.0' \
  'packaging>=23.2,<25' \
  2>&1 | tail -3

echo '=== Verifying core imports ==='
sudo -u ${RAG_FRAPPE_USER} \${FRAPPE_PYTHON} - <<PYVERIFY
import sys
try:
    import pika, aiohttp, langchain, langchain_openai, dotenv, requests_toolbelt
    from langchain_core.messages import HumanMessage, SystemMessage
    print('All core imports OK')
    print('langchain:', langchain.__version__)
except Exception as e:
    print('FATAL import error:', e)
    sys.exit(1)
PYVERIFY
echo 'Python deps complete'
"
}

_seed_frappe_db() {
  _seed_script_local=$(mktemp /tmp/rag-seed-XXXXXX.py)
  _seed_script_remote="/tmp/rag-seed-${_BENCH_ID}-$$.py"

  _ensure_all_log_dirs

  cat > "${_seed_script_local}" <<SEEDEOF
import os, sys, logging, time

os.environ['HOME'] = '/home/${RAG_FRAPPE_USER}'

for _d in [
    '/home/${RAG_FRAPPE_USER}/logs',
    '${_BENCH_LOGS_DIR}',
    '${_SITES_DIR}/logs',
    '${_SITE_LOGS_DIR}',
    '${_SITE_LOGS_ALT}',
]:
    os.makedirs(_d, exist_ok=True)

logging.disable(logging.CRITICAL)
os.chdir('${RAG_FRAPPE_BENCH_DIR}')
sys.path.insert(0, '${RAG_FRAPPE_BENCH_DIR}/apps/frappe')
sys.path.insert(0, '${RAG_FRAPPE_BENCH_DIR}/apps/rag_service')

import frappe
frappe.init(site='${RAG_FRAPPE_SITE}', sites_path='${_SITES_DIR}')

for _d in [
    os.path.join(frappe.local.site_path, 'logs'),
    '${_SITE_LOGS_ALT}',
    '${_SITE_LOGS_DIR}',
]:
    os.makedirs(_d, exist_ok=True)

frappe.connect()

def _is_single(dt):
    try:
        r = frappe.db.sql('SELECT issingle FROM "tabDocType" WHERE name=%s', [dt], as_dict=True)
        return bool(r and r[0].get('issingle'))
    except Exception:
        return False

def _registered(dt):
    try:
        r = frappe.db.sql('SELECT name FROM "tabDocType" WHERE name=%s', [dt], as_dict=True)
        return bool(r)
    except Exception:
        return False

def _wait(dt, attempts=20, delay=5):
    for i in range(attempts):
        if _registered(dt):
            return True
        print(dt + ' not yet in DB, waiting (' + str(i+1) + '/' + str(attempts) + ')...', flush=True)
        frappe.db.close()
        time.sleep(delay)
        frappe.connect()
    return False

def _upsert_single(dt, field, val):
    rows = frappe.db.sql(
        'SELECT doctype FROM "tabSingles" WHERE doctype=%s AND field=%s', [dt, field], as_dict=True
    )
    if rows:
        frappe.db.sql(
            'UPDATE "tabSingles" SET value=%s WHERE doctype=%s AND field=%s', [val, dt, field]
        )
    else:
        frappe.db.sql(
            'INSERT INTO "tabSingles" (doctype, field, value) VALUES (%s,%s,%s)', [dt, field, val]
        )

def _seed_single(dt, fields):
    print('Seeding Single: ' + dt, flush=True)
    for k, v in fields.items():
        _upsert_single(dt, k, str(v) if v is not None else '')
    frappe.db.commit()
    print(dt + ' seeded via tabSingles', flush=True)

def _seed_regular(dt, filters, fields):
    existing = frappe.get_all(dt, filters=filters, limit=1)
    if existing:
        doc = frappe.get_doc(dt, existing[0].name)
        for k, v in fields.items():
            setattr(doc, k, v)
        doc.save(ignore_permissions=True)
    else:
        doc = frappe.get_doc({'doctype': dt})
        for k, v in fields.items():
            setattr(doc, k, v)
        doc.insert(ignore_permissions=True)
    frappe.db.commit()
    print(dt + ' saved: ' + doc.name, flush=True)

_llm_api_key = '${RAG_LLM_API_KEY}'
_llm_provider_raw = '${_LLM_PROVIDER_NORM}'
_llm_doctype_provider = '${_LLM_DOCTYPE_PROVIDER}'

if not _wait('LLM Settings'):
    print('LLM Settings not in DB — skipping')
else:
    if not _llm_api_key:
        print('No API key set — configure RAG_LLM_API_KEY and redeploy')
    else:
        try:
            llm = {
                'provider':    _llm_doctype_provider,
                'api_secret':  _llm_api_key,
                'model_name':  '${RAG_LLM_MODEL}',
                'temperature': str(float('${RAG_LLM_TEMPERATURE}')),
                'max_tokens':  str(int('${RAG_LLM_MAX_TOKENS}')),
                'is_active':   '1',
            }
            print('Seeding LLM Settings: provider=' + _llm_doctype_provider + ' (raw=' + _llm_provider_raw + ') model=${RAG_LLM_MODEL}', flush=True)
            _seed_single('LLM Settings', llm)
        except Exception as e:
            print('LLM Settings error: ' + str(e))

if not _wait('RabbitMQ Settings'):
    print('RabbitMQ Settings not in DB — skipping')
else:
    try:
        rmq = {
            'host':         '${RAG_RABBITMQ_HOST}',
            'port':         '${RAG_RABBITMQ_PORT}',
            'username':     '${RAG_RABBITMQ_USER}',
            'password':     '${RAG_RABBITMQ_PASSWORD}',
            'virtual_host': '${RAG_RABBITMQ_VHOST}',
        }
        if _is_single('RabbitMQ Settings'):
            _seed_single('RabbitMQ Settings', rmq)
        else:
            _seed_regular('RabbitMQ Settings', {}, rmq)
    except Exception as e:
        print('RabbitMQ Settings error: ' + str(e))

frappe.destroy()
print('Settings seed complete')
SEEDEOF

  if ! $RAG_DRY_RUN; then
    scp ${SCP_OPTS} "${_seed_script_local}" "${TARGET}:${_seed_script_remote}"
    rm -f "${_seed_script_local}"

    run_remote_heredoc "Grant site DB user and refresh .pgpass before seed [${_BENCH_ID}]" "
set +e
if [[ -f '${_SITE_DIR}/site_config.json' ]]; then
  _db_name=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_name',''))\" 2>/dev/null || true)
  _db_pass=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_password',''))\" 2>/dev/null || true)

  if [[ -n \"\${_db_name}\" && -n \"\${_db_pass}\" ]]; then
    echo \"Ensuring postgres role and password for site DB user: \${_db_name}\"
    psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres <<PGSQL
DO \\\$\\\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '\${_db_name}') THEN
    CREATE ROLE \"\${_db_name}\" WITH LOGIN PASSWORD '\${_db_pass}';
    RAISE NOTICE 'Created role %', '\${_db_name}';
  ELSE
    ALTER ROLE \"\${_db_name}\" WITH LOGIN PASSWORD '\${_db_pass}';
    RAISE NOTICE 'Updated password for role %', '\${_db_name}';
  END IF;
END
\\\$\\\$;
GRANT ALL PRIVILEGES ON DATABASE \"\${_db_name}\" TO \"\${_db_name}\";
PGSQL
    echo \"Postgres role ensured for \${_db_name}\"
  else
    echo 'Could not read db_name/db_password from site_config.json — skipping role grant'
  fi
else
  echo 'site_config.json not found — skipping role grant'
fi
"
    _write_pgpass_remote

    run_remote_heredoc "Wait for Frappe scheduler then run seed script [${_BENCH_ID}]" "
set +e
echo 'Waiting up to 60s for Frappe scheduler worker...'
_sw=0
while [[ \${_sw} -lt 20 ]]; do
  _sw=\$(( _sw + 1 ))
  _st=\$(supervisorctl status '${_SUPERVISOR_CONF_NAME}-workers:frappe-bench-frappe-schedule' 2>/dev/null \
        | awk '{print \$2}')
  [[ \"\${_st}\" == 'RUNNING' ]] && echo 'Frappe scheduler: RUNNING' && break
  echo \"Frappe scheduler: \${_st} [\${_sw}/20]\"
  sleep 3
done

chmod 600 '${_seed_script_remote}'
chown ${RAG_FRAPPE_USER}:${RAG_FRAPPE_USER} '${_seed_script_remote}'
sudo -H -u ${RAG_FRAPPE_USER} \
  HOME=/home/${RAG_FRAPPE_USER} \
  ${RAG_FRAPPE_BENCH_DIR}/env/bin/python3 '${_seed_script_remote}'
_exit=\$?
rm -f '${_seed_script_remote}'
exit \${_exit}
"
  else
    info "DRY RUN: would scp seed script and execute on remote"
    rm -f "${_seed_script_local}"
  fi
}

_ensure_tls_cert() {
  run_remote_heredoc "Ensure TLS certificate exists [${_BENCH_ID}]" "
set +e
mkdir -p /etc/ssl/rag
chmod 700 /etc/ssl/rag

if [[ -f '${RAG_TLS_CERT}' && -f '${RAG_TLS_KEY}' ]]; then
  echo 'Existing TLS cert/key found — skipping generation'
  openssl x509 -in '${RAG_TLS_CERT}' -noout -dates 2>/dev/null || true
else
  echo 'Generating self-signed certificate for ${RAG_DOMAIN_NAME:-${RAG_SERVER_HOST}}'
  openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
    -keyout '${RAG_TLS_KEY}' \
    -out '${RAG_TLS_CERT}' \
    -subj '/CN=${RAG_DOMAIN_NAME:-${RAG_SERVER_HOST}}/O=RAG/C=US' \
    -addext 'subjectAltName=DNS:${RAG_DOMAIN_NAME:-${RAG_SERVER_HOST}},IP:${RAG_SERVER_HOST}' \
    2>/dev/null
  chmod 600 '${RAG_TLS_KEY}'
  chmod 644 '${RAG_TLS_CERT}'
  echo 'Self-signed TLS cert generated (valid 10 years)'
fi
"
}

_build_nginx_conf() {
  local listen_http
  listen_http="$(_nginx_http_listen)"
  local server_name
  server_name="$(_nginx_server_name)"

  if $RAG_ENABLE_HTTPS; then
    cat <<NGINXCFG
server {
    listen ${listen_http};
    server_name ${server_name};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${RAG_NGINX_HTTPS_PORT} ssl;
    server_name ${server_name};
    client_max_body_size ${RAG_NGINX_MAX_BODY_MB}m;

    ssl_certificate     ${RAG_TLS_CERT};
    ssl_certificate_key ${RAG_TLS_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;

    location /assets {
        alias ${RAG_FRAPPE_BENCH_DIR}/sites/assets;
        try_files \$uri \$uri/ =404;
        expires 1d;
        add_header Cache-Control 'public';
    }

    location /files {
        alias ${_SITE_DIR}/public/files;
        try_files \$uri \$uri/ =404;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host ${RAG_FRAPPE_SITE};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_redirect off;
        proxy_read_timeout ${RAG_NGINX_PROXY_TIMEOUT}s;
        proxy_connect_timeout ${RAG_NGINX_PROXY_TIMEOUT}s;
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
    client_max_body_size ${RAG_NGINX_MAX_BODY_MB}m;

    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;

    location /assets {
        alias ${RAG_FRAPPE_BENCH_DIR}/sites/assets;
        try_files \$uri \$uri/ =404;
        expires 1d;
        add_header Cache-Control 'public';
    }

    location /files {
        alias ${_SITE_DIR}/public/files;
        try_files \$uri \$uri/ =404;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host ${RAG_FRAPPE_SITE};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_read_timeout ${RAG_NGINX_PROXY_TIMEOUT}s;
        proxy_connect_timeout ${RAG_NGINX_PROXY_TIMEOUT}s;
        proxy_buffering on;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
    }
}
NGINXCFG
  fi
}

do_stop() {
  header "Stop RAG [${_BENCH_ID}]"
  _deploy_log "Action: stop"
  run_remote_heredoc "Stop bench supervisor processes [${_BENCH_ID}]" "
set +e
supervisorctl stop '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl stop '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
echo 'bench processes stopped'
"
  run_remote_heredoc "Stop rag-app system service [${_BENCH_ID}]" "
set +e
systemctl stop ${_SERVICE_NAME} 2>/dev/null || true
echo 'rag-app stopped'
"
  success "RAG stopped [${_BENCH_ID}]"
  _deploy_log "RAG stopped"
}

do_restart() {
  header "Restart RAG [${_BENCH_ID}]"
  _deploy_log "Action: restart"
  run_remote_heredoc "Restart bench supervisor processes [${_BENCH_ID}]" "
set +e
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5
supervisorctl status 2>/dev/null || true
"
  _restart_rag_app_with_diagnostics
  success "RAG restarted [${_BENCH_ID}]"
  _deploy_log "RAG restarted"
}

do_status() {
  header "RAG Health Check [${_BENCH_ID}]"
  _deploy_log "Action: status"

  _status_listen_port="$(_nginx_http_listen)"
  $RAG_ENABLE_HTTPS && _status_listen_port="${RAG_NGINX_HTTPS_PORT}"

  run_remote_heredoc "Full RAG status [${_BENCH_ID}]" "
set +e
echo '=== Supervisor processes ==='
supervisorctl status 2>/dev/null | grep -E '${_SUPERVISOR_CONF_NAME}|^$' || echo 'supervisor not running'

echo ''
echo '=== System services ==='
for svc in nginx supervisor; do
  printf '  %-20s %s\n' \"\${svc}\" \"\$(systemctl is-active \${svc} 2>/dev/null || echo inactive)\"
done

echo ''
echo '=== Podman containers [${_BENCH_ID}] ==='
sudo -u ${RAG_SERVICE_OWNER} podman ps \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null \
  | grep -E '${_BENCH_ID}|^NAMES' || echo 'no matching containers found'

echo ''
echo '=== Redis [${_BENCH_ID}] ==='
redis-cli -h 127.0.0.1 -p ${RAG_REDIS_CACHE_PORT} ping 2>/dev/null | grep -q PONG \
  && echo 'redis-cache (${RAG_REDIS_CACHE_PORT}): OK' \
  || echo 'redis-cache (${RAG_REDIS_CACHE_PORT}): NOT RESPONDING'
redis-cli -h 127.0.0.1 -p ${RAG_REDIS_QUEUE_PORT} ping 2>/dev/null | grep -q PONG \
  && echo 'redis-queue (${RAG_REDIS_QUEUE_PORT}): OK' \
  || echo 'redis-queue (${RAG_REDIS_QUEUE_PORT}): NOT RESPONDING'

echo ''
echo '=== Postgres [${_BENCH_ID}] ==='
psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
  -c 'SELECT 1' >/dev/null 2>&1 \
  && echo 'postgres (${RAG_PG_HOST}:${RAG_PG_PORT}): OK' \
  || echo 'postgres (${RAG_PG_HOST}:${RAG_PG_PORT}): NOT RESPONDING'

echo ''
echo '=== Site DB user connectivity ==='
if [[ -f '${_SITE_DIR}/site_config.json' ]]; then
  _db_name=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_name',''))\" 2>/dev/null || true)
  _db_pass=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_password',''))\" 2>/dev/null || true)
  PGPASSWORD=\"\${_db_pass}\" psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} \
    -U \"\${_db_name}\" -d \"\${_db_name}\" -c 'SELECT 1' >/dev/null 2>&1 \
    && echo \"site DB user (\${_db_name}): OK\" \
    || echo \"site DB user (\${_db_name}): FAILED — run --update-config to fix\"
fi

echo ''
echo '=== Frappe bench HTTP [${_BENCH_ID}] ==='
curl -sf --max-time 10 -H 'Host: ${RAG_FRAPPE_SITE}' http://127.0.0.1:8000 -o /dev/null \
  && echo 'bench HTTP (8000): OK' || echo 'bench HTTP (8000): not responding'

echo ''
echo '=== External endpoint [${_BENCH_ID}] ==='
if ${RAG_ENABLE_HTTPS}; then
  curl -sf -k --max-time 10 https://127.0.0.1:${RAG_NGINX_HTTPS_PORT} -o /dev/null \
    && echo 'HTTPS endpoint (${RAG_NGINX_HTTPS_PORT}): OK' \
    || echo 'HTTPS endpoint (${RAG_NGINX_HTTPS_PORT}): not responding'
else
  curl -sf --max-time 10 http://127.0.0.1:${_status_listen_port} -o /dev/null \
    && echo 'HTTP endpoint (${_status_listen_port}): OK' \
    || echo 'HTTP endpoint (${_status_listen_port}): not responding'
fi

echo ''
echo '=== rag-app service [${_BENCH_ID}] ==='
systemctl status ${_SERVICE_NAME} --no-pager -l 2>/dev/null || echo 'rag-app service not found or not running'

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

  run_remote_as_owner "Stop and remove containers, volumes, and systemd units for bench ${_BENCH_ID}" "
set +e

systemctl stop ${_SERVICE_NAME} 2>/dev/null || true
systemctl disable ${_SERVICE_NAME} 2>/dev/null || true
rm -f ${_SYSTEMD_UNIT} 2>/dev/null || true
rm -f ${_WRAPPER_SCRIPT} 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

for container in \
  ${RAG_POSTGRES_CONTAINER} \
  ${RAG_REDIS_CACHE_CONTAINER} \
  ${RAG_REDIS_QUEUE_CONTAINER} \
  ${RAG_RABBITMQ_CONTAINER}; do
  podman stop \"\${container}\" 2>/dev/null || true
  podman rm -f \"\${container}\" 2>/dev/null || true
  echo \"Removed container: \${container}\"
done

for vol in \$(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^rag-${_BENCH_ID}' || true); do
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
  warn "  Bench dir:   ${RAG_FRAPPE_BENCH_DIR}"
  warn "  Site DB:     ${RAG_FRAPPE_SITE} (postgres)"
  warn "  Supervisor:  ${_SUPERVISOR_CONF_NAME}.conf"
  warn "  Nginx conf:  ${_NGINX_CONF_NAME}.conf"
  warn "  Systemd:     ${_SERVICE_NAME}"
  warn "  Containers:  ${RAG_POSTGRES_CONTAINER}, ${RAG_REDIS_CACHE_CONTAINER}, ${RAG_REDIS_QUEUE_CONTAINER}, ${RAG_RABBITMQ_CONTAINER}"
  warn "  Volumes:     all podman volumes prefixed rag-${_BENCH_ID}"
  warn "  Caches:      pip and uv caches"

  if ! $RAG_FORCE; then
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
supervisorctl stop 'frappe-bench-web:' 2>/dev/null || true
supervisorctl stop 'frappe-bench-workers:' 2>/dev/null || true

for _old_conf in \
  /etc/supervisor/conf.d/${_SUPERVISOR_CONF_NAME}.conf \
  /etc/supervisor/conf.d/frappe-bench*.conf; do
  [[ -f \"\${_old_conf}\" ]] || continue
  rm -f \"\${_old_conf}\"
  echo \"Removed supervisor config: \${_old_conf}\"
done

supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true

for _nc in \
  '/etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf' \
  '/etc/nginx/sites-enabled/${_NGINX_CONF_NAME}.conf'; do
  [[ -f \"\${_nc}\" ]] && rm -f \"\${_nc}\" && echo \"Removed nginx conf: \${_nc}\"
done
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true

_site_db=\$(echo '${RAG_FRAPPE_SITE}' | tr '.' '_' | tr '-' '_')
psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
  -c \"DROP DATABASE IF EXISTS \\\"\${_site_db}\\\";\" 2>/dev/null \
  && echo \"Dropped DB: \${_site_db}\" || echo 'DB drop failed or already gone'

[[ -d '${RAG_FRAPPE_BENCH_DIR}' ]] \
  && rm -rf '${RAG_FRAPPE_BENCH_DIR}' \
  && echo 'Removed bench dir: ${RAG_FRAPPE_BENCH_DIR}'

pip3 cache purge 2>/dev/null || true
uv cache clean 2>/dev/null || true
df -h /
echo 'Bench deep wipe complete.'
"

  run_remote_as_owner "Stop, disable, and remove all containers, volumes, and user units for bench ${_BENCH_ID}" "
set +e

systemctl stop ${_SERVICE_NAME} 2>/dev/null || true
systemctl disable ${_SERVICE_NAME} 2>/dev/null || true
rm -f ${_SYSTEMD_UNIT} 2>/dev/null || true
rm -f ${_WRAPPER_SCRIPT} 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

for container in \
  ${RAG_POSTGRES_CONTAINER} \
  ${RAG_REDIS_CACHE_CONTAINER} \
  ${RAG_REDIS_QUEUE_CONTAINER} \
  ${RAG_RABBITMQ_CONTAINER}; do
  podman stop \"\${container}\" 2>/dev/null || true
  podman rm -f \"\${container}\" 2>/dev/null || true
  echo \"Removed container: \${container}\"
done

for vol in \$(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^rag-${_BENCH_ID}' || true); do
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

  if ! $RAG_DRY_RUN; then
    _bench_ok=$(ssh ${SSH_BASE_OPTS} "$TARGET" \
      "test -d '${RAG_FRAPPE_BENCH_DIR}/apps/rag_service' && echo yes || echo no" 2>/dev/null || echo no)
    if [[ "$_bench_ok" != "yes" ]]; then
      warn "Bench or rag_service app not found — falling back to full deploy"
      _deploy_log "Update: bench missing, running full deploy"
      RAG_UPDATE_ONLY=false
      return 0
    fi
  fi

  run_remote_as_frappe "git pull + migrate + build [${_BENCH_ID}]" "
cd ${RAG_FRAPPE_BENCH_DIR}/apps/rag_service
git remote get-url origin >/dev/null 2>&1 || git remote add origin ${RAG_GIT_REPO}
git remote set-url origin ${RAG_GIT_REPO}
git fetch --all --prune
git checkout ${RAG_GIT_BRANCH} 2>/dev/null \
  || git checkout -b ${RAG_GIT_BRANCH} origin/${RAG_GIT_BRANCH}
git reset --hard origin/${RAG_GIT_BRANCH}
echo \"HEAD: \$(git log --oneline -1)\"
cd ${RAG_FRAPPE_BENCH_DIR}
bench --site ${RAG_FRAPPE_SITE} migrate
bench build --app rag_service --force
"
  run_remote_heredoc "Restart bench supervisor processes after update [${_BENCH_ID}]" "
set +e
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5
supervisorctl status 2>/dev/null || true
"
  _restart_rag_app_with_diagnostics
  success "Update complete [${_BENCH_ID}]"
  _deploy_log "Update complete"
}

do_update_config() {
  header "Update config: dependencies + site config + DB settings [${_BENCH_ID}]"
  _deploy_log "Action: update-config"

  if ! $RAG_DRY_RUN; then
    _bench_ok=$(ssh ${SSH_BASE_OPTS} "$TARGET" \
      "test -d '${RAG_FRAPPE_BENCH_DIR}/apps/rag_service' && echo yes || echo no" 2>/dev/null || echo no)
    if [[ "$_bench_ok" != "yes" ]]; then
      die "Bench not found at ${RAG_FRAPPE_BENCH_DIR} — run a full deploy first."
    fi
  fi

  _install_python_deps

  run_remote_as_frappe "Update common_site_config and bench site config [${_BENCH_ID}]" "
cd ${RAG_FRAPPE_BENCH_DIR}
cat > ${_SITES_DIR}/common_site_config.json <<SITECFG
{
  \"db_host\": \"${RAG_PG_HOST}\",
  \"db_port\": ${RAG_PG_PORT},
  \"redis_cache\": \"redis://127.0.0.1:${RAG_REDIS_CACHE_PORT}\",
  \"redis_queue\": \"redis://127.0.0.1:${RAG_REDIS_QUEUE_PORT}\",
  \"redis_socketio\": \"redis://127.0.0.1:${RAG_REDIS_CACHE_PORT}\"
}
SITECFG
echo 'common_site_config.json updated'

bench --site ${RAG_FRAPPE_SITE} set-config db_host '${RAG_PG_HOST}'
bench --site ${RAG_FRAPPE_SITE} set-config db_port ${RAG_PG_PORT}

if ${RAG_DEPLOY_DOMAIN}; then
  _host_prefix='http'
  ${RAG_ENABLE_HTTPS} && _host_prefix='https'
  bench --site ${RAG_FRAPPE_SITE} set-config host_name \"\${_host_prefix}://${RAG_DOMAIN_NAME}\"
else
  bench --site ${RAG_FRAPPE_SITE} set-config host_name 'http://${RAG_SERVER_HOST}:${RAG_API_PORT}'
fi
echo 'Bench site config updated'
"

  _patch_source_imports
  _write_consumer_script
  _write_pgpass_remote

  run_remote_heredoc "Restart bench supervisor processes before config seed [${_BENCH_ID}]" "
set +e
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5
supervisorctl status 2>/dev/null || true
"

  _seed_frappe_db

  RAG_WAIT 5
  _restart_rag_app_with_diagnostics

  success "Config update complete [${_BENCH_ID}]"
  _deploy_log "update-config complete"
}

header "Pre-flight [${_BENCH_ID}]"
_deploy_log "=== RAG Deploy session started ==="
_appid_log  "=== RAG Deploy session started ==="

[[ -f "$RAG_SSH_KEY_PATH" ]] || die "SSH key not found: $RAG_SSH_KEY_PATH"
chmod 600 "$RAG_SSH_KEY_PATH"
success "SSH key OK"

if ! $RAG_DRY_RUN; then
  _ssh_master_up
  ssh ${SSH_BASE_OPTS} "$TARGET" "echo 'SSH OK'" > /dev/null 2>&1 \
    || die "Cannot connect to ${TARGET} on port ${RAG_SSH_PORT}"
fi
success "SSH connection verified → ${TARGET}"
_deploy_log "SSH verified → ${TARGET}"

info "LLM provider: ${_LLM_PROVIDER_NORM} (doctype: ${_LLM_DOCTYPE_PROVIDER})  model: ${RAG_LLM_MODEL}"
$RAG_ENABLE_HTTPS \
  && info "Deploy mode: HTTPS  → $(_effective_url)" \
  || { $RAG_DEPLOY_DOMAIN \
         && info "Deploy mode: DOMAIN → $(_effective_url)" \
         || info "Deploy mode: PORT   → $(_effective_url)"; }

$RAG_DRY_RUN && warn "DRY RUN — SSH commands printed, not executed."

if $RAG_STOP_ONLY;     then do_stop;          _deploy_log "=== Session end ==="; exit 0; fi
if $RAG_RESTART_ONLY;  then do_restart;        _deploy_log "=== Session end ==="; exit 0; fi
if $RAG_STATUS_ONLY;   then do_status;         _deploy_log "=== Session end ==="; exit 0; fi
if $RAG_UPDATE_CONFIG; then do_update_config;  _deploy_log "=== Session end ==="; exit 0; fi

if $RAG_UPDATE_ONLY; then
  do_update
  if $RAG_UPDATE_ONLY; then _deploy_log "=== Session end ==="; exit 0; fi
  warn "--update fell back to full deploy because bench was missing"
fi

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
  run_remote_heredoc "Install system packages" "
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

if ! ${RAG_PYTHON_VERSION} --version &>/dev/null 2>&1; then
  add-apt-repository ppa:deadsnakes/ppa -y 2>/dev/null || true
  apt-get update -qq
  _pyver=\$(echo '${RAG_PYTHON_VERSION}' | sed 's/python//')
  apt-get install -y -qq \
    python\${_pyver} python\${_pyver}-dev python\${_pyver}-venv python\${_pyver}-distutils \
    2>&1 | tail -3
fi

apt-get clean
rm -rf /var/lib/apt/lists/*

pip3 install frappe-bench --break-system-packages -q 2>&1 | tail -2
npm install -g yarn -q 2>&1 | tail -2

echo \"yarn: \$(yarn --version)\"
echo \"frappe-bench: \$(bench --version 2>/dev/null || pip3 show frappe-bench 2>/dev/null | grep Version)\"
echo \"${RAG_PYTHON_VERSION}: \$(${RAG_PYTHON_VERSION} --version)\"
"
  success "System packages installed"
  _deploy_log "Step 1 complete"
fi

if step_enabled 2; then
  header "Step 2 — Container units + OS user + Postgres bootstrap [${_BENCH_ID}]"
  _deploy_log "Step 2: container units, frappe user, postgres"

  _write_pgpass_remote

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

podman pull ${RAG_POSTGRES_IMAGE} 2>/dev/null || true
_start_container '${RAG_POSTGRES_CONTAINER}' \
  \"-e POSTGRES_PASSWORD=${RAG_POSTGRES_PASSWORD} -p ${RAG_PG_HOST}:${RAG_PG_PORT}:5432 ${RAG_POSTGRES_IMAGE}\"

podman pull ${RAG_REDIS_IMAGE} 2>/dev/null || true
_start_container '${RAG_REDIS_CACHE_CONTAINER}' \
  \"-p 127.0.0.1:${RAG_REDIS_CACHE_PORT}:6379 ${RAG_REDIS_IMAGE} redis-server --maxmemory ${RAG_REDIS_MAXMEMORY} --maxmemory-policy ${RAG_REDIS_MAXMEMORY_POLICY}\"

_start_container '${RAG_REDIS_QUEUE_CONTAINER}' \
  \"-p 127.0.0.1:${RAG_REDIS_QUEUE_PORT}:6379 ${RAG_REDIS_IMAGE} redis-server --maxmemory ${RAG_REDIS_MAXMEMORY} --maxmemory-policy ${RAG_REDIS_MAXMEMORY_POLICY}\"

podman pull ${RAG_RABBITMQ_IMAGE} 2>/dev/null || true
_start_container '${RAG_RABBITMQ_CONTAINER}' \
  \"-e RABBITMQ_DEFAULT_USER=${RAG_RABBITMQ_USER} -e RABBITMQ_DEFAULT_PASS=${RAG_RABBITMQ_PASSWORD} -e RABBITMQ_DEFAULT_VHOST=${RAG_RABBITMQ_VHOST} -p 127.0.0.1:${RAG_RABBITMQ_PORT}:5672 -p 127.0.0.1:${RAG_RABBITMQ_MANAGEMENT_PORT}:15672 ${RAG_RABBITMQ_IMAGE}\"

echo 'All containers started with --restart=always'

_wait_tcp() {
  local host=\"\$1\" port=\"\$2\" label=\"\$3\"
  echo \"Waiting for \${label} on \${host}:\${port}...\"
  local i=0
  while [[ \${i} -lt 40 ]]; do
    i=\$(( i + 1 ))
    nc -z \"\${host}\" \"\${port}\" 2>/dev/null && echo \"\${label}: reachable\" && return 0
    sleep 3
  done
  echo \"FATAL: \${label} not reachable after 120s\" >&2; exit 1
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

_wait_tcp ${RAG_PG_HOST} ${RAG_PG_PORT} 'postgres TCP'
_wait_redis ${RAG_REDIS_CACHE_PORT} 'redis-cache'
_wait_redis ${RAG_REDIS_QUEUE_PORT} 'redis-queue'
"

  run_remote_heredoc "Create frappe OS user and configure postgres [${_BENCH_ID}]" "
set +e
id ${RAG_FRAPPE_USER} &>/dev/null || useradd -ms /bin/bash ${RAG_FRAPPE_USER}

grep -qxF '${RAG_FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL' /etc/sudoers \
  || echo '${RAG_FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

chmod 755 /home/${RAG_FRAPPE_USER}
usermod -a -G ${RAG_FRAPPE_USER} www-data 2>/dev/null || true

mkdir -p /home/${RAG_FRAPPE_USER}/logs
chown -R ${RAG_FRAPPE_USER}:${RAG_FRAPPE_USER} /home/${RAG_FRAPPE_USER}/logs
chmod 755 /home/${RAG_FRAPPE_USER}/logs

echo 'Waiting for postgres to accept connections on ${RAG_PG_HOST}:${RAG_PG_PORT}...'
i=0
while [[ \${i} -lt 40 ]]; do
  i=\$(( i + 1 ))
  psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
    -c 'SELECT 1' >/dev/null 2>&1 && echo 'postgres: OK' && break
  sleep 3
  [[ \${i} -eq 40 ]] && echo 'FATAL: postgres not ready' >&2 && exit 1
done

psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
  -c \"ALTER USER postgres WITH SUPERUSER CREATEDB CREATEROLE PASSWORD '${RAG_POSTGRES_PASSWORD}';\"

psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres -d template1 \
  -c 'GRANT ALL ON SCHEMA public TO PUBLIC;'

psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres -d template1 \
  -c 'ALTER SCHEMA public OWNER TO postgres;'

chmod o+rx ${RAG_TAP_RAG_DIR} 2>/dev/null || true
find ${RAG_TAP_RAG_DIR} -maxdepth 3 -name 'requirements*.txt' -exec chmod o+r {} \; 2>/dev/null || true

echo 'frappe user and postgres ready'
id ${RAG_FRAPPE_USER}
"
  success "Containers started, frappe user and postgres configured [${_BENCH_ID}]"
  _deploy_log "Step 2 complete"
fi

if step_enabled 3; then
  header "Step 3 — NVM + Node (${RAG_NODE_VERSION}) for ${RAG_FRAPPE_USER}"
  _deploy_log "Step 3: nvm + node"
  run_remote_as_frappe "Install NVM and Node ${RAG_NODE_VERSION}" "
export NVM_DIR=\"\${HOME}/.nvm\"
if [[ ! -s \"\${NVM_DIR}/nvm.sh\" ]]; then
  curl -fsSL ${RAG_NVM_INSTALL_URL} | bash
fi
source \"\${NVM_DIR}/nvm.sh\"
nvm install ${RAG_NODE_VERSION}
nvm use ${RAG_NODE_VERSION}
nvm alias default ${RAG_NODE_VERSION}
echo \"node: \$(node --version)\"
echo \"npm:  \$(npm --version)\"
"
  success "NVM and Node ${RAG_NODE_VERSION} ready"
  _deploy_log "Step 3 complete"
fi

if step_enabled 4; then
  header "Step 4 — Frappe bench init [${_BENCH_ID}]"
  _deploy_log "Step 4: bench init"
  run_remote_as_frappe "bench init ${RAG_FRAPPE_BENCH_DIR}" "
if [[ -d ${RAG_FRAPPE_BENCH_DIR} ]]; then
  echo 'bench dir exists — skipping init'
else
  bench init ${RAG_FRAPPE_BENCH_DIR} \
    --frappe-branch ${RAG_FRAPPE_BRANCH} \
    --python ${RAG_PYTHON_VERSION}
fi

mkdir -p ${_BENCH_LOGS_DIR}
mkdir -p ${_SITES_DIR}/logs
chown -R ${RAG_FRAPPE_USER}:${RAG_FRAPPE_USER} ${_BENCH_LOGS_DIR} 2>/dev/null || true
chown -R ${RAG_FRAPPE_USER}:${RAG_FRAPPE_USER} ${_SITES_DIR}/logs 2>/dev/null || true

cat > ${_SITES_DIR}/common_site_config.json <<SITECFG
{
  \"db_host\": \"${RAG_PG_HOST}\",
  \"db_port\": ${RAG_PG_PORT},
  \"redis_cache\": \"redis://127.0.0.1:${RAG_REDIS_CACHE_PORT}\",
  \"redis_queue\": \"redis://127.0.0.1:${RAG_REDIS_QUEUE_PORT}\",
  \"redis_socketio\": \"redis://127.0.0.1:${RAG_REDIS_CACHE_PORT}\"
}
SITECFG

echo 'bench init done'
ls ${RAG_FRAPPE_BENCH_DIR}/apps/
"
  success "Frappe bench initialised [${_BENCH_ID}]"
  _deploy_log "Step 4 complete"
fi

if step_enabled 5; then
  header "Step 5 — Verify infrastructure containers [${_BENCH_ID}]"
  _deploy_log "Step 5: verify containers"
  run_remote_as_owner "Ensure all infrastructure containers are running [${_BENCH_ID}]" "
set +e

_ensure_container() {
  local name=\"\$1\"
  local state
  state=\$(podman inspect --format '{{.State.Status}}' \"\${name}\" 2>/dev/null || echo 'missing')
  if [[ \"\${state}\" != 'running' ]]; then
    echo \"Starting \${name} (state: \${state})\"
    podman start \"\${name}\" 2>/dev/null || true
    sleep 3
  else
    echo \"\${name}: running\"
  fi
}

_ensure_container '${RAG_POSTGRES_CONTAINER}'
_ensure_container '${RAG_REDIS_CACHE_CONTAINER}'
_ensure_container '${RAG_REDIS_QUEUE_CONTAINER}'
_ensure_container '${RAG_RABBITMQ_CONTAINER}'

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

_wait_redis ${RAG_REDIS_CACHE_PORT} 'redis-cache'
_wait_redis ${RAG_REDIS_QUEUE_PORT} 'redis-queue'

echo 'Redis verified'
"

  run_remote_heredoc "Verify postgres connectivity and enable pgvector [${_BENCH_ID}]" "
echo 'Verifying postgres on ${RAG_PG_HOST}:${RAG_PG_PORT}...'
i=0
while [[ \${i} -lt 30 ]]; do
  i=\$(( i + 1 ))
  psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
    -c 'SELECT 1' >/dev/null 2>&1 && echo 'postgres: OK' && break
  sleep 3
  [[ \${i} -eq 30 ]] && echo 'FATAL: postgres not ready after 90s' >&2 && exit 1
done

psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres -d template1 \
  -c 'CREATE EXTENSION IF NOT EXISTS vector;' 2>/dev/null \
  && echo 'pgvector enabled on template1' || echo 'pgvector not available on template1'

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

_site_db=\$(echo '${RAG_FRAPPE_SITE}' | tr '.' '_' | tr '-' '_')

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
      -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} \
      -U \"\${_db_user}\" -d \"\${_db_user}\" \
      -c 'SELECT 1' >/dev/null 2>&1
    _conn_ok=\$?
  else
    _conn_ok=1
  fi

  if [[ \${_conn_ok} -ne 0 ]]; then
    echo 'Site DB unreachable or stale — wiping site dir and dropping DB/role'
    psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
      -c \"DROP DATABASE IF EXISTS \\\"\${_db_user}\\\";\" 2>/dev/null || true
    psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
      -c \"DROP DATABASE IF EXISTS \\\"\${_site_db}\\\";\" 2>/dev/null || true
    psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
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

  run_remote_as_frappe "bench new-site ${RAG_FRAPPE_SITE} [${_BENCH_ID}]" "
cd ${RAG_FRAPPE_BENCH_DIR}

if [[ -d ${_SITE_DIR} ]]; then
  echo 'site already exists and DB is healthy — skipping new-site'
else
  PGPASSWORD='${RAG_POSTGRES_PASSWORD}' \
  bench new-site ${RAG_FRAPPE_SITE} \
    --db-type postgres \
    --db-root-username postgres \
    --db-root-password '${RAG_POSTGRES_PASSWORD}' \
    --db-host ${RAG_PG_HOST} \
    --db-port ${RAG_PG_PORT} \
    --admin-password '${RAG_FRAPPE_ADMIN_PASSWORD}'
fi

bench use ${RAG_FRAPPE_SITE}
bench --site ${RAG_FRAPPE_SITE} set-config db_host '${RAG_PG_HOST}'
bench --site ${RAG_FRAPPE_SITE} set-config db_port ${RAG_PG_PORT}

_host_proto='http'
${RAG_ENABLE_HTTPS} && _host_proto='https'

if ${RAG_DEPLOY_DOMAIN}; then
  bench --site ${RAG_FRAPPE_SITE} set-config host_name \"\${_host_proto}://${RAG_DOMAIN_NAME}\"
else
  bench --site ${RAG_FRAPPE_SITE} set-config host_name 'http://${RAG_SERVER_HOST}:${RAG_API_PORT}'
fi

bench --site ${RAG_FRAPPE_SITE} set-config served_by nginx

mkdir -p ${_SITE_LOGS_DIR}
mkdir -p ${_SITE_LOGS_ALT}
chown -R ${RAG_FRAPPE_USER}:${RAG_FRAPPE_USER} ${_SITE_LOGS_DIR} 2>/dev/null || true
chown -R ${RAG_FRAPPE_USER}:${RAG_FRAPPE_USER} ${_SITE_LOGS_ALT} 2>/dev/null || true

echo 'site ready'
"

  _write_pgpass_remote

  run_remote_heredoc "Enable pgvector extension in site database [${_BENCH_ID}]" "
set +e
_site_db=\$(python3 -c \"
import json
cfg = json.load(open('${_SITE_DIR}/site_config.json'))
print(cfg.get('db_name',''))
\" 2>/dev/null || echo '')

if [[ -n \"\${_site_db}\" ]]; then
  psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres -d \"\${_site_db}\" \
    -c 'CREATE EXTENSION IF NOT EXISTS vector;' 2>/dev/null \
    && echo \"pgvector enabled in \${_site_db}\" \
    || echo 'pgvector extension failed — pgvector may not be installed in this postgres image'
else
  echo 'Could not determine site DB name — skipping pgvector'
fi
"
  success "Frappe site ready [${_BENCH_ID}]"
  _deploy_log "Step 6 complete"
fi

if step_enabled 7; then
  header "Step 7 — Install rag_service app [${_BENCH_ID}]"
  _deploy_log "Step 7: install rag_service"
  run_remote_as_frappe "get-app + install-app rag_service [${_BENCH_ID}]" "
cd ${RAG_FRAPPE_BENCH_DIR}

if [[ -d apps/rag_service ]]; then
  echo 'rag_service present — pulling latest'
  cd apps/rag_service
  git remote set-url origin ${RAG_GIT_REPO} 2>/dev/null || git remote add origin ${RAG_GIT_REPO}
  git fetch --all --prune
  git checkout ${RAG_GIT_BRANCH} 2>/dev/null \
    || git checkout -b ${RAG_GIT_BRANCH} origin/${RAG_GIT_BRANCH}
  git reset --hard origin/${RAG_GIT_BRANCH}
  echo \"HEAD: \$(git log --oneline -1)\"
  cd ${RAG_FRAPPE_BENCH_DIR}
else
  bench get-app ${RAG_GIT_REPO} --branch ${RAG_GIT_BRANCH}
fi

_rag_installed=\$(bench --site ${RAG_FRAPPE_SITE} list-apps 2>/dev/null | grep -c '^rag_service$' || true)
if [[ \${_rag_installed} -gt 0 ]]; then
  echo 'rag_service already installed — skipping'
else
  bench --site ${RAG_FRAPPE_SITE} install-app rag_service
  echo 'rag_service installed'
fi
"
  success "rag_service installed [${_BENCH_ID}]"
  _deploy_log "Step 7 complete"
fi

if step_enabled 8; then
  header "Step 8 — Install business_theme_v14 [${_BENCH_ID}]"
  _deploy_log "Step 8: install business theme"
  run_remote_as_frappe "get-app + install-app business_theme_v14 [${_BENCH_ID}]" "
cd ${RAG_FRAPPE_BENCH_DIR}

[[ ! -d apps/business_theme_v14 ]] \
  && bench get-app ${RAG_BUSINESS_THEME_REPO} --branch ${RAG_BUSINESS_THEME_BRANCH}

_theme_installed=\$(bench --site ${RAG_FRAPPE_SITE} list-apps 2>/dev/null | grep -c '^business_theme_v14$' || true)
if [[ \${_theme_installed} -gt 0 ]]; then
  echo 'business_theme_v14 already installed — skipping'
else
  bench --site ${RAG_FRAPPE_SITE} install-app business_theme_v14
  echo 'business_theme_v14 installed'
fi
"
  success "business_theme_v14 installed [${_BENCH_ID}]"
  _deploy_log "Step 8 complete"
fi

if step_enabled 9; then
  header "Step 9 — bench migrate + build [${_BENCH_ID}]"
  _deploy_log "Step 9: migrate and build"
  run_remote_as_frappe "bench migrate + build [${_BENCH_ID}]" "
cd ${RAG_FRAPPE_BENCH_DIR}
bench --site ${RAG_FRAPPE_SITE} migrate
bench build --force
echo 'migrate and build done'
"
  success "Migrations applied and assets built [${_BENCH_ID}]"
  _deploy_log "Step 9 complete"
fi

if step_enabled 10; then
  header "Step 10 — Supervisor + Nginx [${_BENCH_ID}]"
  _deploy_log "Step 10: supervisor and nginx"

  _NGINX_CONF_CONTENT="$(_build_nginx_conf)"

  if $RAG_ENABLE_HTTPS; then
    _ensure_tls_cert
  fi

  run_remote_as_frappe "bench setup supervisor [${_BENCH_ID}]" "
cd ${RAG_FRAPPE_BENCH_DIR}
bench setup supervisor --yes
echo 'supervisor config generated'
"

  _NGINX_TMP=$(mktemp)
  printf '%s\n' "${_NGINX_CONF_CONTENT}" > "${_NGINX_TMP}"
  _NGINX_REMOTE_TMP="/tmp/rag-nginx-${_BENCH_ID}-$$.conf"

  if ! $RAG_DRY_RUN; then
    scp ${SCP_OPTS} "${_NGINX_TMP}" "${TARGET}:${_NGINX_REMOTE_TMP}"
  fi
  rm -f "${_NGINX_TMP}"

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

_src='${RAG_FRAPPE_BENCH_DIR}/config/supervisor.conf'
_dst='/etc/supervisor/conf.d/${_SUPERVISOR_CONF_NAME}.conf'

if [[ -f \"\${_src}\" ]]; then
  python3 - <<PYSTRIP
import re, pathlib, sys
src = pathlib.Path('${RAG_FRAPPE_BENCH_DIR}/config/supervisor.conf')
dst = pathlib.Path('/etc/supervisor/conf.d/${_SUPERVISOR_CONF_NAME}.conf')
if not src.exists():
    print('ERROR: supervisor.conf not found', file=sys.stderr)
    sys.exit(1)
txt = src.read_text()
txt = re.sub(r'\[(?:program|group):frappe-bench-redis[^\]]*\][^\[]*', '', txt, flags=re.DOTALL)
txt = re.sub(r'\[program:[^\]]*redis[^\]]*\][^\[]*', '', txt, flags=re.DOTALL)
txt = txt.replace('[group:frappe-bench-web]', '[group:${_SUPERVISOR_CONF_NAME}-web]')
txt = txt.replace('[group:frappe-bench-workers]', '[group:${_SUPERVISOR_CONF_NAME}-workers]')
dst.write_text(txt)
print(f'Installed supervisor config: {dst}')
PYSTRIP
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
supervisorctl reread
supervisorctl update

echo '=== Supervisor status ==='
supervisorctl status 2>/dev/null || true
"
  success "Supervisor and Nginx configured [${_BENCH_ID}]"
  _deploy_log "Step 10 complete"
fi

if step_enabled 11; then
  header "Step 11 — Verify infrastructure [${_BENCH_ID}]"
  _deploy_log "Step 11: verify infrastructure"
  run_remote_heredoc "Verify all infrastructure services [${_BENCH_ID}]" "
_wait_redis() {
  local port=\"\$1\" label=\"\$2\"
  echo \"Checking \${label} on port \${port}...\"
  local i=0
  while [[ \${i} -lt 30 ]]; do
    i=\$(( i + 1 ))
    redis-cli -h 127.0.0.1 -p \"\${port}\" ping 2>/dev/null | grep -q PONG && echo \"\${label}: OK\" && return 0
    sleep 3
  done
  echo \"FATAL: \${label} not ready\" >&2; exit 1
}

_wait_redis ${RAG_REDIS_CACHE_PORT} 'redis-cache'
_wait_redis ${RAG_REDIS_QUEUE_PORT} 'redis-queue'

echo 'Checking postgres on ${RAG_PG_HOST}:${RAG_PG_PORT}...'
i=0
while [[ \${i} -lt 30 ]]; do
  i=\$(( i + 1 ))
  psql -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
    -c 'SELECT 1' >/dev/null 2>&1 && echo 'postgres: OK' && break
  sleep 3
  [[ \${i} -eq 30 ]] && echo 'FATAL: postgres not ready' >&2 && exit 1
done

echo 'All infrastructure services verified'
"
  success "Infrastructure verified [${_BENCH_ID}]"
  _deploy_log "Step 11 complete"
fi

if step_enabled 12; then
  header "Step 12 — Python dependencies [${_BENCH_ID}]"
  _deploy_log "Step 12: python deps"

  run_remote_heredoc "Fix permissions before pip installs [${_BENCH_ID}]" "
set +e
chmod o+rx /home/${RAG_SERVER_USER} 2>/dev/null || true
chmod o+rx ${RAG_TAP_RAG_DIR} 2>/dev/null || true
find ${RAG_TAP_RAG_DIR} -maxdepth 3 -name 'requirements*.txt' -exec chmod o+r {} \; 2>/dev/null || true
find ${RAG_TAP_RAG_DIR} -maxdepth 1 -exec chmod o+rx {} \; 2>/dev/null || true
echo 'permissions fixed'
"

  _install_python_deps

  success "Python dependencies installed [${_BENCH_ID}]"
  _deploy_log "Step 12 complete"
fi

if step_enabled 13; then
  header "Step 13 — Patch langchain imports + rewrite consumer.py [${_BENCH_ID}]"
  _deploy_log "Step 13: code patches"

  _patch_source_imports
  _write_consumer_script

  run_remote_heredoc "Patch LLM manager to not raise on missing config [${_BENCH_ID}]" "
set +e
_f='${RAG_TAP_RAG_DIR}/rag_service/core/langchain_manager.py'
[[ -f \"\${_f}\" ]] || _f='${RAG_FRAPPE_BENCH_DIR}/apps/rag_service/rag_service/core/langchain_manager.py'
if [[ -f \"\${_f}\" ]]; then
  sed -i 's/raise Exception(\"No active LLM configuration found\")/print(\"Warning: No active LLM configuration found — will retry on first use\")\n            return/' \"\${_f}\"
  echo \"Patched: \${_f}\"
else
  echo 'langchain_manager.py not found — skipping patch'
fi
"

  success "Code patches applied [${_BENCH_ID}]"
  _deploy_log "Step 13 complete"
fi

if step_enabled 14; then
  header "Step 14 — Log directories + permissions [${_BENCH_ID}]"
  _deploy_log "Step 14: log dirs"
  _ensure_all_log_dirs
  success "Log directories ready [${_BENCH_ID}]"
  _deploy_log "Step 14 complete"
fi

if step_enabled 15; then
  header "Step 15 — RabbitMQ + rag-app systemd service [${_BENCH_ID}]"
  _deploy_log "Step 15: rag-app service"

  _S15_CONSUMER_LOCAL="${RAG_TAP_RAG_DIR}/rag_service/scripts/consumer.py"
  _S15_CONSUMER_BENCH="${RAG_FRAPPE_BENCH_DIR}/apps/rag_service/rag_service/scripts/consumer.py"

  if ! $RAG_DRY_RUN; then
    _S15_CONSUMER_PATH=$(ssh ${SSH_BASE_OPTS} "$TARGET" \
      "test -f '${_S15_CONSUMER_LOCAL}' && echo '${_S15_CONSUMER_LOCAL}' || echo '${_S15_CONSUMER_BENCH}'" 2>/dev/null \
      || echo "${_S15_CONSUMER_BENCH}")
  else
    _S15_CONSUMER_PATH="${_S15_CONSUMER_LOCAL}"
  fi

  run_remote_as_owner "Ensure RabbitMQ container is running [${_BENCH_ID}]" "
set +e
state=\$(podman inspect --format '{{.State.Status}}' '${RAG_RABBITMQ_CONTAINER}' 2>/dev/null || echo 'missing')
if [[ \"\${state}\" != 'running' ]]; then
  echo \"RabbitMQ not running (state: \${state}) — starting\"
  podman start '${RAG_RABBITMQ_CONTAINER}' 2>/dev/null || true
  sleep 5
else
  echo 'RabbitMQ: running'
fi
"

  run_remote_heredoc "Verify RabbitMQ is up [${_BENCH_ID}]" "
echo 'Waiting for RabbitMQ on 127.0.0.1:${RAG_RABBITMQ_PORT}...'
i=0
while [[ \${i} -lt 20 ]]; do
  i=\$(( i + 1 ))
  nc -z 127.0.0.1 ${RAG_RABBITMQ_PORT} 2>/dev/null && echo 'RabbitMQ: OK' && break
  sleep 3
  [[ \${i} -eq 20 ]] && echo 'FATAL: RabbitMQ not ready after 60s' >&2 && exit 1
done
"

  _S15_WRAPPER_LOCAL=$(mktemp /tmp/rag-wrapper-XXXXXX.sh)
  _S15_UNIT_LOCAL=$(mktemp /tmp/rag-unit-XXXXXX.service)
  _S15_WRAPPER_REMOTE="/tmp/rag-wrapper-${_BENCH_ID}-$$.sh"
  _S15_UNIT_REMOTE="/tmp/rag-unit-${_BENCH_ID}-$$.service"

  cat > "${_S15_WRAPPER_LOCAL}" <<WRAPPER_EOF
#!/bin/bash
set -e

export HOME=/home/${RAG_FRAPPE_USER}
export PYTHONPATH=${RAG_TAP_RAG_DIR}:${RAG_FRAPPE_BENCH_DIR}/apps/frappe:${RAG_FRAPPE_BENCH_DIR}/apps/rag_service

mkdir -p ${_SITE_LOGS_DIR} ${_SITE_LOGS_ALT}

_rmq_i=0
while ! nc -z ${RAG_RABBITMQ_HOST} ${RAG_RABBITMQ_PORT} 2>/dev/null; do
  _rmq_i=\$(( _rmq_i + 1 ))
  [ \${_rmq_i} -ge 20 ] && echo 'RabbitMQ not ready after 60s' >&2 && exit 1
  sleep 3
done

_pg_i=0
while ! PGPASSWORD='${RAG_POSTGRES_PASSWORD}' psql \
    -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres \
    -c 'SELECT 1' >/dev/null 2>&1; do
  _pg_i=\$(( _pg_i + 1 ))
  [ \${_pg_i} -ge 20 ] && echo 'Postgres not ready after 60s' >&2 && exit 1
  sleep 3
done

_SITE_CFG='${_SITE_DIR}/site_config.json'
_DB_NAME=\$(python3 -c "import json; c=json.load(open('\${_SITE_CFG}')); print(c['db_name'])" 2>/dev/null || true)
_DB_PASS=\$(python3 -c "import json; c=json.load(open('\${_SITE_CFG}')); print(c['db_password'])" 2>/dev/null || true)

if [ -z "\${_DB_NAME}" ]; then
  echo 'FATAL: could not read db_name from site_config.json' >&2
  exit 1
fi

PGPASSWORD='${RAG_POSTGRES_PASSWORD}' psql \
  -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} -U postgres <<PGSQL 2>/dev/null || true
DO \\\$\\\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '\${_DB_NAME}') THEN
    CREATE ROLE "\${_DB_NAME}" WITH LOGIN PASSWORD '\${_DB_PASS}';
  ELSE
    ALTER ROLE "\${_DB_NAME}" WITH LOGIN PASSWORD '\${_DB_PASS}';
  END IF;
END
\\\$\\\$;
GRANT ALL PRIVILEGES ON DATABASE "\${_DB_NAME}" TO "\${_DB_NAME}";
PGSQL

_PGPASS_TMP="\$(mktemp)"
echo '${RAG_PG_HOST}:${RAG_PG_PORT}:*:postgres:${RAG_POSTGRES_PASSWORD}' > "\${_PGPASS_TMP}"
echo '${RAG_PG_HOST}:${RAG_PG_PORT}:*:'\"\${_DB_NAME}\"':'\"\${_DB_PASS}\" >> "\${_PGPASS_TMP}"
chmod 600 "\${_PGPASS_TMP}"
export PGPASSFILE="\${_PGPASS_TMP}"

_site_i=0
while ! PGPASSWORD="\${_DB_PASS}" psql \
    -h ${RAG_PG_HOST} -p ${RAG_PG_PORT} \
    -U "\${_DB_NAME}" -d "\${_DB_NAME}" \
    -c 'SELECT 1' >/dev/null 2>&1; do
  _site_i=\$(( _site_i + 1 ))
  [ \${_site_i} -ge 20 ] && echo "Site DB \${_DB_NAME} not ready after 60s" >&2 && exit 1
  echo "Waiting for site DB \${_DB_NAME}..."
  sleep 3
done

[ -f '${RAG_TAP_RAG_DIR}/.env' ] && set -a && . '${RAG_TAP_RAG_DIR}/.env' && set +a

cd ${RAG_FRAPPE_BENCH_DIR}
exec ${RAG_FRAPPE_BENCH_DIR}/env/bin/python3 ${_S15_CONSUMER_PATH}
WRAPPER_EOF

  cat > "${_S15_UNIT_LOCAL}" <<UNIT_EOF
[Unit]
Description=RAG Worker (${_BENCH_ID})
After=network.target
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
User=${RAG_FRAPPE_USER}
Group=${RAG_FRAPPE_USER}
WorkingDirectory=${RAG_FRAPPE_BENCH_DIR}
ExecStart=${_WRAPPER_SCRIPT}
Restart=on-failure
RestartSec=15
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT_EOF

  if ! $RAG_DRY_RUN; then
    scp ${SCP_OPTS} "${_S15_WRAPPER_LOCAL}" "${TARGET}:${_S15_WRAPPER_REMOTE}"
    scp ${SCP_OPTS} "${_S15_UNIT_LOCAL}" "${TARGET}:${_S15_UNIT_REMOTE}"
  else
    info "DRY RUN: would scp wrapper and unit files to remote"
  fi
  rm -f "${_S15_WRAPPER_LOCAL}" "${_S15_UNIT_LOCAL}"

  run_remote_heredoc "Install rag-app-${_BENCH_ID} wrapper script and system service" "
mv '${_S15_WRAPPER_REMOTE}' '${_WRAPPER_SCRIPT}'
chmod 755 '${_WRAPPER_SCRIPT}'
chown root:root '${_WRAPPER_SCRIPT}'

mv '${_S15_UNIT_REMOTE}' '${_SYSTEMD_UNIT}'
chown root:root '${_SYSTEMD_UNIT}'
chmod 644 '${_SYSTEMD_UNIT}'
systemctl daemon-reload
systemctl enable ${_SERVICE_NAME}
echo 'Service unit written: ${_SERVICE_NAME}.service'
"

  _restart_rag_app_with_diagnostics

  success "rag-app service configured [${_BENCH_ID}]"
  _deploy_log "Step 15 complete"
fi

if step_enabled 16; then
  header "Step 16 — Start Frappe workers + seed DB [${_BENCH_ID}]"
  _deploy_log "Step 16: start workers then seed"

  run_remote_heredoc "Ensure Frappe supervisor processes are running before seed [${_BENCH_ID}]" "
set +e
supervisorctl start '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl start '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5
supervisorctl status 2>/dev/null || true
"

  _ensure_all_log_dirs
  _seed_frappe_db
  success "Frappe DB settings seeded [${_BENCH_ID}]"
  _deploy_log "Step 16 complete"
fi

if step_enabled 17; then
  header "Step 17 — Final restart + health check [${_BENCH_ID}]"
  _deploy_log "Step 17: final restart"

  run_remote_heredoc "Restart bench supervisor processes [${_BENCH_ID}]" "
set +e
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5
supervisorctl status 2>/dev/null || true
"

  RAG_WAIT 10
  _restart_rag_app_with_diagnostics
  RAG_WAIT 5
  do_status

  success "Final health check complete [${_BENCH_ID}]"
  _deploy_log "Step 17 complete"
fi

if step_enabled 18; then
  header "Step 18 — Firewall [${_BENCH_ID}]"
  _deploy_log "Step 18: firewall"

  if [[ "${RAG_OPEN_FIREWALL_PORT:-false}" == "true" ]]; then
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
${RAG_ENABLE_HTTPS} && _open_port ${RAG_NGINX_HTTPS_PORT}
"
    warn "Also open port ${_FW_HTTP} in your cloud NSG / security group."
    $RAG_ENABLE_HTTPS && warn "Also open port ${RAG_NGINX_HTTPS_PORT} (HTTPS) in your cloud NSG / security group."
    _deploy_log "Step 18 complete: opened ${_FW_HTTP}${RAG_ENABLE_HTTPS:+ and ${RAG_NGINX_HTTPS_PORT}}"
  else
    info "Step 18 — Skipping firewall (RAG_OPEN_FIREWALL_PORT=false)"
    _deploy_log "Step 18: skipped"
  fi
fi

ssh ${SSH_BASE_OPTS} -O exit "$TARGET" 2>/dev/null || true

echo ""
success "RAG deployment complete [${_BENCH_ID}]"
info "URL:      $(_effective_url)"
info "Login:    Administrator / ${RAG_FRAPPE_ADMIN_PASSWORD}"
info "Provider: ${_LLM_PROVIDER_NORM} (doctype: ${_LLM_DOCTYPE_PROVIDER})  model: ${RAG_LLM_MODEL}"
$RAG_ENABLE_HTTPS && warn "HTTPS uses a self-signed cert — install a CA-signed cert for production."
info "Next:     → LLM Settings (provider will show as '${_LLM_DOCTYPE_PROVIDER}' — this is correct for Groq)"
info "          → RabbitMQ Settings (verify connection)"
info "          → Prompt Template (set active)"
info "          → RAG Settings (set base_url, api_key, api_secret)"
info "Logs:     ${RAG_DEPLOY_LOG}"
_deploy_log "=== RAG Deployment complete ==="
_appid_log  "=== RAG Deployment complete ==="
echo ""