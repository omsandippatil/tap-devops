#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

_info()   { echo -e "${DIM}${CYAN}  ›${RESET} $*"; }
_ok()     { echo -e "${GREEN}  ✓${RESET} $*"; }
_warn()   { echo -e "${YELLOW}  ⚠${RESET}  $*"; }
_err()    { echo -e "${RED}  ✗${RESET} $*" >&2; }
_die()    { _err "$*"; exit 1; }
_header() { echo -e "\n${BOLD}${CYAN}  ══  $*  ══${RESET}"; }

LMS_CONFIG_FILE="${LMS_CONFIG_FILE:-./tap-devops/config.env}"
LMS_DRY_RUN="${LMS_DRY_RUN:-false}"
LMS_STEPS="${LMS_STEPS:-}"
LMS_FORCE="${LMS_FORCE:-false}"
LMS_VERBOSE="${LMS_VERBOSE:-false}"
LMS_NO_WAIT="${LMS_NO_WAIT:-false}"

LMS_CLEAN="${LMS_CLEAN:-false}"
LMS_CLEAN_ONLY="${LMS_CLEAN_ONLY:-false}"
LMS_CLEAN_CONTAINERS="${LMS_CLEAN_CONTAINERS:-false}"
LMS_CLEAN_VOLUMES="${LMS_CLEAN_VOLUMES:-false}"
LMS_CLEAN_DIRS="${LMS_CLEAN_DIRS:-false}"
LMS_CLEAN_VENV="${LMS_CLEAN_VENV:-false}"
LMS_CLEAN_SERVICES="${LMS_CLEAN_SERVICES:-false}"

LMS_RESTART_ONLY="${LMS_RESTART_ONLY:-false}"
LMS_STOP_ONLY="${LMS_STOP_ONLY:-false}"
LMS_STATUS_ONLY="${LMS_STATUS_ONLY:-false}"
LMS_UPDATE_ONLY="${LMS_UPDATE_ONLY:-false}"
LMS_UPDATE_CONFIG="${LMS_UPDATE_CONFIG:-false}"

LMS_DEPLOY_DOMAIN="${LMS_DEPLOY_DOMAIN:-false}"
LMS_ENABLE_HTTPS="${LMS_ENABLE_HTTPS:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)            LMS_CONFIG_FILE="$2"; shift 2 ;;
    --dry-run)           LMS_DRY_RUN=true; shift ;;
    --steps)             LMS_STEPS="$2"; shift 2 ;;
    --force)             LMS_FORCE=true; shift ;;
    --verbose)           LMS_VERBOSE=true; shift ;;
    --no-wait)           LMS_NO_WAIT=true; shift ;;
    --clean)             LMS_CLEAN=true; LMS_FORCE=true; shift ;;
    --clean-only)        LMS_CLEAN=true; LMS_CLEAN_ONLY=true; LMS_FORCE=true; shift ;;
    --clean-containers)  LMS_CLEAN_CONTAINERS=true; shift ;;
    --clean-volumes)     LMS_CLEAN_VOLUMES=true; shift ;;
    --clean-dirs)        LMS_CLEAN_DIRS=true; LMS_FORCE=true; shift ;;
    --clean-venv)        LMS_CLEAN_VENV=true; shift ;;
    --clean-services)    LMS_CLEAN_SERVICES=true; shift ;;
    --restart)           LMS_RESTART_ONLY=true; shift ;;
    --stop)              LMS_STOP_ONLY=true; shift ;;
    --status)            LMS_STATUS_ONLY=true; shift ;;
    --update)            LMS_UPDATE_ONLY=true; shift ;;
    --update-config)     LMS_UPDATE_CONFIG=true; shift ;;
    --deploy-to-domain)  LMS_DEPLOY_DOMAIN=true; shift ;;
    --enable-https)      LMS_ENABLE_HTTPS=true; LMS_DEPLOY_DOMAIN=true; shift ;;
    --help)
      cat <<'HELP'
Usage: setup-lms.sh [--config FILE] [OPTIONS]

Deployment modes:
  (no flags)           Full fresh deploy
  --update             Pull all apps + migrate + restart
  --update-config      Sync site/DB config then restart
  --restart            Restart all LMS services
  --stop               Stop all LMS services
  --status             Full health status

Clean operations:
  --clean-containers   Stop and remove Podman containers
  --clean-volumes      Remove Podman volumes
  --clean-dirs         Wipe bench directory and site DB
  --clean-venv         Remove Python virtualenv
  --clean-services     Remove supervisor + nginx + systemd units
  --clean              Full wipe (all of the above) then redeploy
  --clean-only         Full wipe and exit

Step control:
  --steps N            Run only step N
  --steps N-M          Run steps N through M
  --steps N,M,X-Y      Comma-separated list/ranges

Options:
  --config FILE        Path to config.env
  --dry-run            Print commands without executing
  --force              Skip confirmation prompts
  --verbose            Enable set -x on remote scripts
  --no-wait            Skip non-critical sleep delays
  --deploy-to-domain   Serve via nginx using LMS_DOMAIN_NAME
  --enable-https       Configure HTTPS (implies --deploy-to-domain)
HELP
      exit 0 ;;
    *) _die "Unknown argument: $1 — use --help" ;;
  esac
done

[[ -f "$LMS_CONFIG_FILE" ]] || _die "Config file not found: $LMS_CONFIG_FILE"
source "$LMS_CONFIG_FILE"
_ok "Loaded config: $LMS_CONFIG_FILE"

LMS_LOG_DIR="${LMS_LOG_DIR:-./tap-devops/logs}"
LMS_LOG_MAX_MB="${LMS_LOG_MAX_MB:-10}"
LMS_LOG_BACKUP_COUNT="${LMS_LOG_BACKUP_COUNT:-5}"
LMS_SSH_PORT="${LMS_SSH_PORT:-22}"
LMS_SSH_ACCEPT_NEW="${LMS_SSH_ACCEPT_NEW:-false}"
LMS_PG_HOST="${LMS_PG_HOST:-127.0.0.1}"
LMS_PG_PORT="${LMS_PG_PORT:-5437}"
LMS_PYTHON_VERSION="${LMS_PYTHON_VERSION:-python3.11}"
LMS_FRAPPE_BRANCH="${LMS_FRAPPE_BRANCH:-version-14}"
LMS_BUSINESS_THEME_BRANCH="${LMS_BUSINESS_THEME_BRANCH:-main}"
LMS_NODE_VERSION="${LMS_NODE_VERSION:-16.15.0}"
LMS_REDIS_CACHE_PORT="${LMS_REDIS_CACHE_PORT:-13200}"
LMS_REDIS_QUEUE_PORT="${LMS_REDIS_QUEUE_PORT:-11200}"
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
LMS_OPEN_FIREWALL_PORT="${LMS_OPEN_FIREWALL_PORT:-true}"
LMS_SERVICE_OWNER="${LMS_SERVICE_OWNER:-${LMS_SERVER_USER}}"
LMS_FRAPPE_SHORT_WORKERS="${LMS_FRAPPE_SHORT_WORKERS:-2}"
LMS_FRAPPE_LONG_WORKERS="${LMS_FRAPPE_LONG_WORKERS:-1}"
LMS_NVM_INSTALL_URL="${LMS_NVM_INSTALL_URL:-https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh}"
LMS_BUSINESS_THEME_REPO="${LMS_BUSINESS_THEME_REPO:-https://github.com/Midocean-Technologies/business_theme_v14.git}"
LMS_TLS_CERT="${LMS_TLS_CERT:-/etc/ssl/lms/lms.crt}"
LMS_TLS_KEY="${LMS_TLS_KEY:-/etc/ssl/lms/lms.key}"
LMS_POSTGRES_IMAGE="${LMS_POSTGRES_IMAGE:-docker.io/library/postgres:15-alpine}"
LMS_REDIS_IMAGE="${LMS_REDIS_IMAGE:-docker.io/library/redis:7-alpine}"
LMS_SERVER_SUDO_PASSWORD="${LMS_SERVER_SUDO_PASSWORD:-}"
LMS_GUNICORN_WORKERS="${LMS_GUNICORN_WORKERS:-4}"
LMS_DEPLOY_SECRET_KEY="${LMS_DEPLOY_SECRET_KEY:-}"

REQUIRED_VARS=(
  LMS_SERVER_USER LMS_SERVER_HOST LMS_SSH_KEY_PATH
  LMS_GIT_REPO LMS_GIT_BRANCH
  LMS_POSTGRES_PASSWORD
  LMS_FRAPPE_BENCH_DIR LMS_FRAPPE_SITE LMS_FRAPPE_USER LMS_FRAPPE_ADMIN_PASSWORD
  LMS_DEPLOY_SECRET_KEY
)
for _v in "${REQUIRED_VARS[@]}"; do
  [[ -n "${!_v:-}" ]] || _die "Required config var \$$_v not set in $LMS_CONFIG_FILE"
done

if [[ "${LMS_DEPLOY_DOMAIN}" == "true" ]] || [[ "${LMS_ENABLE_HTTPS}" == "true" ]]; then
  [[ -n "${LMS_DOMAIN_NAME:-}" ]] || _die "--deploy-to-domain and --enable-https require LMS_DOMAIN_NAME"
fi

_BENCH_ID=$(basename "${LMS_FRAPPE_BENCH_DIR}")

LMS_POSTGRES_CONTAINER="${LMS_POSTGRES_CONTAINER:-lms-${_BENCH_ID}-postgres}"
LMS_REDIS_CACHE_CONTAINER="${LMS_REDIS_CACHE_CONTAINER:-lms-${_BENCH_ID}-redis-cache}"
LMS_REDIS_QUEUE_CONTAINER="${LMS_REDIS_QUEUE_CONTAINER:-lms-${_BENCH_ID}-redis-queue}"

_SUPERVISOR_CONF_NAME="lms-bench-${_BENCH_ID}"
_NGINX_CONF_NAME="lms-bench-${_BENCH_ID}"
_SERVICE_NAME="lms-app-${_BENCH_ID}"
_CONSUMER_SERVICE_NAME="lms-consumer-${_BENCH_ID}"
_SYSTEMD_UNIT="/etc/systemd/system/${_SERVICE_NAME}.service"
_CONSUMER_SYSTEMD_UNIT="/etc/systemd/system/${_CONSUMER_SERVICE_NAME}.service"

_SITES_DIR="${LMS_FRAPPE_BENCH_DIR}/sites"
_SITE_DIR="${_SITES_DIR}/${LMS_FRAPPE_SITE}"
_SITE_LOGS_DIR="${_SITE_DIR}/logs"
_BENCH_LOGS_DIR="${LMS_FRAPPE_BENCH_DIR}/logs"
_SITE_LOGS_ALT="${LMS_FRAPPE_BENCH_DIR}/${LMS_FRAPPE_SITE}/logs"
_ASSETS_DIR="${_SITES_DIR}/assets"
_ASSET_MANIFEST_FILE="${_ASSETS_DIR}/assets.json"
_SITE_ASSETS_DIR="${_SITE_DIR}/assets"
_SITE_ASSET_MANIFEST="${_SITE_ASSETS_DIR}/assets.json"
_VENV_DIR="${LMS_FRAPPE_BENCH_DIR}/env"

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

LMS_DEPLOY_LOG="${LMS_LOG_DIR}/${_BENCH_ID}.log"

_deploy_log() { _log_to_file "$LMS_DEPLOY_LOG" "$*"; }

_tee_deploy_log() {
  while IFS= read -r line; do
    echo "$line"
    _log_to_file "$LMS_DEPLOY_LOG" "$line"
  done
}

SSH_CTRL_PATH="/tmp/lms-ssh-ctl-${_BENCH_ID}-$$"
_STRICT_OPT="StrictHostKeyChecking=yes"
[[ "${LMS_SSH_ACCEPT_NEW:-false}" == "true" ]] && _STRICT_OPT="StrictHostKeyChecking=accept-new"

SSH_BASE_OPTS=(
  -i "${LMS_SSH_KEY_PATH}"
  -p "${LMS_SSH_PORT}"
  -o "${_STRICT_OPT}"
  -o "ConnectTimeout=15"
  -o "ServerAliveInterval=30"
  -o "ServerAliveCountMax=20"
  -o "ControlMaster=auto"
  -o "ControlPath=${SSH_CTRL_PATH}"
  -o "ControlPersist=300"
)

SCP_BASE_OPTS=(
  -i "${LMS_SSH_KEY_PATH}"
  -P "${LMS_SSH_PORT}"
  -o "${_STRICT_OPT}"
  -o "ConnectTimeout=15"
  -o "ControlMaster=auto"
  -o "ControlPath=${SSH_CTRL_PATH}"
  -o "ControlPersist=300"
)

TARGET="${LMS_SERVER_USER}@${LMS_SERVER_HOST}"

_sudo_prefix() {
  if [[ -n "${LMS_SERVER_SUDO_PASSWORD:-}" ]]; then
    printf 'echo %q | sudo -S ' "${LMS_SERVER_SUDO_PASSWORD}"
  else
    printf 'sudo '
  fi
}

_wait_if_needed() {
  $LMS_NO_WAIT && return 0
  sleep "$1"
}

_ssh_verify() {
  rm -f "${SSH_CTRL_PATH}" 2>/dev/null || true
  ssh "${SSH_BASE_OPTS[@]}" -o BatchMode=yes "$TARGET" "echo SSH_OK" 2>/dev/null | grep -q SSH_OK
}

_effective_url() {
  if [[ "$LMS_ENABLE_HTTPS" == "true" ]]; then
    echo "https://${LMS_DOMAIN_NAME}/"
  elif [[ "$LMS_DEPLOY_DOMAIN" == "true" ]]; then
    echo "http://${LMS_DOMAIN_NAME}/"
  else
    echo "http://${LMS_SERVER_HOST}:${LMS_WEB_PORT}/"
  fi
}

_nginx_listen_port() {
  if [[ "$LMS_DEPLOY_DOMAIN" == "true" ]]; then
    echo "${LMS_NGINX_PORT}"
  else
    echo "${LMS_WEB_PORT}"
  fi
}

_nginx_server_name() {
  if [[ "$LMS_DEPLOY_DOMAIN" == "true" ]]; then
    echo "${LMS_DOMAIN_NAME}"
  else
    echo "_"
  fi
}

_run_remote() {
  local desc="$1"; shift
  _info "Remote: $desc"
  _deploy_log "Remote: $desc"
  if $LMS_DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run] $*${RESET}"
    return 0
  fi
  local _rc=0
  ssh "${SSH_BASE_OPTS[@]}" "$TARGET" "$@" 2>&1 | _tee_deploy_log || _rc=${PIPESTATUS[0]}
  if [[ $_rc -ne 0 ]]; then
    _err "Remote command failed (exit $_rc): $desc"
    _deploy_log "ERROR: remote command failed (exit $_rc): $desc"
    return $_rc
  fi
}

_run_heredoc_as_root() {
  local desc="$1"
  local body="$2"
  _info "Remote (root): $desc"
  _deploy_log "Remote (root): $desc"
  if $LMS_DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run root heredoc] $desc${RESET}"
    return 0
  fi
  local flags="set -eo pipefail"
  $LMS_VERBOSE && flags="${flags}; set -x"
  local _sudo_pre
  _sudo_pre="$(_sudo_prefix)"
  local _rc=0
  ssh "${SSH_BASE_OPTS[@]}" "$TARGET" "bash -s" 2>&1 <<EOF | _tee_deploy_log || _rc=${PIPESTATUS[0]}
${_sudo_pre}bash --login -s <<'INNER'
${flags}
${body}
INNER
EOF
  if [[ $_rc -ne 0 ]]; then
    _err "Remote root script failed (exit $_rc): $desc"
    _deploy_log "ERROR: remote root script failed (exit $_rc): $desc"
    return $_rc
  fi
}

_run_heredoc_as_frappe() {
  local desc="$1"
  local body="$2"
  _info "Remote (${LMS_FRAPPE_USER}): $desc"
  _deploy_log "Remote (${LMS_FRAPPE_USER}): $desc"
  if $LMS_DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run frappe heredoc] $desc${RESET}"
    return 0
  fi
  local preamble="export HOME=/home/${LMS_FRAPPE_USER}
export NVM_DIR=\"/home/${LMS_FRAPPE_USER}/.nvm\"
[[ -s \"\${NVM_DIR}/nvm.sh\" ]] && source \"\${NVM_DIR}/nvm.sh\"
nvm use ${LMS_NODE_VERSION} 2>/dev/null || true
export PATH=\"\${HOME}/.local/bin:\${HOME}/.nvm/versions/node/v${LMS_NODE_VERSION}/bin:\${PATH}\"
hash -r 2>/dev/null || true
cd ${LMS_FRAPPE_BENCH_DIR} 2>/dev/null || cd \${HOME}
[[ -f ${_VENV_DIR}/bin/activate ]] && source ${_VENV_DIR}/bin/activate 2>/dev/null || true"
  local flags="set -eo pipefail"
  $LMS_VERBOSE && flags="${flags}; set -x"
  local _sudo_pre
  _sudo_pre="$(_sudo_prefix)"
  local _rc=0
  ssh "${SSH_BASE_OPTS[@]}" "$TARGET" "bash -s" 2>&1 <<EOF | _tee_deploy_log || _rc=${PIPESTATUS[0]}
${_sudo_pre}-H -u ${LMS_FRAPPE_USER} bash --login -s <<'INNER'
${preamble}
${flags}
${body}
INNER
EOF
  if [[ $_rc -ne 0 ]]; then
    _err "Remote frappe script failed (exit $_rc): $desc"
    _deploy_log "ERROR: remote frappe script failed (exit $_rc): $desc"
    return $_rc
  fi
}

_run_heredoc_as_owner() {
  local desc="$1"
  local body="$2"
  _info "Remote (${LMS_SERVICE_OWNER}): $desc"
  _deploy_log "Remote (${LMS_SERVICE_OWNER}): $desc"
  if $LMS_DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run owner heredoc] $desc${RESET}"
    return 0
  fi
  local preamble="export HOME=/home/${LMS_SERVICE_OWNER}
_uid=\$(id -u)
export XDG_RUNTIME_DIR=/run/user/\${_uid}
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${_uid}/bus
loginctl enable-linger \$(whoami) 2>/dev/null || true"
  local flags="set -eo pipefail"
  $LMS_VERBOSE && flags="${flags}; set -x"
  local _sudo_pre
  _sudo_pre="$(_sudo_prefix)"
  local _rc=0
  ssh "${SSH_BASE_OPTS[@]}" "$TARGET" "bash -s" 2>&1 <<EOF | _tee_deploy_log || _rc=${PIPESTATUS[0]}
${_sudo_pre}-H -u ${LMS_SERVICE_OWNER} bash --login -s <<'INNER'
${preamble}
${flags}
${body}
INNER
EOF
  if [[ $_rc -ne 0 ]]; then
    _err "Remote owner script failed (exit $_rc): $desc"
    _deploy_log "ERROR: remote owner script failed (exit $_rc): $desc"
    return $_rc
  fi
}

_step_enabled() {
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

_DEPLOY_FAILED=false

_step_run() {
  local step_num="$1" step_label="$2"
  shift 2
  _header "Step ${step_num} — ${step_label}"
  _deploy_log "Step ${step_num}: ${step_label}"
  if ! "$@"; then
    _err "Step ${step_num} failed: ${step_label}"
    _deploy_log "ERROR: Step ${step_num} failed: ${step_label}"
    _DEPLOY_FAILED=true
    return 1
  fi
  _deploy_log "Step ${step_num} complete"
  return 0
}

_grant_nopasswd_sudo() {
  _info "Ensuring ${LMS_SERVER_USER} has passwordless sudo"
  local _rc=0
  ssh "${SSH_BASE_OPTS[@]}" "$TARGET" "bash -s" 2>&1 <<EOF | _tee_deploy_log || _rc=${PIPESTATUS[0]}
echo '${LMS_SERVER_SUDO_PASSWORD}' | sudo -S bash -c "echo '${LMS_SERVER_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${LMS_SERVER_USER}-nopasswd && chmod 440 /etc/sudoers.d/${LMS_SERVER_USER}-nopasswd"
EOF
  [[ $_rc -ne 0 ]] && _die "Failed to configure passwordless sudo for ${LMS_SERVER_USER}"
}

_install_supervisorctl_shim() {
  _run_heredoc_as_root "Install supervisorctl shim" \
'set +e
_real=$(command -v supervisorctl 2>/dev/null || true)
if [[ -n "${_real}" && "${_real}" != "/usr/local/bin/supervisorctl" ]]; then
  cp "${_real}" /usr/local/bin/supervisorctl.real
fi
cat > /usr/local/bin/supervisorctl <<'"'"'SHIM'"'"'
#!/usr/bin/env bash
exit 0
SHIM
chmod +x /usr/local/bin/supervisorctl
echo "supervisorctl shim installed"'
}

_remove_supervisorctl_shim() {
  _run_heredoc_as_root "Remove supervisorctl shim" \
'set +e
if [[ -f /usr/local/bin/supervisorctl.real ]]; then
  mv /usr/local/bin/supervisorctl.real /usr/local/bin/supervisorctl
  echo "supervisorctl shim removed — real binary restored"
else
  rm -f /usr/local/bin/supervisorctl
  echo "supervisorctl shim removed"
fi'
}

_write_pgpass() {
  _run_heredoc_as_root "Write .pgpass" \
"set +eu
PGLINE_SU='${LMS_PG_HOST}:${LMS_PG_PORT}:*:postgres:${LMS_POSTGRES_PASSWORD}'

_write_pgpass_for_user() {
  local home_dir=\"\$1\" owner=\"\$2\"
  local pgpass=\"\${home_dir}/.pgpass\"
  echo \"\${PGLINE_SU}\" > \"\${pgpass}\"
  if [[ -f '${_SITE_DIR}/site_config.json' ]]; then
    local pdb_name pdb_pass
    pdb_name=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_name',''))\" 2>/dev/null || true)
    pdb_pass=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_password',''))\" 2>/dev/null || true)
    if [[ -n \"\${pdb_name:-}\" && -n \"\${pdb_pass:-}\" ]]; then
      echo '${LMS_PG_HOST}:${LMS_PG_PORT}:*:'\"\${pdb_name}\"':'\"\${pdb_pass}\" >> \"\${pgpass}\"
    fi
  fi
  chown \"\${owner}\":\"\${owner}\" \"\${pgpass}\"
  chmod 600 \"\${pgpass}\"
  echo \"written: \${pgpass}\"
}

_write_pgpass_for_user /root root
_write_pgpass_for_user /home/${LMS_FRAPPE_USER} ${LMS_FRAPPE_USER}
[[ '${LMS_SERVICE_OWNER}' != '${LMS_FRAPPE_USER}' ]] && _write_pgpass_for_user /home/${LMS_SERVICE_OWNER} ${LMS_SERVICE_OWNER}
true"
}

_ensure_log_dirs() {
  _run_heredoc_as_root "Ensure log directories" \
"set +e
for _d in /home/${LMS_FRAPPE_USER}/logs ${_BENCH_LOGS_DIR} ${_SITES_DIR}/logs ${_SITE_LOGS_DIR} ${_SITE_LOGS_ALT}; do
  mkdir -p \"\${_d}\"
  chown -R ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} \"\${_d}\" 2>/dev/null || true
  chmod 755 \"\${_d}\"
done
mkdir -p /logs
chown ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} /logs 2>/dev/null || true
chmod 777 /logs
chmod o+rx /home/${LMS_FRAPPE_USER} 2>/dev/null || true
chmod o+rx ${LMS_FRAPPE_BENCH_DIR} 2>/dev/null || true
chmod o+rx ${_SITES_DIR} 2>/dev/null || true
[[ -f '${_SITE_DIR}/site_config.json' ]] && chmod o+r '${_SITE_DIR}/site_config.json' 2>/dev/null || true
echo 'log dirs ensured'"
}

_fix_asset_permissions() {
  _run_heredoc_as_root "Fix asset permissions" \
"set +e
if [[ -d '${_ASSETS_DIR}' ]]; then
  find '${_ASSETS_DIR}' -type d -exec chmod 755 {} +
  find '${_ASSETS_DIR}' -type f -exec chmod 644 {} +
  chown -R ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} '${_ASSETS_DIR}'
  echo 'asset permissions fixed'
fi"
}

_verify_asset_manifest() {
  _run_heredoc_as_root "Verify assets.json" \
"set +e
if [[ ! -f '${_ASSET_MANIFEST_FILE}' ]]; then
  echo 'FATAL: assets.json missing at ${_ASSET_MANIFEST_FILE}' >&2
  ls -la '${_ASSETS_DIR}/' >&2 || true
  exit 1
fi
_size=\$(wc -c < '${_ASSET_MANIFEST_FILE}' 2>/dev/null || echo 0)
[[ \"\${_size}\" -lt 10 ]] && { echo 'FATAL: assets.json empty' >&2; exit 1; }
python3 -c \"import json; json.load(open('${_ASSET_MANIFEST_FILE}'))\"
echo \"assets.json valid JSON (\${_size} bytes)\""
}

_copy_asset_manifest_to_site() {
  _run_heredoc_as_root "Copy assets.json into site dir" \
"set +e
if [[ ! -f '${_ASSET_MANIFEST_FILE}' ]]; then
  echo 'WARNING: assets.json not found at source — skipping' >&2
  exit 0
fi
[[ -L '${_SITE_ASSETS_DIR}' ]] && rm -f '${_SITE_ASSETS_DIR}'
mkdir -p '${_SITE_ASSETS_DIR}'
cp '${_ASSET_MANIFEST_FILE}' '${_SITE_ASSET_MANIFEST}'
chown ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} '${_SITE_ASSET_MANIFEST}'
chmod 644 '${_SITE_ASSET_MANIFEST}'
echo 'assets.json copied to site dir'"
}

_clear_redis_asset_cache() {
  _run_heredoc_as_root "Clear asset cache in Redis" \
"set +e
redis-cli -h 127.0.0.1 -p ${LMS_REDIS_CACHE_PORT} DEL assets_json 2>/dev/null || true
redis-cli -h 127.0.0.1 -p ${LMS_REDIS_CACHE_PORT} FLUSHDB 2>/dev/null || true
echo 'redis asset cache cleared'"
}

_build_assets() {
  _run_heredoc_as_frappe "Build assets" \
"cd ${LMS_FRAPPE_BENCH_DIR}
export PYTHONUNBUFFERED=1
bench build 2>&1 | cat
if [[ ! -f '${_ASSET_MANIFEST_FILE}' ]]; then
  bench build --app frappe 2>&1 | cat
fi
[[ ! -f '${_ASSET_MANIFEST_FILE}' ]] && { echo 'FATAL: assets.json not generated' >&2; exit 1; }
python3 -c \"import json; d=json.load(open('${_ASSET_MANIFEST_FILE}')); print(f'manifest: {len(d)} entries')\""

  _fix_asset_permissions
  _verify_asset_manifest
  _copy_asset_manifest_to_site
  _clear_redis_asset_cache
}

_clear_bench_caches() {
  _run_heredoc_as_frappe "Clear bench caches" \
"set +e
cd ${LMS_FRAPPE_BENCH_DIR}
bench --site ${LMS_FRAPPE_SITE} clear-cache 2>/dev/null || true
bench --site ${LMS_FRAPPE_SITE} clear-website-cache 2>/dev/null || true
echo 'caches cleared'"
  _clear_redis_asset_cache
}

_restart_gunicorn() {
  _run_heredoc_as_root "Restart ${_SERVICE_NAME}" \
"set +u
systemctl reset-failed ${_SERVICE_NAME} 2>/dev/null || true
systemctl restart ${_SERVICE_NAME}

_i=0
while [[ \${_i} -lt 12 ]]; do
  _i=\$(( _i + 1 ))
  _state=\$(systemctl is-active ${_SERVICE_NAME} 2>/dev/null || echo unknown)
  if [[ \"\${_state}\" == active ]]; then
    echo '${_SERVICE_NAME}: active'
    break
  fi
  if [[ \"\${_state}\" == failed ]]; then
    systemctl reset-failed ${_SERVICE_NAME} 2>/dev/null || true
    sleep 3
    systemctl start ${_SERVICE_NAME} 2>/dev/null || true
  fi
  echo \"${_SERVICE_NAME}: \${_state} [\${_i}/12]\"
  sleep 5
done

sleep 10
_final=\$(systemctl is-active ${_SERVICE_NAME} 2>/dev/null || echo unknown)
echo \"${_SERVICE_NAME} final state: \${_final}\"
systemctl status ${_SERVICE_NAME} --no-pager -l 2>/dev/null || true
journalctl -u ${_SERVICE_NAME} -n 30 --no-pager 2>/dev/null || true"
}

_restart_consumer() {
  _run_heredoc_as_root "Restart ${_CONSUMER_SERVICE_NAME}" \
"set +e
systemctl reset-failed ${_CONSUMER_SERVICE_NAME} 2>/dev/null || true
systemctl restart ${_CONSUMER_SERVICE_NAME} 2>/dev/null || true
sleep 5
_state=\$(systemctl is-active ${_CONSUMER_SERVICE_NAME} 2>/dev/null || echo unknown)
echo \"${_CONSUMER_SERVICE_NAME} state: \${_state}\"
journalctl -u ${_CONSUMER_SERVICE_NAME} -n 20 --no-pager 2>/dev/null || true"
}

_ensure_tls_cert() {
  _run_heredoc_as_root "Ensure TLS certificate" \
"set +e
mkdir -p /etc/ssl/lms
chmod 700 /etc/ssl/lms
if [[ -f '${LMS_TLS_CERT}' && -f '${LMS_TLS_KEY}' ]]; then
  echo 'existing TLS cert found'
  openssl x509 -in '${LMS_TLS_CERT}' -noout -dates 2>/dev/null || true
  exit 0
fi
openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
  -keyout '${LMS_TLS_KEY}' \
  -out '${LMS_TLS_CERT}' \
  -subj '/CN=${LMS_DOMAIN_NAME}/O=LMS/C=US' \
  -addext 'subjectAltName=DNS:${LMS_DOMAIN_NAME},IP:${LMS_SERVER_HOST}' \
  2>&1 || true
chmod 600 '${LMS_TLS_KEY}'
chmod 644 '${LMS_TLS_CERT}'
echo 'self-signed TLS cert generated'
openssl x509 -in '${LMS_TLS_CERT}' -noout -dates 2>/dev/null || true"
}

_build_nginx_conf() {
  local listen_port server_name
  listen_port="$(_nginx_listen_port)"
  server_name="$(_nginx_server_name)"

  if [[ "$LMS_ENABLE_HTTPS" == "true" ]]; then
    cat <<NGINXCFG
server {
    listen ${listen_port};
    listen [::]:${listen_port};
    server_name ${server_name};
    return 301 https://\$host\$request_uri;
}

server {
    listen ${LMS_NGINX_HTTPS_PORT} ssl;
    listen [::]:${LMS_NGINX_HTTPS_PORT} ssl;
    server_name ${server_name};
    client_max_body_size ${LMS_NGINX_MAX_BODY_MB}m;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;

    ssl_certificate     ${LMS_TLS_CERT};
    ssl_certificate_key ${LMS_TLS_KEY};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache   shared:LMS_SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;

    keepalive_timeout 65;

    location /assets {
        alias ${_ASSETS_DIR};
        try_files \$uri \$uri/ =404;
        expires 7d;
        add_header Cache-Control 'public, immutable';
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
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / {
        proxy_pass http://127.0.0.1:${LMS_GUNICORN_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Frappe-Site-Name ${LMS_FRAPPE_SITE};
        proxy_set_header X-Forwarded-Proto https;
        proxy_redirect off;
        proxy_buffering on;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_read_timeout ${LMS_NGINX_PROXY_TIMEOUT}s;
        proxy_connect_timeout ${LMS_NGINX_PROXY_TIMEOUT}s;
    }
}
NGINXCFG
  else
    cat <<NGINXCFG
server {
    listen ${listen_port};
    listen [::]:${listen_port};
    server_name ${server_name};
    client_max_body_size ${LMS_NGINX_MAX_BODY_MB}m;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/rss+xml application/atom+xml image/svg+xml;

    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-Content-Type-Options nosniff always;

    keepalive_timeout 65;

    location /assets {
        alias ${_ASSETS_DIR};
        try_files \$uri \$uri/ =404;
        expires 7d;
        add_header Cache-Control 'public, immutable';
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
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        proxy_pass http://127.0.0.1:${LMS_GUNICORN_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Frappe-Site-Name ${LMS_FRAPPE_SITE};
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_redirect off;
        proxy_buffering on;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_read_timeout ${LMS_NGINX_PROXY_TIMEOUT}s;
        proxy_connect_timeout ${LMS_NGINX_PROXY_TIMEOUT}s;
    }
}
NGINXCFG
  fi
}

_write_common_site_config() {
  _run_heredoc_as_frappe "Write common_site_config.json" \
"cd ${LMS_FRAPPE_BENCH_DIR}
cat > ${_SITES_DIR}/common_site_config.json <<SITECFG
{
  \"background_workers\": ${LMS_FRAPPE_SHORT_WORKERS},
  \"frappe_user\": \"${LMS_FRAPPE_USER}\",
  \"gunicorn_workers\": ${LMS_GUNICORN_WORKERS},
  \"live_reload\": false,
  \"redis_cache\": \"redis://127.0.0.1:${LMS_REDIS_CACHE_PORT}\",
  \"redis_queue\": \"redis://127.0.0.1:${LMS_REDIS_QUEUE_PORT}\",
  \"redis_socketio\": \"redis://127.0.0.1:${LMS_REDIS_QUEUE_PORT}\",
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
echo 'common_site_config.json written'"
}

_get_app_or_update() {
  local app_name="$1" repo="$2" branch="$3"
  _run_heredoc_as_frappe "Get or update ${app_name}" \
"cd ${LMS_FRAPPE_BENCH_DIR}
if [[ -d apps/${app_name} ]]; then
  cd apps/${app_name}
  git remote set-url origin ${repo} 2>/dev/null || git remote add origin ${repo}
  git fetch --all --prune
  git checkout ${branch} 2>/dev/null || git checkout -b ${branch} origin/${branch}
  git reset --hard origin/${branch}
  echo '${app_name} HEAD: '\$(git log --oneline -1)
  cd ${LMS_FRAPPE_BENCH_DIR}
else
  bench get-app ${repo} --branch ${branch}
fi"
}

_update_frappe_core() {
  _run_heredoc_as_frappe "Update frappe core" \
"cd ${LMS_FRAPPE_BENCH_DIR}/apps/frappe
git fetch --all --prune
git reset --hard origin/${LMS_FRAPPE_BRANCH}
echo 'frappe HEAD: '\$(git log --oneline -1)"
}

_install_app_if_needed() {
  local app_name="$1"
  _run_heredoc_as_frappe "Install ${app_name} if needed" \
"cd ${LMS_FRAPPE_BENCH_DIR}
_installed=\$(bench --site ${LMS_FRAPPE_SITE} list-apps 2>/dev/null | grep -c '^${app_name}\$' || true)
if [[ \${_installed} -gt 0 ]]; then
  echo '${app_name}: already installed'
else
  bench --site ${LMS_FRAPPE_SITE} install-app ${app_name}
  echo '${app_name}: installed'
fi"
}

_open_firewall_ports() {
  local http_port="$1"
  _run_heredoc_as_root "Open firewall ports" \
"set +e
_open_port() {
  local port=\"\$1\" proto=\"\${2:-tcp}\"
  if command -v ufw &>/dev/null; then
    ufw allow \"\${port}/\${proto}\" 2>/dev/null || true
    echo \"ufw: opened \${port}/\${proto}\"
  elif command -v firewall-cmd &>/dev/null; then
    firewall-cmd --permanent --add-port=\"\${port}/\${proto}\" 2>/dev/null || true
    firewall-cmd --reload 2>/dev/null || true
    echo \"firewalld: opened \${port}/\${proto}\"
  else
    echo \"no firewall tool found — open port \${port} in cloud security group\"
  fi
}
_open_port ${LMS_SSH_PORT}
_open_port ${http_port}
[[ '${LMS_ENABLE_HTTPS}' == true ]] && _open_port ${LMS_NGINX_HTTPS_PORT} || true"
}

do_stop() {
  _header "Stop [${_BENCH_ID}]"
  _deploy_log "Action: stop"
  _run_heredoc_as_root "Stop all LMS services" \
"set +e
supervisorctl stop '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl stop '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
systemctl stop ${_SERVICE_NAME} 2>/dev/null || true
systemctl stop ${_CONSUMER_SERVICE_NAME} 2>/dev/null || true
echo 'LMS stopped'"
  _ok "LMS stopped [${_BENCH_ID}]"
}

do_restart() {
  _header "Restart [${_BENCH_ID}]"
  _deploy_log "Action: restart"
  _clear_bench_caches
  _run_heredoc_as_root "Restart supervisor workers" \
"set +e
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5
supervisorctl status 2>/dev/null || true"
  _restart_gunicorn
  _ok "LMS restarted [${_BENCH_ID}]"
}

do_status() {
  _header "Status [${_BENCH_ID}]"
  _deploy_log "Action: status"
  local _sl
  _sl="$(_nginx_listen_port)"
  [[ "$LMS_ENABLE_HTTPS" == "true" ]] && _sl="${LMS_NGINX_HTTPS_PORT}"
  _run_heredoc_as_root "Full LMS status" \
"set +e
echo '=== Supervisor ==='
supervisorctl status 2>/dev/null | grep '${_SUPERVISOR_CONF_NAME}' || echo 'no matching supervisor processes'

echo ''
echo '=== System services ==='
for svc in nginx supervisor ${_SERVICE_NAME} ${_CONSUMER_SERVICE_NAME} rabbitmq-server; do
  printf '  %-40s %s\n' \"\${svc}\" \"\$(systemctl is-active \${svc} 2>/dev/null || echo inactive)\"
done

echo ''
echo '=== Podman containers ==='
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}' 2>/dev/null | grep -E '${_BENCH_ID}|^NAMES' || echo 'no matching containers'

echo ''
echo '=== Redis ==='
redis-cli -h 127.0.0.1 -p ${LMS_REDIS_CACHE_PORT} ping 2>/dev/null | grep -q PONG && echo 'redis-cache: OK' || echo 'redis-cache: NOT RESPONDING'
redis-cli -h 127.0.0.1 -p ${LMS_REDIS_QUEUE_PORT} ping 2>/dev/null | grep -q PONG && echo 'redis-queue: OK' || echo 'redis-queue: NOT RESPONDING'

echo ''
echo '=== RabbitMQ ==='
if command -v rabbitmqctl &>/dev/null; then
  rabbitmqctl status 2>/dev/null | grep -E 'RabbitMQ|uptime|listeners' || echo 'rabbitmq: status unavailable'
else
  systemctl is-active rabbitmq-server 2>/dev/null | grep -q active && echo 'rabbitmq-server: active' || echo 'rabbitmq-server: inactive/not installed'
fi

echo ''
echo '=== Postgres ==='
psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres -c 'SELECT 1' >/dev/null 2>&1 && echo 'postgres: OK' || echo 'postgres: NOT RESPONDING'

echo ''
echo '=== Site DB ==='
if [[ -f '${_SITE_DIR}/site_config.json' ]]; then
  _db_name=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_name',''))\" 2>/dev/null || true)
  _db_pass=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_password',''))\" 2>/dev/null || true)
  PGPASSWORD=\"\${_db_pass}\" psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U \"\${_db_name}\" -d \"\${_db_name}\" -c 'SELECT 1' >/dev/null 2>&1 \
    && echo \"site DB (\${_db_name}): OK\" || echo \"site DB (\${_db_name}): FAILED\"
fi

echo ''
echo '=== Assets ==='
if [[ -f '${_ASSET_MANIFEST_FILE}' ]]; then
  echo \"assets.json: OK (\$(wc -c < '${_ASSET_MANIFEST_FILE}') bytes)\"
else
  echo 'assets.json: MISSING'
fi
[[ -f '${_SITE_ASSET_MANIFEST}' ]] && echo 'site assets.json: OK' || echo 'site assets.json: MISSING'

echo ''
echo '=== Gunicorn ==='
_g_code=\$(curl -s --max-time 30 -H 'X-Frappe-Site-Name: ${LMS_FRAPPE_SITE}' http://127.0.0.1:${LMS_GUNICORN_PORT} -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)
echo \"gunicorn (${LMS_GUNICORN_PORT}): HTTP \${_g_code}\"

echo ''
echo '=== Endpoint ==='
if [[ '${LMS_ENABLE_HTTPS}' == true ]]; then
  _e_code=\$(curl -sk --max-time 30 https://127.0.0.1:${LMS_NGINX_HTTPS_PORT} -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)
  echo \"HTTPS (${LMS_NGINX_HTTPS_PORT}): HTTP \${_e_code}\"
else
  _e_code=\$(curl -s --max-time 30 http://127.0.0.1:${_sl} -o /dev/null -w '%{http_code}' 2>/dev/null || echo 000)
  echo \"HTTP (${_sl}): HTTP \${_e_code}\"
fi

echo ''
echo '=== Disk ==='
df -h /

echo ''
echo '=== Service logs (last 20 lines) ==='
journalctl -u ${_SERVICE_NAME} -n 20 --no-pager 2>/dev/null || true

echo ''
echo '=== Consumer logs (last 20 lines) ==='
journalctl -u ${_CONSUMER_SERVICE_NAME} -n 20 --no-pager 2>/dev/null || true"
}

do_clean_containers() {
  _header "Clean containers [${_BENCH_ID}]"
  _deploy_log "Action: clean-containers"
  _run_heredoc_as_owner "Stop and remove containers" \
"set +e
for container in ${LMS_POSTGRES_CONTAINER} ${LMS_REDIS_CACHE_CONTAINER} ${LMS_REDIS_QUEUE_CONTAINER}; do
  podman stop \"\${container}\" 2>/dev/null || true
  podman rm -f \"\${container}\" 2>/dev/null || true
  echo \"removed container: \${container}\"
done"
  _ok "Containers removed [${_BENCH_ID}]"
}

do_clean_volumes() {
  _header "Clean volumes [${_BENCH_ID}]"
  _deploy_log "Action: clean-volumes"
  _run_heredoc_as_owner "Remove Podman volumes" \
"set +e
for vol in \$(podman volume ls --format '{{.Name}}' 2>/dev/null | grep -E '^lms-${_BENCH_ID}' || true); do
  podman volume rm -f \"\${vol}\" 2>/dev/null || true
  echo \"removed volume: \${vol}\"
done"
  _ok "Volumes removed [${_BENCH_ID}]"
}

do_clean_venv() {
  _header "Clean venv [${_BENCH_ID}]"
  _deploy_log "Action: clean-venv"
  _run_heredoc_as_root "Remove Python virtualenv" \
"set +e
if [[ -d '${_VENV_DIR}' ]]; then
  rm -rf '${_VENV_DIR}'
  echo 'venv removed: ${_VENV_DIR}'
else
  echo 'venv not found — skipping'
fi"
  _ok "Venv removed [${_BENCH_ID}]"
}

do_clean_dirs() {
  _header "Clean dirs [${_BENCH_ID}]"
  _deploy_log "Action: clean-dirs"
  if ! $LMS_FORCE; then
    [[ -t 0 ]] || _die "--clean-dirs requires --force or interactive terminal"
    read -rp "  Confirm wipe of bench dir '${LMS_FRAPPE_BENCH_DIR}'? [y/N] " _confirm
    [[ "${_confirm,,}" == "y" ]] || { _info "Cancelled."; return 0; }
  fi
  _run_heredoc_as_root "Wipe bench dir and site DB" \
"set +e

_pg_reachable() {
  PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql \
    -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
    -c 'SELECT 1' >/dev/null 2>&1
}

if _pg_reachable; then
  _site_db=\$(echo '${LMS_FRAPPE_SITE}' | tr '.' '_' | tr '-' '_')
  PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
    -c \"DROP DATABASE IF EXISTS \\\"\${_site_db}\\\";\" 2>/dev/null || true

  if [[ -f '${_SITE_DIR}/site_config.json' ]]; then
    _db_name=\$(python3 -c \"import json; c=json.load(open('${_SITE_DIR}/site_config.json')); print(c.get('db_name',''))\" 2>/dev/null || true)
    if [[ -n \"\${_db_name:-}\" ]]; then
      PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
        -c \"DROP DATABASE IF EXISTS \\\"\${_db_name}\\\";\" 2>/dev/null || true
      PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
        -c \"DROP ROLE IF EXISTS \\\"\${_db_name}\\\";\" 2>/dev/null || true
    fi
  fi
  echo 'postgres: site DB dropped'
else
  echo 'postgres unreachable — skipping DB cleanup (container likely removed)'
fi

if [[ -d '${LMS_FRAPPE_BENCH_DIR}' ]]; then
  rm -rf '${LMS_FRAPPE_BENCH_DIR}'
  echo 'bench dir removed: ${LMS_FRAPPE_BENCH_DIR}'
else
  echo 'bench dir not found — skipping'
fi"
  _ok "Bench dir wiped [${_BENCH_ID}]"
}

do_clean_services() {
  _header "Clean services [${_BENCH_ID}]"
  _deploy_log "Action: clean-services"

  _run_heredoc_as_root "Remove systemd units" \
"set +e
for _svc in ${_SERVICE_NAME} ${_CONSUMER_SERVICE_NAME}; do
  systemctl stop \"\${_svc}\" 2>/dev/null || true
  systemctl disable \"\${_svc}\" 2>/dev/null || true
  rm -f \"/etc/systemd/system/\${_svc}.service\" 2>/dev/null || true
done
systemctl daemon-reload 2>/dev/null || true
echo 'systemd units removed'"

  _run_heredoc_as_root "Remove supervisor config" \
"set +e
supervisorctl stop '${_SUPERVISOR_CONF_NAME}-web:' 2>/dev/null || true
supervisorctl stop '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
rm -f '/etc/supervisor/conf.d/${_SUPERVISOR_CONF_NAME}.conf' 2>/dev/null || true
supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true
echo 'supervisor config removed'"

  _run_heredoc_as_root "Remove nginx config" \
"set +e
rm -f '/etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf' 2>/dev/null || true
rm -f '/etc/nginx/sites-enabled/${_NGINX_CONF_NAME}.conf' 2>/dev/null || true
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
echo 'nginx config removed'"

  _ok "Services cleaned [${_BENCH_ID}]"
}

do_full_clean() {
  _header "Full clean [${_BENCH_ID}]"
  _deploy_log "Action: full clean"

  _warn "This will permanently wipe:"
  _warn "  Systemd:    ${_SERVICE_NAME}, ${_CONSUMER_SERVICE_NAME}"
  _warn "  Supervisor: ${_SUPERVISOR_CONF_NAME}.conf"
  _warn "  Nginx:      ${_NGINX_CONF_NAME}.conf"
  _warn "  Bench dir:  ${LMS_FRAPPE_BENCH_DIR}"
  _warn "  Site DB:    ${LMS_FRAPPE_SITE}"
  _warn "  Containers: ${LMS_POSTGRES_CONTAINER}, ${LMS_REDIS_CACHE_CONTAINER}, ${LMS_REDIS_QUEUE_CONTAINER}"
  _warn "  Volumes:    all lms-${_BENCH_ID}-* volumes"

  if ! $LMS_FORCE; then
    [[ -t 0 ]] || _die "--clean requires --force or interactive terminal"
    read -rp "  Confirm full wipe of '${_BENCH_ID}'? [y/N] " _confirm
    [[ "${_confirm,,}" == "y" ]] || { _info "Clean cancelled."; return 0; }
  fi

  do_clean_services
  do_clean_dirs
  do_clean_containers
  do_clean_volumes
  do_clean_venv

  _ok "Full clean complete [${_BENCH_ID}]"
  _deploy_log "Full clean complete"
}

do_update() {
  _header "Update [${_BENCH_ID}]"
  _deploy_log "Action: update"

  if ! $LMS_DRY_RUN; then
    local _bench_ok
    _bench_ok=$(ssh "${SSH_BASE_OPTS[@]}" "$TARGET" \
      "test -d '${LMS_FRAPPE_BENCH_DIR}/apps/tap_lms' && echo yes || echo no" 2>/dev/null || echo no)
    if [[ "$_bench_ok" != "yes" ]]; then
      _warn "Bench not found — falling back to full deploy"
      LMS_UPDATE_ONLY=false
      return 0
    fi
  fi

  _update_frappe_core
  _get_app_or_update "tap_lms"            "${LMS_GIT_REPO}"            "${LMS_GIT_BRANCH}"
  _get_app_or_update "business_theme_v14" "${LMS_BUSINESS_THEME_REPO}" "${LMS_BUSINESS_THEME_BRANCH}"

  _run_heredoc_as_frappe "pip install updated deps" \
"cd ${LMS_FRAPPE_BENCH_DIR}
source ${_VENV_DIR}/bin/activate
pip install -e apps/frappe -q 2>&1 | tail -3
pip install -e apps/tap_lms -q 2>&1 | tail -3
pip install -e apps/business_theme_v14 -q 2>&1 | tail -3 || true"

  _run_heredoc_as_frappe "bench migrate" \
"cd ${LMS_FRAPPE_BENCH_DIR}
bench --site ${LMS_FRAPPE_SITE} migrate
bench --site ${LMS_FRAPPE_SITE} set-maintenance-mode off"

  _build_assets
  _clear_bench_caches

  _run_heredoc_as_root "Restart workers" \
"set +e
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5
supervisorctl status 2>/dev/null || true"

  _restart_gunicorn
  _ok "Update complete [${_BENCH_ID}]"
  _deploy_log "Update complete"
}

do_update_config() {
  _header "Update config [${_BENCH_ID}]"
  _deploy_log "Action: update-config"

  if ! $LMS_DRY_RUN; then
    local _bench_ok
    _bench_ok=$(ssh "${SSH_BASE_OPTS[@]}" "$TARGET" \
      "test -d '${LMS_FRAPPE_BENCH_DIR}/apps/tap_lms' && echo yes || echo no" 2>/dev/null || echo no)
    [[ "$_bench_ok" == "yes" ]] || _die "Bench not found — run full deploy first"
  fi

  _write_common_site_config

  _run_heredoc_as_frappe "Update site config" \
"cd ${LMS_FRAPPE_BENCH_DIR}
bench --site ${LMS_FRAPPE_SITE} set-config db_host '${LMS_PG_HOST}'
bench --site ${LMS_FRAPPE_SITE} set-config db_port ${LMS_PG_PORT}
bench --site ${LMS_FRAPPE_SITE} set-config server_script_enabled true

if [[ '${LMS_DEPLOY_DOMAIN}' == true ]]; then
  _proto=http
  [[ '${LMS_ENABLE_HTTPS}' == true ]] && _proto=https
  bench --site ${LMS_FRAPPE_SITE} set-config host_name \"\${_proto}://${LMS_DOMAIN_NAME}\"
else
  bench --site ${LMS_FRAPPE_SITE} set-config host_name 'http://${LMS_SERVER_HOST}:${LMS_WEB_PORT}'
fi"

  _write_pgpass
  _clear_bench_caches

  _run_heredoc_as_root "Restart workers" \
"set +e
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5"

  _wait_if_needed 5
  _restart_gunicorn

  _ok "Config updated [${_BENCH_ID}]"
  _deploy_log "update-config complete"
}

_run_step0() {
  if [[ -n "${LMS_SERVER_SUDO_PASSWORD:-}" ]]; then
    _grant_nopasswd_sudo
    _ok "Passwordless sudo configured"
  else
    _info "LMS_SERVER_SUDO_PASSWORD not set — assuming sudo is already passwordless"
  fi
}

_run_step1() {
  _run_heredoc_as_root "Install system packages" \
'export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  build-essential curl git vim netcat-openbsd \
  python3-pip python3-venv virtualenv software-properties-common \
  postgresql-client redis-tools redis-server \
  supervisor \
  xvfb libfontconfig wkhtmltopdf \
  nginx fail2ban cron npm \
  openssl \
  rabbitmq-server \
  2>&1 | tail -5

systemctl stop redis-server 2>/dev/null || true
systemctl disable redis-server 2>/dev/null || true
systemctl mask redis-server 2>/dev/null || true
echo "system redis-server masked"

_rmq_active=$(systemctl is-active rabbitmq-server 2>/dev/null || echo inactive)
if [[ "${_rmq_active}" != "active" ]]; then
  systemctl enable rabbitmq-server 2>/dev/null || true
  systemctl start rabbitmq-server
  echo "rabbitmq-server started"
else
  echo "rabbitmq-server already running"
fi'

  _run_heredoc_as_root "Install python version if needed" \
"if ! ${LMS_PYTHON_VERSION} --version &>/dev/null 2>&1; then
  add-apt-repository ppa:deadsnakes/ppa -y 2>/dev/null || true
  apt-get update -qq
  _pyver=\$(echo '${LMS_PYTHON_VERSION}' | sed 's/python//')
  apt-get install -y -qq python\${_pyver} python\${_pyver}-dev python\${_pyver}-venv python\${_pyver}-distutils 2>&1 | tail -3
fi"

  _run_heredoc_as_root "Install podman" \
'if ! command -v podman &>/dev/null; then
  if apt-cache show podman &>/dev/null 2>&1; then
    apt-get install -y -qq podman 2>&1 | tail -3
  else
    apt-get install -y -qq podman-docker 2>&1 | tail -3 || \
    curl -fsSL https://raw.githubusercontent.com/containers/podman/main/contrib/podmansetup/podman-setup.sh \
      | bash -s -- --quiet 2>&1 | tail -5 || true
  fi
fi
command -v podman &>/dev/null || { echo "FATAL: podman not installed" >&2; exit 1; }'

  _run_heredoc_as_root "Write nginx main config" \
"loginctl enable-linger '${LMS_SERVICE_OWNER}' 2>/dev/null || true
cat > /etc/nginx/nginx.conf <<'NGINXMAIN'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /run/nginx.pid;

events {
    worker_connections 2048;
    use epoll;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;
    client_max_body_size 50m;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    access_log /var/log/nginx/access.log;
    error_log /var/log/nginx/error.log;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}
NGINXMAIN"

  _run_heredoc_as_root "Install frappe-bench and yarn" \
'apt-get clean
rm -rf /var/lib/apt/lists/*
if command -v pip3 &>/dev/null; then
  pip3 install frappe-bench --break-system-packages -q 2>&1 | tail -2
else
  python3 -m pip install frappe-bench --break-system-packages -q 2>&1 | tail -2
fi
npm install -g yarn -q 2>&1 | tail -2
echo "podman: $(podman --version)"
echo "yarn: $(yarn --version)"'

  _ok "System packages installed"
}

_run_step2() {
  _run_heredoc_as_owner "Start infrastructure containers" \
"_uid=\$(id -u)
export XDG_RUNTIME_DIR=/run/user/\${_uid}
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\${_uid}/bus
loginctl enable-linger \$(whoami) 2>/dev/null || true

_start_container() {
  local name=\"\$1\" run_args=\"\$2\"
  podman stop \"\${name}\" 2>/dev/null || true
  podman rm -f \"\${name}\" 2>/dev/null || true
  eval podman run -d --name \"\${name}\" --restart=always \${run_args}
  echo \"started: \${name}\"
}

podman pull ${LMS_POSTGRES_IMAGE} 2>/dev/null || true
_start_container '${LMS_POSTGRES_CONTAINER}' \
  '-e POSTGRES_PASSWORD=${LMS_POSTGRES_PASSWORD} -p ${LMS_PG_HOST}:${LMS_PG_PORT}:5432 ${LMS_POSTGRES_IMAGE}'

podman pull ${LMS_REDIS_IMAGE} 2>/dev/null || true
_start_container '${LMS_REDIS_CACHE_CONTAINER}' \
  '-p 127.0.0.1:${LMS_REDIS_CACHE_PORT}:6379 ${LMS_REDIS_IMAGE} redis-server --maxmemory ${LMS_REDIS_MAXMEMORY} --maxmemory-policy ${LMS_REDIS_MAXMEMORY_POLICY} --save \"\"'
_start_container '${LMS_REDIS_QUEUE_CONTAINER}' \
  '-p 127.0.0.1:${LMS_REDIS_QUEUE_PORT}:6379 ${LMS_REDIS_IMAGE} redis-server --maxmemory ${LMS_REDIS_MAXMEMORY} --maxmemory-policy ${LMS_REDIS_MAXMEMORY_POLICY}'

_i=0
while [[ \${_i} -lt 60 ]]; do
  _i=\$(( _i + 1 ))
  PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres -c 'SELECT 1' >/dev/null 2>&1 && echo 'postgres: ready' && break
  sleep 3
  [[ \${_i} -eq 60 ]] && { echo 'FATAL: postgres not ready after 180s' >&2; exit 1; }
done

_wait_redis() {
  local port=\"\$1\" label=\"\$2\" _i=0
  while [[ \${_i} -lt 40 ]]; do
    _i=\$(( _i + 1 ))
    redis-cli -h 127.0.0.1 -p \"\${port}\" ping 2>/dev/null | grep -q PONG && echo \"\${label}: OK\" && return 0
    sleep 3
  done
  echo \"FATAL: \${label} not ready\" >&2; exit 1
}
_wait_redis ${LMS_REDIS_CACHE_PORT} redis-cache
_wait_redis ${LMS_REDIS_QUEUE_PORT} redis-queue"

  _run_heredoc_as_root "Create frappe OS user and configure postgres" \
"set +e
id ${LMS_FRAPPE_USER} &>/dev/null || useradd -ms /bin/bash ${LMS_FRAPPE_USER}
grep -qxF '${LMS_FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL' /etc/sudoers \
  || echo '${LMS_FRAPPE_USER} ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
chmod 755 /home/${LMS_FRAPPE_USER}
usermod -a -G ${LMS_FRAPPE_USER} www-data 2>/dev/null || true
mkdir -p /home/${LMS_FRAPPE_USER}/logs
chown -R ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} /home/${LMS_FRAPPE_USER}/logs

_i=0
while [[ \${_i} -lt 40 ]]; do
  _i=\$(( _i + 1 ))
  PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres -c 'SELECT 1' >/dev/null 2>&1 && echo 'postgres: OK' && break
  sleep 3
  [[ \${_i} -eq 40 ]] && { echo 'FATAL: postgres not ready' >&2; exit 1; }
done

PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
  -c \"ALTER USER postgres WITH SUPERUSER CREATEDB CREATEROLE PASSWORD '${LMS_POSTGRES_PASSWORD}';\"
PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres -d template1 \
  -c 'GRANT ALL ON SCHEMA public TO PUBLIC;'
PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres -d template1 \
  -c 'ALTER SCHEMA public OWNER TO postgres;'
echo 'postgres configured'"

  _write_pgpass
  _ok "Containers and postgres ready"
}

_run_step3() {
  _run_heredoc_as_frappe "Install NVM and Node ${LMS_NODE_VERSION}" \
"export NVM_DIR=\"\${HOME}/.nvm\"
if [[ ! -s \"\${NVM_DIR}/nvm.sh\" ]]; then
  curl -fsSL ${LMS_NVM_INSTALL_URL} | bash
fi
source \"\${NVM_DIR}/nvm.sh\"
nvm install ${LMS_NODE_VERSION}
nvm use ${LMS_NODE_VERSION}
nvm alias default ${LMS_NODE_VERSION}
npm install -g yarn
echo \"node: \$(node --version)\"
echo \"yarn: \$(yarn --version)\""
  _ok "NVM and Node ready"
}

_run_step4() {
  _install_supervisorctl_shim

  _run_heredoc_as_frappe "bench init" \
"if [[ -d ${LMS_FRAPPE_BENCH_DIR} ]]; then
  echo 'bench dir exists — skipping init'
else
  export UV_LINK_MODE=copy
  bench init ${LMS_FRAPPE_BENCH_DIR} \
    --frappe-branch ${LMS_FRAPPE_BRANCH} \
    --python ${LMS_PYTHON_VERSION} \
    --skip-assets \
    --no-procfile \
    --no-backups
fi
mkdir -p ${_BENCH_LOGS_DIR} ${_SITES_DIR}/logs
chown -R ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} ${_BENCH_LOGS_DIR} ${_SITES_DIR}/logs 2>/dev/null || true
echo 'bench init done'"

  _run_heredoc_as_frappe "Install frappe Python dependencies" \
"export UV_LINK_MODE=copy
cd ${LMS_FRAPPE_BENCH_DIR}
if [[ -f ${_VENV_DIR}/bin/activate ]]; then
  source ${_VENV_DIR}/bin/activate
else
  ${LMS_PYTHON_VERSION} -m venv ${_VENV_DIR}
  source ${_VENV_DIR}/bin/activate
fi
if command -v uv &>/dev/null; then
  UV_LINK_MODE=copy uv pip install --upgrade -e apps/frappe --python ${_VENV_DIR}/bin/python
else
  pip install --upgrade -e apps/frappe -q
fi
python -c 'import importlib.metadata; v=importlib.metadata.version(\"werkzeug\"); print(\"werkzeug OK:\", v)'
echo 'frappe deps installed'"

  _write_common_site_config
  _ok "Frappe bench initialised"
}

_run_step5() {
  _run_heredoc_as_owner "Ensure containers running" \
"set +e
_ensure_container() {
  local name=\"\$1\"
  local state
  state=\$(podman inspect --format '{{.State.Status}}' \"\${name}\" 2>/dev/null || echo missing)
  if [[ \"\${state}\" != running ]]; then
    podman start \"\${name}\" 2>/dev/null || true
    sleep 3
  fi
  echo \"\${name}: \$(podman inspect --format '{{.State.Status}}' \"\${name}\" 2>/dev/null || echo missing)\"
}
_ensure_container '${LMS_POSTGRES_CONTAINER}'
_ensure_container '${LMS_REDIS_CACHE_CONTAINER}'
_ensure_container '${LMS_REDIS_QUEUE_CONTAINER}'

_wait_redis() {
  local port=\"\$1\" label=\"\$2\" _i=0
  while [[ \${_i} -lt 30 ]]; do
    _i=\$(( _i + 1 ))
    redis-cli -h 127.0.0.1 -p \"\${port}\" ping 2>/dev/null | grep -q PONG && echo \"\${label}: OK\" && return 0
    sleep 3
  done
  echo \"FATAL: \${label} not ready\" >&2; exit 1
}
_wait_redis ${LMS_REDIS_CACHE_PORT} redis-cache
_wait_redis ${LMS_REDIS_QUEUE_PORT} redis-queue"

  _run_heredoc_as_root "Verify postgres" \
"_i=0
while [[ \${_i} -lt 30 ]]; do
  _i=\$(( _i + 1 ))
  PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres -c 'SELECT 1' >/dev/null 2>&1 && echo 'postgres: OK' && break
  sleep 3
  [[ \${_i} -eq 30 ]] && { echo 'FATAL: postgres not ready' >&2; exit 1; }
done"
  _ok "Containers verified"
}

_run_step6() {
  _run_heredoc_as_root "Check and clean stale site" \
"set +e
_site_db=\$(echo '${LMS_FRAPPE_SITE}' | tr '.' '_' | tr '-' '_')

if [[ -d '${_SITE_DIR}' && -f '${_SITE_DIR}/site_config.json' ]]; then
  _db_user=\$(python3 -c \"
import json
try:
  cfg = json.load(open('${_SITE_DIR}/site_config.json'))
  print(cfg.get('db_name',''))
except: print('')
\" 2>/dev/null || true)
  _db_pass=\$(python3 -c \"
import json
try:
  cfg = json.load(open('${_SITE_DIR}/site_config.json'))
  print(cfg.get('db_password',''))
except: print('')
\" 2>/dev/null || true)

  _conn_ok=1
  if [[ -n \"\${_db_user}\" ]]; then
    PGPASSWORD=\"\${_db_pass}\" psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} \
      -U \"\${_db_user}\" -d \"\${_db_user}\" -c 'SELECT 1' >/dev/null 2>&1
    _conn_ok=\$?
  fi

  if [[ \${_conn_ok} -ne 0 ]]; then
    echo 'stale site detected — wiping'
    PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
      -c \"DROP DATABASE IF EXISTS \\\"\${_db_user}\\\";\" 2>/dev/null || true
    PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
      -c \"DROP DATABASE IF EXISTS \\\"\${_site_db}\\\";\" 2>/dev/null || true
    PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres \
      -c \"DROP ROLE IF EXISTS \\\"\${_db_user}\\\";\" 2>/dev/null || true
    rm -rf '${_SITE_DIR}'
    echo 'stale site wiped'
  else
    echo 'site DB OK — keeping existing site'
  fi
elif [[ -d '${_SITE_DIR}' && ! -f '${_SITE_DIR}/site_config.json' ]]; then
  rm -rf '${_SITE_DIR}'
  echo 'incomplete site dir wiped'
else
  echo 'no existing site'
fi"

  _run_heredoc_as_frappe "bench new-site" \
"cd ${LMS_FRAPPE_BENCH_DIR}
if [[ -d '${_SITE_DIR}' && -f '${_SITE_DIR}/site_config.json' ]]; then
  echo 'site exists and healthy — skipping new-site'
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

if [[ '${LMS_DEPLOY_DOMAIN}' == true ]]; then
  _proto=http
  [[ '${LMS_ENABLE_HTTPS}' == true ]] && _proto=https
  bench --site ${LMS_FRAPPE_SITE} set-config host_name \"\${_proto}://${LMS_DOMAIN_NAME}\"
else
  bench --site ${LMS_FRAPPE_SITE} set-config host_name 'http://${LMS_SERVER_HOST}:${LMS_WEB_PORT}'
fi

echo '${LMS_FRAPPE_SITE}' > ${_SITES_DIR}/currentsite.txt
mkdir -p ${_SITE_LOGS_DIR} ${_SITE_LOGS_ALT}
chown -R ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} ${_SITE_LOGS_DIR} ${_SITE_LOGS_ALT} 2>/dev/null || true
echo 'site ready'"

  _run_heredoc_as_root "Ensure site DB role" \
"set +e
[[ ! -f '${_SITE_DIR}/site_config.json' ]] && exit 0

_db_name=\$(python3 -c \"
import json
try:
  c = json.load(open('${_SITE_DIR}/site_config.json'))
  print(c.get('db_name',''))
except: print('')
\" 2>/dev/null || true)

_db_pass=\$(python3 -c \"
import json
try:
  c = json.load(open('${_SITE_DIR}/site_config.json'))
  print(c.get('db_password',''))
except: print('')
\" 2>/dev/null || true)

[[ -z \"\${_db_name}\" || -z \"\${_db_pass}\" ]] && exit 0

PGPASSWORD='${LMS_POSTGRES_PASSWORD}' psql \
  -h ${LMS_PG_HOST} -p ${LMS_PG_PORT} -U postgres -v ON_ERROR_STOP=0 <<PGSQL
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
\\\\c \"\${_db_name}\"
GRANT ALL ON SCHEMA public TO \"\${_db_name}\";
ALTER SCHEMA public OWNER TO \"\${_db_name}\";
PGSQL
echo \"role ensured: \${_db_name}\""

  _write_pgpass
  _ok "Frappe site ready"
}

_run_step7() {
  _get_app_or_update "tap_lms" "${LMS_GIT_REPO}" "${LMS_GIT_BRANCH}"
  _install_app_if_needed "tap_lms"
  _ok "tap_lms installed"
}

_run_step8() {
  _get_app_or_update "business_theme_v14" "${LMS_BUSINESS_THEME_REPO}" "${LMS_BUSINESS_THEME_BRANCH}"
  _install_app_if_needed "business_theme_v14"
  _remove_supervisorctl_shim
  _ok "business_theme_v14 installed"
}

_run_step9() {
  _run_heredoc_as_frappe "migrate + scheduler" \
"cd ${LMS_FRAPPE_BENCH_DIR}
bench --site ${LMS_FRAPPE_SITE} migrate
bench --site ${LMS_FRAPPE_SITE} enable-scheduler
bench --site ${LMS_FRAPPE_SITE} set-maintenance-mode off
echo 'migrate done'"
  _ok "Migrations applied"
}

_run_step10() {
  [[ "$LMS_ENABLE_HTTPS" == "true" ]] && _ensure_tls_cert

  local _NGINX_CONF_CONTENT
  _NGINX_CONF_CONTENT="$(_build_nginx_conf)"

  _run_heredoc_as_frappe "bench setup supervisor" \
"cd ${LMS_FRAPPE_BENCH_DIR}
bench setup supervisor --yes
echo 'supervisor config generated'"

  local _NGINX_TMP _NGINX_REMOTE_TMP
  _NGINX_TMP=$(mktemp)
  _NGINX_REMOTE_TMP="/tmp/lms-nginx-${_BENCH_ID}-$$.conf"
  printf '%s\n' "${_NGINX_CONF_CONTENT}" > "${_NGINX_TMP}"
  if ! $LMS_DRY_RUN; then
    scp "${SCP_BASE_OPTS[@]}" "${_NGINX_TMP}" "${TARGET}:${_NGINX_REMOTE_TMP}"
  fi
  rm -f "${_NGINX_TMP}"

  _run_heredoc_as_root "Install supervisor and nginx configs" \
"set +e
supervisorctl stop 'frappe-bench-web:' 2>/dev/null || true
supervisorctl stop 'frappe-bench-workers:' 2>/dev/null || true
for _old in /etc/supervisor/conf.d/frappe-bench*.conf; do
  [[ -f \"\${_old}\" ]] || continue
  rm -f \"\${_old}\"
done
supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true

if [[ -f '${LMS_FRAPPE_BENCH_DIR}/config/supervisor.conf' ]]; then
  python3 - <<'PYEOF'
import re, pathlib, sys

src = pathlib.Path('${LMS_FRAPPE_BENCH_DIR}/config/supervisor.conf')
dst = pathlib.Path('/etc/supervisor/conf.d/${_SUPERVISOR_CONF_NAME}.conf')
if not src.exists():
    print('ERROR: supervisor.conf not found', file=sys.stderr)
    sys.exit(1)

txt = src.read_text()
txt = re.sub(r'\[(?:program|group):[^\]]*redis[^\]]*\][^\[]*', '', txt, flags=re.DOTALL|re.IGNORECASE)
txt = re.sub(r'(?m)^programs\s*=.*redis.*\n', '', txt, flags=re.IGNORECASE)
txt = re.sub(r'\[program:[^\]]*frappe-web[^\]]*\][^\[]*', '', txt, flags=re.DOTALL|re.IGNORECASE)
txt = re.sub(r'(?m)^programs\s*=\s*(.*)\n', lambda m: 'programs=' + ','.join(
    p.strip() for p in m.group(1).split(',')
    if 'frappe-web' not in p.lower() and 'redis' not in p.lower()
) + '\n', txt, flags=re.IGNORECASE)
txt = re.sub(r'\[group:[^\]]*-web\]',     '[group:${_SUPERVISOR_CONF_NAME}-web]',     txt)
txt = re.sub(r'\[group:[^\]]*-workers\]', '[group:${_SUPERVISOR_CONF_NAME}-workers]', txt)
dst.write_text(txt)
print(f'supervisor config written: {dst}')
PYEOF
fi

rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
rm -f /etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/${_NGINX_CONF_NAME}.conf 2>/dev/null || true

if [[ -f '${_NGINX_REMOTE_TMP}' ]]; then
  mv '${_NGINX_REMOTE_TMP}' /etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf
  chown root:root /etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf
  chmod 644 /etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf
else
  echo 'FATAL: nginx config not found' >&2; exit 1
fi

nginx -t && systemctl reload nginx && echo 'nginx reloaded OK' \
  || { cat /etc/nginx/conf.d/${_NGINX_CONF_NAME}.conf >&2; echo 'FATAL: nginx config invalid' >&2; exit 1; }

systemctl enable supervisor
supervisorctl reread 2>&1 || true
supervisorctl update 2>&1 || true
supervisorctl status 2>/dev/null || true"
  _ok "Supervisor and Nginx configured"
}

_run_step11() {
  _ensure_log_dirs
  _ok "Log directories ready"
}

_run_step12() {
  local _WORKERS="${LMS_GUNICORN_WORKERS}"
  if [[ "${_WORKERS}" -le 0 ]]; then
    _WORKERS=$(ssh "${SSH_BASE_OPTS[@]}" "$TARGET" "nproc 2>/dev/null || echo 2" 2>/dev/null | tr -d '[:space:]')
    _WORKERS=$(( (_WORKERS * 2) + 1 ))
  fi
  _info "Gunicorn workers: ${_WORKERS}"

  _run_heredoc_as_root "Install gunicorn and consumer systemd units" \
"cat > '${_SYSTEMD_UNIT}' <<'UNITEOF'
[Unit]
Description=LMS Gunicorn (${_BENCH_ID}) port ${LMS_GUNICORN_PORT}
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=${LMS_FRAPPE_USER}
Group=${LMS_FRAPPE_USER}
WorkingDirectory=${_SITES_DIR}
Environment=HOME=/home/${LMS_FRAPPE_USER}
Environment=SITES_PATH=${_SITES_DIR}
Environment=BENCH_PATH=${LMS_FRAPPE_BENCH_DIR}
Environment=FRAPPE_SITE=${LMS_FRAPPE_SITE}
ExecStart=${_VENV_DIR}/bin/gunicorn \
  --chdir ${_SITES_DIR} \
  --bind 127.0.0.1:${LMS_GUNICORN_PORT} \
  --workers ${_WORKERS} \
  --worker-class sync \
  --preload \
  --timeout 120 \
  --graceful-timeout 30 \
  --max-requests 1000 \
  --max-requests-jitter 50 \
  frappe.app:application
Restart=on-failure
RestartSec=30
TimeoutStopSec=60
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${_SERVICE_NAME}

[Install]
WantedBy=multi-user.target
UNITEOF
chown root:root '${_SYSTEMD_UNIT}'
chmod 644 '${_SYSTEMD_UNIT}'

_consumer_active=\$(systemctl is-active '${_CONSUMER_SERVICE_NAME}' 2>/dev/null || echo inactive)
if [[ \"\${_consumer_active}\" == active ]]; then
  systemctl stop '${_CONSUMER_SERVICE_NAME}' 2>/dev/null || true
fi

_CONSUMER_WRAPPER=${LMS_FRAPPE_BENCH_DIR}/lms-consumer-run.py
cat > \"\${_CONSUMER_WRAPPER}\" <<PYEOF
import frappe
frappe.init(site=\"${LMS_FRAPPE_SITE}\", sites_path=\"${_SITES_DIR}\")
frappe.connect()
from tap_lms.feedback_consumer.feedback_consumer import FeedbackConsumer
c = FeedbackConsumer()
c.setup_rabbitmq()
c.start_consuming()
PYEOF
chown ${LMS_FRAPPE_USER}:${LMS_FRAPPE_USER} \"\${_CONSUMER_WRAPPER}\"
chmod 750 \"\${_CONSUMER_WRAPPER}\"

cat > '${_CONSUMER_SYSTEMD_UNIT}' <<CONSUMEREOF
[Unit]
Description=LMS Feedback Consumer (${_BENCH_ID})
After=network.target rabbitmq-server.service
Wants=rabbitmq-server.service
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
User=${LMS_FRAPPE_USER}
Group=${LMS_FRAPPE_USER}
WorkingDirectory=${LMS_FRAPPE_BENCH_DIR}
Environment=HOME=/home/${LMS_FRAPPE_USER}
Environment=BENCH_PATH=${LMS_FRAPPE_BENCH_DIR}
Environment=FRAPPE_SITE=${LMS_FRAPPE_SITE}
ExecStart=${_VENV_DIR}/bin/python ${LMS_FRAPPE_BENCH_DIR}/lms-consumer-run.py
Restart=on-failure
RestartSec=15
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${_CONSUMER_SERVICE_NAME}

[Install]
WantedBy=multi-user.target
CONSUMEREOF
chown root:root '${_CONSUMER_SYSTEMD_UNIT}'
chmod 644 '${_CONSUMER_SYSTEMD_UNIT}'

systemctl daemon-reload
systemctl enable '${_SERVICE_NAME}'
systemctl enable '${_CONSUMER_SERVICE_NAME}'
echo 'systemd units installed: ${_SERVICE_NAME}, ${_CONSUMER_SERVICE_NAME}'"
  _ok "Gunicorn and consumer service units installed (workers: ${_WORKERS})"
}

_run_step13() {
  _build_assets

  _run_heredoc_as_root "Start supervisor workers" \
"set +e
_conf='/etc/supervisor/conf.d/${_SUPERVISOR_CONF_NAME}.conf'
[[ -f \"\${_conf}\" ]] || { echo 'ERROR: supervisor config missing' >&2; exit 1; }
supervisorctl reread 2>&1 || true
supervisorctl update 2>&1 || true
supervisorctl start '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 8
supervisorctl status 2>/dev/null || true"

  _ensure_log_dirs
  _ok "Assets built and workers started"
}

_run_step14() {
  _clear_redis_asset_cache
  _restart_gunicorn

  _wait_if_needed 20

  _run_heredoc_as_root "Verify gunicorn responding" \
"set +e
for _i in \$(seq 1 15); do
  _code=\$(curl -s --max-time 30 \
    -H 'X-Frappe-Site-Name: ${LMS_FRAPPE_SITE}' \
    -o /dev/null -w '%{http_code}' \
    http://127.0.0.1:${LMS_GUNICORN_PORT} 2>/dev/null || echo 000)
  case \"\${_code}\" in
    200|301|302|303|401|403|404)
      echo \"gunicorn OK: HTTP \${_code}\"
      break ;;
    *)
      echo \"attempt \${_i}/15 — HTTP \${_code} — waiting 10s\"
      sleep 10
      ;;
  esac
  if [[ \${_i} -eq 15 ]]; then
    echo 'WARNING: gunicorn not healthy after 150s'
    journalctl -u ${_SERVICE_NAME} -n 50 --no-pager 2>/dev/null || true
  fi
done"

  _run_heredoc_as_root "Restart workers post-gunicorn" \
"set +e
supervisorctl restart '${_SUPERVISOR_CONF_NAME}-workers:' 2>/dev/null || true
sleep 5
supervisorctl status 2>/dev/null || true"

  _info "${_CONSUMER_SERVICE_NAME}: installed and enabled — start manually after configuring RabbitMQ settings"

  do_status
  _ok "Final checks complete"
}

_run_step15() {
  local _fw_port
  _fw_port="$(_nginx_listen_port)"
  if [[ "${LMS_OPEN_FIREWALL_PORT}" == "true" ]]; then
    _open_firewall_ports "${_fw_port}" || true
    _warn "Also verify port ${_fw_port} is open in your cloud security group / NSG."
    [[ "$LMS_ENABLE_HTTPS" == "true" ]] && _warn "Also verify port ${LMS_NGINX_HTTPS_PORT} is open."
  else
    _info "Step 15 — firewall skipped (LMS_OPEN_FIREWALL_PORT=false)"
  fi
}

_header "Pre-flight [${_BENCH_ID}]"
_deploy_log "=== LMS Deploy session started ==="
_deploy_log "Config: ${LMS_CONFIG_FILE}"
_deploy_log "Target: ${TARGET}:${LMS_SSH_PORT}"
_deploy_log "Bench:  ${LMS_FRAPPE_BENCH_DIR}"

[[ -f "$LMS_SSH_KEY_PATH" ]] || _die "SSH key not found: $LMS_SSH_KEY_PATH"
chmod 600 "$LMS_SSH_KEY_PATH"
_ok "SSH key OK"

if ! $LMS_DRY_RUN; then
  _info "Testing SSH to ${TARGET}:${LMS_SSH_PORT}..."
  _SSH_ATTEMPT=0
  _SSH_OK=false
  while [[ $_SSH_ATTEMPT -lt 3 ]]; do
    _SSH_ATTEMPT=$(( _SSH_ATTEMPT + 1 ))
    if _ssh_verify; then
      _SSH_OK=true
      break
    fi
    _warn "SSH attempt ${_SSH_ATTEMPT}/3 failed — retry in 3s"
    sleep 3
  done

  if ! $_SSH_OK; then
    _warn "Attempting known_hosts fix..."
    _KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts"
    mkdir -p "${HOME}/.ssh"
    ssh-keyscan -H -p "${LMS_SSH_PORT}" "${LMS_SERVER_HOST}" >> "$_KNOWN_HOSTS_FILE" 2>/dev/null \
      || _die "ssh-keyscan failed for ${LMS_SERVER_HOST}:${LMS_SSH_PORT}"
    chmod 600 "$_KNOWN_HOSTS_FILE"
    _ssh_verify || _die "Cannot connect to ${TARGET}:${LMS_SSH_PORT}"
  fi
fi
_ok "SSH verified → ${TARGET}"

if [[ "$LMS_ENABLE_HTTPS" == "true" ]]; then
  _info "Deploy mode: HTTPS  → $(_effective_url)"
elif [[ "$LMS_DEPLOY_DOMAIN" == "true" ]]; then
  _info "Deploy mode: DOMAIN → $(_effective_url)"
else
  _info "Deploy mode: PORT   → $(_effective_url)"
fi

$LMS_DRY_RUN && _warn "DRY RUN — commands will be printed, not executed."

if $LMS_STOP_ONLY;     then do_stop;          _deploy_log "=== Session end ==="; ssh "${SSH_BASE_OPTS[@]}" -O exit "$TARGET" 2>/dev/null || true; exit 0; fi
if $LMS_RESTART_ONLY;  then do_restart;       _deploy_log "=== Session end ==="; ssh "${SSH_BASE_OPTS[@]}" -O exit "$TARGET" 2>/dev/null || true; exit 0; fi
if $LMS_STATUS_ONLY;   then do_status;        _deploy_log "=== Session end ==="; ssh "${SSH_BASE_OPTS[@]}" -O exit "$TARGET" 2>/dev/null || true; exit 0; fi
if $LMS_UPDATE_CONFIG; then do_update_config; _deploy_log "=== Session end ==="; ssh "${SSH_BASE_OPTS[@]}" -O exit "$TARGET" 2>/dev/null || true; exit 0; fi

if $LMS_UPDATE_ONLY; then
  do_update
  if $LMS_UPDATE_ONLY; then
    _deploy_log "=== Session end ==="
    ssh "${SSH_BASE_OPTS[@]}" -O exit "$TARGET" 2>/dev/null || true
    exit 0
  fi
fi

if $LMS_CLEAN_CONTAINERS && ! $LMS_CLEAN; then do_clean_containers; fi
if $LMS_CLEAN_VOLUMES    && ! $LMS_CLEAN; then do_clean_volumes;    fi
if $LMS_CLEAN_VENV       && ! $LMS_CLEAN; then do_clean_venv;       fi
if $LMS_CLEAN_DIRS       && ! $LMS_CLEAN; then do_clean_dirs;       fi
if $LMS_CLEAN_SERVICES   && ! $LMS_CLEAN; then do_clean_services;   fi

if $LMS_CLEAN; then
  do_full_clean
  if $LMS_CLEAN_ONLY; then
    _deploy_log "=== Session end ==="
    ssh "${SSH_BASE_OPTS[@]}" -O exit "$TARGET" 2>/dev/null || true
    exit 0
  fi
fi

_step_enabled 0  && _step_run 0  "Ensure passwordless sudo"                         _run_step0
_step_enabled 1  && { _step_run 1  "System packages + nginx config + podman"        _run_step1 || true; }
_step_enabled 2  && _step_run 2  "Containers + OS user + Postgres"                  _run_step2
_step_enabled 3  && _step_run 3  "NVM + Node ${LMS_NODE_VERSION}"                   _run_step3
_step_enabled 4  && _step_run 4  "Frappe bench init"                                _run_step4
_step_enabled 5  && _step_run 5  "Verify containers"                                _run_step5
_step_enabled 6  && _step_run 6  "Create Frappe site"                               _run_step6
_step_enabled 7  && _step_run 7  "Install tap_lms"                                  _run_step7
_step_enabled 8  && _step_run 8  "Install business_theme_v14"                       _run_step8
_step_enabled 9  && _step_run 9  "Migrate + scheduler"                              _run_step9
_step_enabled 10 && _step_run 10 "Supervisor + Nginx"                               _run_step10
_step_enabled 11 && _step_run 11 "Log directories"                                  _run_step11
_step_enabled 12 && _step_run 12 "Gunicorn systemd service"                         _run_step12
_step_enabled 13 && _step_run 13 "Build assets + start workers"                     _run_step13
_step_enabled 14 && _step_run 14 "Start gunicorn + final checks"                    _run_step14
if _step_enabled 15; then
  _header "Step 15 — Firewall"
  _run_step15 || true
fi

ssh "${SSH_BASE_OPTS[@]}" -O exit "$TARGET" 2>/dev/null || true

if $_DEPLOY_FAILED; then
  _err "Deployment finished with errors — check: ${LMS_DEPLOY_LOG}"
  _deploy_log "=== Session end — FAILED ==="
  exit 1
fi

echo ""
_ok "LMS deployment complete [${_BENCH_ID}]"
_info "URL:      $(_effective_url)"
_info "Login:    Administrator / ${LMS_FRAPPE_ADMIN_PASSWORD}"
_info "Logs:     ${LMS_DEPLOY_LOG}"
_info "Consumer: ${_CONSUMER_SERVICE_NAME} — start after configuring RabbitMQ settings"
[[ "$LMS_ENABLE_HTTPS" == "true" ]] && _warn "HTTPS is using a self-signed cert — replace with a CA-signed cert for production."
_deploy_log "=== Session end — SUCCESS ==="
echo ""