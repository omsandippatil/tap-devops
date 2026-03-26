#!/usr/bin/env bash
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
die()     { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${RESET}"; }

PLG_CONFIG_FILE="./config.env"
PLG_SKIP_MODEL=false
PLG_DRY_RUN=false
PLG_STEPS=""
PLG_CLEAN=false
PLG_CLEAN_ONLY=false
PLG_RESTART_ONLY=false
PLG_STATUS_ONLY=false
PLG_UPDATE_ONLY=false
PLG_UPDATE_CONFIG_ONLY=false
PLG_CLEAN_SERVICES=false
PLG_CLEAN_CONTAINERS=false
PLG_CLEAN_VOLUMES=false
PLG_CLEAN_DIRS=false
PLG_CLEAN_VENV=false
PLG_FORCE=false
PLG_VERBOSE=false
PLG_NO_WAIT=false
PLG_PARALLEL_PULL=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Core options:
  --config FILE          Config file path (default: ./config.env)
  --steps LIST           Comma-separated steps or ranges, e.g. 1,3,5-8
  --dry-run              Print SSH commands without executing
  --skip-model           Skip CLIP model download
  --force                Skip confirmation prompts
  --verbose              Show full remote output (set -x on remote)
  --no-wait              Skip sleep/wait delays between steps

Deployment modes:
  --clean                Full cleanup before deploy (all resources for this app)
  --clean-only           Clean and exit (no deploy)
  --restart              Restart all services and exit
  --status               Show health check and exit
  --update               Safe atomic update: validate new code before swap,
                         keep old code as rollback, restart app services only
  --update-config        Re-write .env from config.env and restart app services
                         (no git pull, infra/data untouched)

Selective clean flags (combinable):
  --clean-services       Stop and remove only systemd service units
  --clean-containers     Stop and remove only podman containers
  --clean-volumes        Remove only podman volumes
  --clean-dirs           Remove only app and bench directories
  --clean-venv           Remove only the Python venv

Performance:
  --parallel-pull        Pull container images in parallel

  --help                 Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)           PLG_CONFIG_FILE="$2"; shift 2 ;;
    --skip-model)       PLG_SKIP_MODEL=true; shift ;;
    --dry-run)          PLG_DRY_RUN=true; shift ;;
    --steps)            PLG_STEPS="$2"; shift 2 ;;
    --clean)            PLG_CLEAN=true; shift ;;
    --clean-only)       PLG_CLEAN=true; PLG_CLEAN_ONLY=true; shift ;;
    --restart)          PLG_RESTART_ONLY=true; shift ;;
    --status)           PLG_STATUS_ONLY=true; shift ;;
    --update)           PLG_UPDATE_ONLY=true; shift ;;
    --update-config)    PLG_UPDATE_CONFIG_ONLY=true; shift ;;
    --clean-services)   PLG_CLEAN_SERVICES=true; shift ;;
    --clean-containers) PLG_CLEAN_CONTAINERS=true; shift ;;
    --clean-volumes)    PLG_CLEAN_VOLUMES=true; shift ;;
    --clean-dirs)       PLG_CLEAN_DIRS=true; shift ;;
    --clean-venv)       PLG_CLEAN_VENV=true; shift ;;
    --force)            PLG_FORCE=true; shift ;;
    --verbose)          PLG_VERBOSE=true; shift ;;
    --no-wait)          PLG_NO_WAIT=true; shift ;;
    --parallel-pull)    PLG_PARALLEL_PULL=true; shift ;;
    --help)             usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -f "$PLG_CONFIG_FILE" ]] || die "Config file not found: $PLG_CONFIG_FILE"
source "$PLG_CONFIG_FILE"
success "Loaded config from $PLG_CONFIG_FILE"

$PLG_DRY_RUN && warn "DRY RUN — SSH commands will be printed, not executed."

REQUIRED_VARS=(
  PLG_SERVER_USER PLG_SERVER_HOST PLG_SSH_KEY_PATH
  PLG_APP_DIR PLG_GIT_REPO PLG_GIT_BRANCH
  PLG_POSTGRES_USER PLG_POSTGRES_PASSWORD PLG_POSTGRES_DB PLG_POSTGRES_PORT
  PLG_FRAPPE_BENCH_DIR PLG_FRAPPE_SITE_NAME PLG_FRAPPE_ADMIN_PASSWORD
  PLG_FRAPPE_WEB_PORT PLG_FRAPPE_REDIS_CACHE_PORT PLG_FRAPPE_REDIS_QUEUE_PORT
  PLG_DEPLOY_SECRET_KEY
)
for v in "${REQUIRED_VARS[@]}"; do
  [[ -n "${!v:-}" ]] || die "Required config variable \$$v is not set in $PLG_CONFIG_FILE"
done

PLG_FRAPPE_GUNICORN_WORKERS="${PLG_FRAPPE_GUNICORN_WORKERS:-2}"
PLG_FRAPPE_GUNICORN_THREADS="${PLG_FRAPPE_GUNICORN_THREADS:-4}"
PLG_FRAPPE_GUNICORN_TIMEOUT="${PLG_FRAPPE_GUNICORN_TIMEOUT:-120}"
PLG_FRAPPE_ADMIN_USER="${PLG_FRAPPE_ADMIN_USER:-Administrator}"
PLG_SSH_PORT="${PLG_SSH_PORT:-22}"
PLG_OBSERVER_PORT="${PLG_OBSERVER_PORT:-8001}"
PLG_DEPLOYER_PORT="${PLG_DEPLOYER_PORT:-8002}"
PLG_LOG_RETENTION_DAYS="${PLG_LOG_RETENTION_DAYS:-7}"
PLG_LOG_MAX_DISK_MB="${PLG_LOG_MAX_DISK_MB:-200}"
PLG_LOG_DIR="${PLG_LOG_DIR:-${PLG_APP_DIR}/observer/logs}"
PLG_OBSERVER_DIR="${PLG_OBSERVER_DIR:-${PLG_APP_DIR}/observer}"
PLG_DEPLOYER_DIR="${PLG_DEPLOYER_DIR:-${PLG_APP_DIR}/deployer}"

SSH_OPTS="-i ${PLG_SSH_KEY_PATH} -p ${PLG_SSH_PORT} -o StrictHostKeyChecking=no -o ConnectTimeout=15"
TARGET="${PLG_SERVER_USER}@${PLG_SERVER_HOST}"

PLG_WAIT() {
  local secs="$1"
  $PLG_NO_WAIT || sleep "$secs"
}

step_enabled() {
  local n="$1"
  [[ -z "$PLG_STEPS" ]] && return 0
  local token lo hi
  local IFS=','
  read -ra _tokens <<< "$PLG_STEPS"
  for token in "${_tokens[@]}"; do
    if [[ "$token" == *-* ]]; then
      lo="${token%-*}"
      hi="${token#*-}"
      [[ "$n" -ge "$lo" && "$n" -le "$hi" ]] && return 0
    else
      [[ "$n" == "$token" ]] && return 0
    fi
  done
  return 1
}

PLG_PATH_PREAMBLE='
export NVM_DIR="${HOME}/.nvm"
[[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"
export PATH="${HOME}/.local/bin:${PATH}"
hash -r 2>/dev/null || true
'

run_remote() {
  local desc="$1"; shift
  info "Remote: $desc"
  if $PLG_DRY_RUN; then
    echo -e "  ${YELLOW}$ $*${RESET}"
    return 0
  fi
  if $PLG_VERBOSE; then
    ssh $SSH_OPTS "$TARGET" "$@"
  else
    ssh $SSH_OPTS "$TARGET" "$@" 2>&1
  fi
}

run_remote_heredoc() {
  local desc="$1"
  local body="$2"
  info "Remote script: $desc"
  if $PLG_DRY_RUN; then
    echo -e "  ${YELLOW}[heredoc block: $desc]${RESET}"
    return 0
  fi
  if $PLG_VERBOSE; then
    ssh $SSH_OPTS "$TARGET" "bash --login -s" <<EOF
${PLG_PATH_PREAMBLE}
set -euo pipefail
set -x
${body}
EOF
  else
    ssh $SSH_OPTS "$TARGET" "bash --login -s" <<EOF
${PLG_PATH_PREAMBLE}
set -euo pipefail
${body}
EOF
  fi
}

confirm() {
  local msg="$1"
  $PLG_FORCE && return 0
  echo -e "${YELLOW}${msg}${RESET}"
  read -rp "Continue? [y/N] " ans
  [[ "${ans,,}" == "y" ]] || { info "Aborted."; exit 0; }
}

header "Pre-flight checks"
[[ -f "$PLG_SSH_KEY_PATH" ]] || die "SSH key not found: $PLG_SSH_KEY_PATH"
chmod 600 "$PLG_SSH_KEY_PATH"
success "SSH key OK"

if ! $PLG_DRY_RUN; then
  ssh $SSH_OPTS "$TARGET" "echo 'SSH OK'" > /dev/null \
    || die "Cannot connect to ${TARGET}."
fi
success "SSH connection verified"


do_clean_services() {
  run_remote_heredoc "Stop and remove systemd services" "
for svc in plg_app plg_api plg-postgres plg-rabbitmq plg-redis-cache plg-redis-queue plg-frappe-web plg-frappe-worker plg-frappe-schedule plg-observer plg-deployer; do
  systemctl --user stop    \${svc}.service 2>/dev/null || true
  systemctl --user disable \${svc}.service 2>/dev/null || true
  rm -f \"\${HOME}/.config/systemd/user/\${svc}.service\"
done
systemctl --user daemon-reload 2>/dev/null || true
echo 'Services removed.'
"
}

do_clean_containers() {
  run_remote_heredoc "Stop and remove podman containers" "
for ctr in ${PLG_POSTGRES_CONTAINER_NAME} ${PLG_RABBITMQ_CONTAINER_NAME} plg-redis-cache plg-redis-queue; do
  podman stop \$ctr 2>/dev/null || true
  podman rm   \$ctr 2>/dev/null || true
done
echo 'Containers removed.'
"
}

do_clean_volumes() {
  run_remote_heredoc "Remove podman volumes" "
podman volume rm ${PLG_POSTGRES_VOLUME_NAME} 2>/dev/null || true
echo 'Volumes removed.'
"
}

do_clean_dirs() {
  run_remote_heredoc "Remove app and bench directories" "
rm -rf ${PLG_APP_DIR}
rm -rf ${PLG_FRAPPE_BENCH_DIR}
find \${HOME} -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
echo 'Directories removed.'
"
}

do_clean_venv() {
  run_remote_heredoc "Remove Python venv" "
rm -rf ${PLG_APP_DIR}/venv
echo 'venv removed.'
"
}

do_full_clean() {
  confirm "This will DESTROY all PLG services, containers, volumes, and directories on ${TARGET}."
  header "Full clean"
  do_clean_services
  do_clean_containers
  do_clean_volumes
  do_clean_dirs
  success "Full clean complete"
}

do_selective_clean() {
  local did=0
  if $PLG_CLEAN_SERVICES;   then header "Selective clean: services";    do_clean_services;   did=1; fi
  if $PLG_CLEAN_CONTAINERS; then header "Selective clean: containers";  do_clean_containers; did=1; fi
  if $PLG_CLEAN_VOLUMES;    then header "Selective clean: volumes";     do_clean_volumes;    did=1; fi
  if $PLG_CLEAN_DIRS;       then header "Selective clean: directories"; do_clean_dirs;       did=1; fi
  if $PLG_CLEAN_VENV;       then header "Selective clean: venv";        do_clean_venv;       did=1; fi
  [[ "$did" -eq 1 ]] && success "Selective clean complete"
}

do_restart() {
  header "Restart all services"
  local _settle=4
  $PLG_NO_WAIT && _settle=0
  run_remote_heredoc "Restart" "
for svc in plg-postgres plg-rabbitmq plg-redis-cache plg-redis-queue plg_app plg_api plg-frappe-web plg-frappe-worker plg-frappe-schedule plg-observer plg-deployer; do
  systemctl --user restart \${svc}.service 2>/dev/null || true
done
sleep ${_settle}
for svc in plg-postgres plg-rabbitmq plg-redis-cache plg-redis-queue plg_app plg_api plg-frappe-web plg-frappe-worker plg-frappe-schedule plg-observer plg-deployer; do
  state=\$(systemctl --user is-active \${svc}.service 2>/dev/null || echo unknown)
  printf '  %-42s %s\n' \"\${svc}.service\" \"\$state\"
done
"
  success "Services restarted"
}

do_status() {
  header "Health check"
  run_remote_heredoc "Status" "
echo '=== Containers ==='
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo ''
echo '=== Systemd services ==='
for svc in plg-postgres plg-rabbitmq plg-redis-cache plg-redis-queue plg_app plg_api plg-frappe-web plg-frappe-worker plg-frappe-schedule plg-observer plg-deployer; do
  state=\$(systemctl --user is-active \${svc}.service 2>/dev/null || echo unknown)
  printf '  %-42s %s\n' \"\${svc}.service\" \"\$state\"
done

echo ''
echo '=== Last 5 lines: plg_app ==='
journalctl --user -u plg_app.service -n 5 --no-pager 2>/dev/null || echo '(no logs yet)'

echo ''
echo '=== Last 5 lines: plg-frappe-web ==='
journalctl --user -u plg-frappe-web.service -n 5 --no-pager 2>/dev/null || echo '(no logs yet)'

echo ''
echo '=== Reachability ==='
curl -sf --max-time 5 http://localhost:${PLG_API_PORT}/docs > /dev/null \
  && echo '  PLG API   UP: http://${PLG_SERVER_HOST}:${PLG_API_PORT}/docs' \
  || echo '  PLG API   not yet on :${PLG_API_PORT}'
curl -sf --max-time 5 http://localhost:${PLG_FRAPPE_WEB_PORT} > /dev/null \
  && echo '  Frappe    UP: http://${PLG_SERVER_HOST}:${PLG_FRAPPE_WEB_PORT}' \
  || echo '  Frappe    not yet on :${PLG_FRAPPE_WEB_PORT}'
curl -sf --max-time 5 http://localhost:${PLG_OBSERVER_PORT}/health > /dev/null \
  && echo '  Observer  UP: http://${PLG_SERVER_HOST}:${PLG_OBSERVER_PORT}/docs' \
  || echo '  Observer  not yet on :${PLG_OBSERVER_PORT}'
curl -sf --max-time 5 http://localhost:${PLG_DEPLOYER_PORT}/health > /dev/null \
  && echo '  Deployer  UP: http://${PLG_SERVER_HOST}:${PLG_DEPLOYER_PORT}/docs' \
  || echo '  Deployer  not yet on :${PLG_DEPLOYER_PORT}'
"
}

do_update() {
  local _settle=4
  $PLG_NO_WAIT && _settle=0

  header "Update: safe atomic update — tap_plg"
  run_remote_heredoc "validate + swap tap_plg" "
APP_DIR=${PLG_APP_DIR}
BRANCH=${PLG_GIT_BRANCH}
REPO=${PLG_GIT_REPO}
STAGING=\"\${APP_DIR}__staging\"
BACKUP=\"\${APP_DIR}__backup_\$(date +%Y%m%d_%H%M%S)\"
VALIDATION_LOG=\"\${APP_DIR}/observer/logs/deployments.jsonl\"
mkdir -p \"\${APP_DIR}/observer/logs\"
TS=\$(date -u +%Y-%m-%dT%H:%M:%SZ)

log_deploy() {
  local status=\"\$1\" msg=\"\$2\"
  echo \"{\\\"ts\\\":\\\"\${TS}\\\",\\\"event\\\":\\\"deploy\\\",\\\"repo\\\":\\\"tap_plg\\\",\\\"branch\\\":\\\"\${BRANCH}\\\",\\\"status\\\":\\\"\${status}\\\",\\\"msg\\\":\\\"\${msg}\\\"}\" >> \"\${VALIDATION_LOG}\" 2>/dev/null || true
}

rm -rf \"\${STAGING}\"
git clone --depth 1 --branch \"\${BRANCH}\" \"\${REPO}\" \"\${STAGING}\"

if command -v ${PLG_FRAPPE_PYTHON} &>/dev/null; then
  PYTHON_BIN=${PLG_FRAPPE_PYTHON}
else
  PYTHON_BIN=\$(command -v python3)
fi

echo '--- Python syntax check ---'
SYNTAX_ERRORS=0
while IFS= read -r -d '' f; do
  \${PYTHON_BIN} -m py_compile \"\$f\" 2>/tmp/plg_syntax_err || { cat /tmp/plg_syntax_err; SYNTAX_ERRORS=\$((SYNTAX_ERRORS+1)); }
done < <(find \"\${STAGING}\" -name '*.py' -not -path '*/venv/*' -not -path '*/.git/*' -print0)
if [[ \$SYNTAX_ERRORS -gt 0 ]]; then
  log_deploy 'failed' \"syntax errors: \${SYNTAX_ERRORS} files\"
  rm -rf \"\${STAGING}\"
  echo \"ABORT: \${SYNTAX_ERRORS} Python syntax error(s) — old code still running\"
  exit 1
fi
echo \"Syntax OK (\$(find \${STAGING} -name '*.py' -not -path '*/venv/*' | wc -l) files)\"

echo '--- Requirements dry-run check ---'
VENV_CHECK=\"/tmp/plg_venv_check_\$\$\"
\${PYTHON_BIN} -m venv \"\${VENV_CHECK}\"
\"\${VENV_CHECK}/bin/pip\" install --upgrade pip --quiet
if ! \"\${VENV_CHECK}/bin/pip\" install -r \"\${STAGING}/requirements.txt\" --dry-run --quiet 2>/tmp/plg_req_err; then
  cat /tmp/plg_req_err
  log_deploy 'failed' 'requirements dry-run failed'
  rm -rf \"\${STAGING}\" \"\${VENV_CHECK}\"
  echo 'ABORT: requirements check failed — old code still running'
  exit 1
fi
rm -rf \"\${VENV_CHECK}\"
echo 'Requirements OK'

echo '--- Import check (top-level modules) ---'
IMPORT_ERRORS=0
for mod in app api; do
  if [[ -f \"\${STAGING}/\${mod}.py\" ]]; then
    cd \"\${STAGING}\"
    \${PYTHON_BIN} -c \"import ast; ast.parse(open('\${mod}.py').read())\" 2>/tmp/plg_import_err || {
      cat /tmp/plg_import_err
      IMPORT_ERRORS=\$((IMPORT_ERRORS+1))
    }
    cd - > /dev/null
  fi
done
if [[ \$IMPORT_ERRORS -gt 0 ]]; then
  log_deploy 'failed' \"import/parse errors: \${IMPORT_ERRORS}\"
  rm -rf \"\${STAGING}\"
  echo \"ABORT: \${IMPORT_ERRORS} AST parse error(s) — old code still running\"
  exit 1
fi
echo 'AST import check OK'

echo '--- Atomic swap ---'
if [[ -d \"\${APP_DIR}\" ]]; then
  cp -a \"\${APP_DIR}\" \"\${BACKUP}\"
  cp -a \"\${APP_DIR}/.env\" \"\${STAGING}/.env\" 2>/dev/null || true
  cp -a \"\${APP_DIR}/data\" \"\${STAGING}/data\" 2>/dev/null || true
  cp -rp \"\${APP_DIR}/observer\" \"\${STAGING}/observer\" 2>/dev/null || true
  cp -rp \"\${APP_DIR}/deployer\" \"\${STAGING}/deployer\" 2>/dev/null || true
fi

mv -T \"\${STAGING}\" \"\${APP_DIR}\"

echo '--- Reinstall requirements ---'
cd \"\${APP_DIR}\"
if command -v ${PLG_FRAPPE_PYTHON} &>/dev/null; then
  PYTHON_BIN=${PLG_FRAPPE_PYTHON}
else
  PYTHON_BIN=\$(command -v python3)
fi
\${PYTHON_BIN} -m venv venv
source venv/bin/activate
pip install --upgrade pip --quiet
pip install -r requirements.txt --quiet
echo \"HEAD: \$(git log --oneline -1)\"

log_deploy 'success' \"HEAD: \$(git log --oneline -1)\"

find \"\${APP_DIR%/*}\" -maxdepth 1 -name \"\$(basename \${APP_DIR})__backup_*\" -type d | sort | head -n -3 | xargs rm -rf 2>/dev/null || true
echo \"Backup kept at: \${BACKUP}\"
echo 'tap_plg swap complete.'
"

  header "Update: plagiarism_app"
  run_remote_heredoc "git pull plagiarism_app" "
BENCH=\"\${HOME}/.local/bin/bench\"
PLG_APP_PATH=${PLG_FRAPPE_BENCH_DIR}/apps/plagiarism_app
VALIDATION_LOG=\"${PLG_APP_DIR}/observer/logs/deployments.jsonl\"
TS=\$(date -u +%Y-%m-%dT%H:%M:%SZ)

log_deploy() {
  local status=\"\$1\" msg=\"\$2\"
  echo \"{\\\"ts\\\":\\\"\${TS}\\\",\\\"event\\\":\\\"deploy\\\",\\\"repo\\\":\\\"plagiarism_app\\\",\\\"branch\\\":\\\"${PLG_PLAGIARISM_APP_BRANCH}\\\",\\\"status\\\":\\\"\${status}\\\",\\\"msg\\\":\\\"\${msg}\\\"}\" >> \"\${VALIDATION_LOG}\" 2>/dev/null || true
}

if [[ -d \"\${PLG_APP_PATH}/.git\" ]]; then
  STAGING=\"\${PLG_APP_PATH}__staging\"
  BACKUP=\"\${PLG_APP_PATH}__backup_\$(date +%Y%m%d_%H%M%S)\"
  rm -rf \"\${STAGING}\"
  git clone --depth 1 --branch ${PLG_PLAGIARISM_APP_BRANCH} \$(git -C \"\${PLG_APP_PATH}\" remote get-url origin) \"\${STAGING}\"

  echo '--- Syntax check plagiarism_app ---'
  SYNTAX_ERRORS=0
  while IFS= read -r -d '' f; do
    python3 -m py_compile \"\$f\" 2>/tmp/plg_syn || { cat /tmp/plg_syn; SYNTAX_ERRORS=\$((SYNTAX_ERRORS+1)); }
  done < <(find \"\${STAGING}\" -name '*.py' -not -path '*/.git/*' -print0)
  if [[ \$SYNTAX_ERRORS -gt 0 ]]; then
    log_deploy 'failed' \"syntax errors: \${SYNTAX_ERRORS}\"
    rm -rf \"\${STAGING}\"
    echo \"ABORT: plagiarism_app has \${SYNTAX_ERRORS} syntax error(s) — old code kept\"
    exit 1
  fi
  echo 'Syntax OK'

  cp -a \"\${PLG_APP_PATH}\" \"\${BACKUP}\"
  mv -T \"\${STAGING}\" \"\${PLG_APP_PATH}\"
  echo \"plagiarism_app HEAD: \$(git -C \${PLG_APP_PATH} log --oneline -1)\"
  log_deploy 'success' \"HEAD: \$(git -C \${PLG_APP_PATH} log --oneline -1)\"
  find \"\$(dirname \${PLG_APP_PATH})\" -maxdepth 1 -name \"\$(basename \${PLG_APP_PATH})__backup_*\" -type d | sort | head -n -3 | xargs rm -rf 2>/dev/null || true
else
  echo 'plagiarism_app not found, skipping'
fi

cd ${PLG_FRAPPE_BENCH_DIR}
\${BENCH} --site ${PLG_FRAPPE_SITE_NAME} migrate
echo 'Migrate complete.'
"

  header "Update: restart app services"
  run_remote_heredoc "Restart app services only" "
for svc in plg_app plg_api plg-frappe-web plg-frappe-worker plg-frappe-schedule; do
  systemctl --user restart \${svc}.service 2>/dev/null || true
done
sleep ${_settle}
for svc in plg_app plg_api plg-frappe-web plg-frappe-worker plg-frappe-schedule; do
  state=\$(systemctl --user is-active \${svc}.service 2>/dev/null || echo unknown)
  printf '  %-42s %s\n' \"\${svc}.service\" \"\$state\"
done
"
  success "Update complete — validated, swapped, infra untouched"
}

do_update_config() {
  header "Update config: re-write .env from config.env"

  if [[ "${PLG_CLIP_MODEL_SOURCE}" == "local" ]]; then
    PLG_CLIP_PATH_LINE="CLIP_LOCAL_MODEL_PATH=${PLG_CLIP_LOCAL_MODEL_PATH}"
  else
    PLG_CLIP_PATH_LINE="CLIP_LOCAL_MODEL_PATH="
  fi

  ENV_CONTENT="RABBITMQ_HOST=${PLG_RABBITMQ_HOST}
RABBITMQ_PORT=${PLG_RABBITMQ_PORT}
RABBITMQ_USER=${PLG_RABBITMQ_USER}
RABBITMQ_PASS=${PLG_RABBITMQ_PASS}
RABBITMQ_MANAGEMENT_PORT=${PLG_RABBITMQ_MANAGEMENT_PORT}
RABBITMQ_PREFETCH_COUNT=${PLG_RABBITMQ_PREFETCH_COUNT}
MAX_RETRIES=${PLG_MAX_RETRIES}
SUBMISSION_QUEUE=${PLG_SUBMISSION_QUEUE}
FEEDBACK_QUEUE=${PLG_FEEDBACK_QUEUE}
DEAD_LETTER_QUEUE=${PLG_DEAD_LETTER_QUEUE}
POSTGRES_HOST=${PLG_POSTGRES_HOST}
POSTGRES_PORT=${PLG_POSTGRES_PORT}
POSTGRES_DB=${PLG_POSTGRES_DB}
POSTGRES_USER=${PLG_POSTGRES_USER}
POSTGRES_PASSWORD=${PLG_POSTGRES_PASSWORD}
POSTGRES_POOL_SIZE=${PLG_POSTGRES_POOL_SIZE}
POSTGRES_MAX_OVERFLOW=${PLG_POSTGRES_MAX_OVERFLOW}
EXACT_DUPLICATE_THRESHOLD=${PLG_EXACT_DUPLICATE_THRESHOLD}
NEAR_DUPLICATE_THRESHOLD=${PLG_NEAR_DUPLICATE_THRESHOLD}
SEMANTIC_MATCH_THRESHOLD=${PLG_SEMANTIC_MATCH_THRESHOLD}
HASH_MATCH_THRESHOLD=${PLG_HASH_MATCH_THRESHOLD}
MAX_IMAGE_SIZE_MB=${PLG_MAX_IMAGE_SIZE_MB}
IMAGE_DOWNLOAD_TIMEOUT=${PLG_IMAGE_DOWNLOAD_TIMEOUT}
IMAGE_MIN_VARIANCE=${PLG_IMAGE_MIN_VARIANCE}
IMAGE_MIN_UNIQUE_COLORS=${PLG_IMAGE_MIN_UNIQUE_COLORS}
IMAGE_MAX_SOLID_COLOR_RATIO=${PLG_IMAGE_MAX_SOLID_COLOR_RATIO}
CLIP_MODEL=${PLG_CLIP_MODEL}
CLIP_DEVICE=${PLG_CLIP_DEVICE}
CLIP_PRETRAINED=${PLG_CLIP_PRETRAINED}
${PLG_CLIP_PATH_LINE}
DISABLE_SSL_VERIFY=${PLG_DISABLE_SSL_VERIFY}
PYTHONHTTPSVERIFY=0
USE_PGVECTOR=${PLG_USE_PGVECTOR}
FAISS_INDEX_PATH=${PLG_APP_DIR}/data/faiss_index.bin
FAISS_METADATA_PATH=${PLG_APP_DIR}/data/faiss_metadata.json
FAISS_DIMENSION=${PLG_FAISS_DIMENSION}
FAISS_TOP_K=${PLG_FAISS_TOP_K}
REFERENCE_IMAGES_DIR=${PLG_APP_DIR}/data/reference_images
TEMP_IMAGES_DIR=${PLG_APP_DIR}/data/temp_images
LOG_LEVEL=${PLG_LOG_LEVEL}
MOCK_GLIFIC=${PLG_MOCK_GLIFIC}
RESUBMISSION_WINDOW_MINUTES=${PLG_RESUBMISSION_WINDOW_MINUTES}"

  local _settle=4
  $PLG_NO_WAIT && _settle=0

  WRITE_ENV_BODY="
cat > ${PLG_APP_DIR}/.env << 'INNEREOF'
${ENV_CONTENT}
INNEREOF
sed -i 's/\r//' ${PLG_APP_DIR}/.env
echo \".env: \$(wc -l < ${PLG_APP_DIR}/.env) lines written\"
"
  run_remote_heredoc "Re-write .env" "$WRITE_ENV_BODY"

  run_remote_heredoc "Restart app services after config update" "
for svc in plg_app plg_api plg-frappe-web plg-frappe-worker plg-frappe-schedule; do
  systemctl --user restart \${svc}.service 2>/dev/null || true
done
sleep ${_settle}
for svc in plg_app plg_api plg-frappe-web plg-frappe-worker plg-frappe-schedule; do
  state=\$(systemctl --user is-active \${svc}.service 2>/dev/null || echo unknown)
  printf '  %-42s %s\n' \"\${svc}.service\" \"\$state\"
done
"
  success "Config updated and app services restarted"
}

do_write_observer() {
  header "Observer: write service files"
  run_remote_heredoc "Write observer app + service" "
mkdir -p ${PLG_OBSERVER_DIR}
mkdir -p ${PLG_LOG_DIR}

cat > ${PLG_OBSERVER_DIR}/requirements.txt << 'REQEOF'
fastapi>=0.111.0
uvicorn[standard]>=0.29.0
REQEOF

if command -v ${PLG_FRAPPE_PYTHON} &>/dev/null; then
  PYTHON_BIN=${PLG_FRAPPE_PYTHON}
else
  PYTHON_BIN=\$(command -v python3)
fi
\${PYTHON_BIN} -m venv ${PLG_OBSERVER_DIR}/venv
${PLG_OBSERVER_DIR}/venv/bin/pip install --upgrade pip --quiet
${PLG_OBSERVER_DIR}/venv/bin/pip install -r ${PLG_OBSERVER_DIR}/requirements.txt --quiet

cat > ${PLG_OBSERVER_DIR}/observer.py << 'PYEOF'
import os, json, time, subprocess, threading, glob, shutil
from pathlib import Path
from datetime import datetime, timezone, timedelta
from typing import Optional
from fastapi import FastAPI, HTTPException, Depends, Query
from fastapi.security import APIKeyHeader
from fastapi.responses import JSONResponse

SECRET_KEY   = os.environ["PLG_DEPLOY_SECRET_KEY"]
LOG_DIR      = Path(os.environ.get("PLG_LOG_DIR", "${PLG_LOG_DIR}"))
RETAIN_DAYS  = int(os.environ.get("PLG_LOG_RETENTION_DAYS", "${PLG_LOG_RETENTION_DAYS}"))
MAX_MB       = int(os.environ.get("PLG_LOG_MAX_DISK_MB",    "${PLG_LOG_MAX_DISK_MB}"))
SERVICES     = [
    "plg_app", "plg_api", "plg-frappe-web",
    "plg-frappe-worker", "plg-frappe-schedule",
    "plg-postgres", "plg-rabbitmq",
    "plg-redis-cache", "plg-redis-queue",
    "plg-observer", "plg-deployer",
]
LOG_DIR.mkdir(parents=True, exist_ok=True)

api_key_header = APIKeyHeader(name="X-Deploy-Key", auto_error=False)

app = FastAPI(title="PLG Observer", version="1.0.0")

_log_lock = threading.Lock()


def _auth(key: str = Depends(api_key_header)):
    if key != SECRET_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return key


def _today_file(service: str) -> Path:
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    return LOG_DIR / f"{service}_{day}.jsonl"


def _purge():
    cutoff = datetime.now(timezone.utc) - timedelta(days=RETAIN_DAYS)
    for f in LOG_DIR.glob("*.jsonl"):
        try:
            day_str = f.stem.rsplit("_", 1)[-1]
            if datetime.strptime(day_str, "%Y-%m-%d").replace(tzinfo=timezone.utc) < cutoff:
                f.unlink()
        except Exception:
            pass
    total_mb = sum(f.stat().st_size for f in LOG_DIR.glob("*.jsonl")) / 1024 / 1024
    if total_mb > MAX_MB:
        files = sorted(LOG_DIR.glob("*.jsonl"), key=lambda f: f.stat().st_mtime)
        for f in files:
            if total_mb <= MAX_MB * 0.8:
                break
            removed_mb = f.stat().st_size / 1024 / 1024
            f.unlink()
            total_mb -= removed_mb


def _tail_service(service: str):
    cmd = ["journalctl", "--user", "-u", f"{service}.service",
           "-f", "--no-pager", "-o", "json"]
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        for raw in proc.stdout:
            try:
                entry = json.loads(raw.decode("utf-8", errors="replace"))
                record = {
                    "ts": datetime.fromtimestamp(
                        int(entry.get("__REALTIME_TIMESTAMP", 0)) / 1e6,
                        tz=timezone.utc
                    ).isoformat(),
                    "service": service,
                    "priority": entry.get("PRIORITY", "6"),
                    "msg": entry.get("MESSAGE", ""),
                    "pid": entry.get("_PID", ""),
                }
                with _log_lock:
                    with open(_today_file(service), "a") as fh:
                        fh.write(json.dumps(record) + "\n")
                _purge()
            except Exception:
                pass
    except Exception:
        pass


def _start_tailers():
    for svc in SERVICES:
        t = threading.Thread(target=_tail_service, args=(svc,), daemon=True)
        t.start()


@app.on_event("startup")
def _startup():
    _start_tailers()


@app.get("/health")
def health():
    return {"status": "ok", "ts": datetime.now(timezone.utc).isoformat()}


@app.get("/logs")
def get_logs(
    service: Optional[str] = Query(None),
    date: Optional[str] = Query(None, description="YYYY-MM-DD, default today"),
    limit: int = Query(200, le=2000),
    _: str = Depends(_auth),
):
    day = date or datetime.now(timezone.utc).strftime("%Y-%m-%d")
    pattern = f"{service}_{day}.jsonl" if service else f"*_{day}.jsonl"
    records = []
    for f in sorted(LOG_DIR.glob(pattern)):
        with open(f) as fh:
            for line in fh:
                try:
                    records.append(json.loads(line))
                except Exception:
                    pass
    records.sort(key=lambda r: r.get("ts", ""))
    return {"date": day, "service": service, "count": len(records), "logs": records[-limit:]}


@app.get("/logs/services")
def list_services(_: str = Depends(_auth)):
    return {"services": SERVICES}


@app.get("/logs/dates")
def list_dates(_: str = Depends(_auth)):
    days = sorted({f.stem.rsplit("_", 1)[-1] for f in LOG_DIR.glob("*.jsonl")}, reverse=True)
    return {"dates": days}


@app.get("/usage")
def get_usage(_: str = Depends(_auth)):
    total_bytes = sum(f.stat().st_size for f in LOG_DIR.glob("*.jsonl"))
    files = []
    for f in sorted(LOG_DIR.glob("*.jsonl"), key=lambda x: x.stat().st_mtime, reverse=True):
        files.append({"file": f.name, "size_kb": round(f.stat().st_size / 1024, 1)})
    disk = shutil.disk_usage(str(LOG_DIR))
    return {
        "log_dir": str(LOG_DIR),
        "retention_days": RETAIN_DAYS,
        "max_disk_mb": MAX_MB,
        "used_mb": round(total_bytes / 1024 / 1024, 2),
        "file_count": len(files),
        "files": files,
        "system_disk_free_gb": round(disk.free / 1024 / 1024 / 1024, 2),
    }


@app.get("/deployments")
def get_deployments(limit: int = Query(50, le=500), _: str = Depends(_auth)):
    deploy_log = LOG_DIR / "deployments.jsonl"
    records = []
    if deploy_log.exists():
        with open(deploy_log) as fh:
            for line in fh:
                try:
                    records.append(json.loads(line))
                except Exception:
                    pass
    return {"count": len(records), "deployments": records[-limit:]}
PYEOF

cat > \"\${HOME}/.config/systemd/user/plg-observer.service\" << 'SVCEOF'
[Unit]
Description=PLG Observer (log collector + API)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${PLG_OBSERVER_DIR}
Environment=PLG_DEPLOY_SECRET_KEY=${PLG_DEPLOY_SECRET_KEY}
Environment=PLG_LOG_DIR=${PLG_LOG_DIR}
Environment=PLG_LOG_RETENTION_DAYS=${PLG_LOG_RETENTION_DAYS}
Environment=PLG_LOG_MAX_DISK_MB=${PLG_LOG_MAX_DISK_MB}
ExecStart=${PLG_OBSERVER_DIR}/venv/bin/uvicorn observer:app --host 0.0.0.0 --port ${PLG_OBSERVER_PORT}
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
SVCEOF

systemctl --user daemon-reload
systemctl --user enable --now plg-observer.service
sleep 3
state=\$(systemctl --user is-active plg-observer.service 2>/dev/null || echo unknown)
echo \"plg-observer: \${state}\"
"
  success "Observer service deployed on :${PLG_OBSERVER_PORT}"
}

do_write_deployer() {
  header "Deployer: write webhook trigger service"
  run_remote_heredoc "Write deployer app + service" "
mkdir -p ${PLG_DEPLOYER_DIR}

cat > ${PLG_DEPLOYER_DIR}/requirements.txt << 'REQEOF'
fastapi>=0.111.0
uvicorn[standard]>=0.29.0
REQEOF

if command -v ${PLG_FRAPPE_PYTHON} &>/dev/null; then
  PYTHON_BIN=${PLG_FRAPPE_PYTHON}
else
  PYTHON_BIN=\$(command -v python3)
fi
\${PYTHON_BIN} -m venv ${PLG_DEPLOYER_DIR}/venv
${PLG_DEPLOYER_DIR}/venv/bin/pip install --upgrade pip --quiet
${PLG_DEPLOYER_DIR}/venv/bin/pip install -r ${PLG_DEPLOYER_DIR}/requirements.txt --quiet

DEPLOY_SCRIPT_PATH=\"\$(readlink -f \$(which \$0 2>/dev/null || echo /opt/plg/deploy.sh))\"
DEPLOY_SCRIPT_PATH=\"\${DEPLOY_SCRIPT_PATH:-/opt/plg/deploy.sh}\"

cat > ${PLG_DEPLOYER_DIR}/deployer.py << 'PYEOF'
import os, json, subprocess, threading, time, uuid
from pathlib import Path
from datetime import datetime, timezone
from fastapi import FastAPI, HTTPException, Depends, BackgroundTasks
from fastapi.security import APIKeyHeader
from fastapi.responses import JSONResponse

SECRET_KEY    = os.environ["PLG_DEPLOY_SECRET_KEY"]
CONFIG_FILE   = os.environ.get("PLG_CONFIG_FILE", "${PLG_CONFIG_FILE}")
DEPLOY_SCRIPT = os.environ.get("PLG_DEPLOY_SCRIPT", "${PLG_APP_DIR}/../deploy.sh")
LOG_DIR       = Path(os.environ.get("PLG_LOG_DIR", "${PLG_LOG_DIR}"))
STATUS_FILE   = LOG_DIR / "deployer_status.json"
LOG_DIR.mkdir(parents=True, exist_ok=True)

api_key_header = APIKeyHeader(name="X-Deploy-Key", auto_error=False)
app = FastAPI(title="PLG Deployer", version="1.0.0")

_lock = threading.Lock()
_current: dict = {}


def _auth(key: str = Depends(api_key_header)):
    if key != SECRET_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")
    return key


def _write_status(data: dict):
    with open(STATUS_FILE, "w") as fh:
        json.dump(data, fh)


def _read_status() -> dict:
    if STATUS_FILE.exists():
        try:
            with open(STATUS_FILE) as fh:
                return json.load(fh)
        except Exception:
            pass
    return {"status": "idle"}


def _run_deploy(deploy_id: str, config: str):
    global _current
    started = datetime.now(timezone.utc).isoformat()
    status = {
        "id": deploy_id,
        "status": "running",
        "started": started,
        "finished": None,
        "exit_code": None,
        "output": "",
    }
    _write_status(status)
    try:
        proc = subprocess.Popen(
            ["bash", DEPLOY_SCRIPT, "--config", config, "--update", "--force", "--no-wait"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        lines = []
        for line in proc.stdout:
            lines.append(line.rstrip())
            if len(lines) > 500:
                lines = lines[-500:]
            status["output"] = "\n".join(lines)
            _write_status(status)
        proc.wait()
        status["exit_code"] = proc.returncode
        status["status"] = "success" if proc.returncode == 0 else "failed"
    except Exception as e:
        status["status"] = "failed"
        status["output"] += f"\nException: {e}"
    status["finished"] = datetime.now(timezone.utc).isoformat()
    with _lock:
        _current = status
    _write_status(status)

    deploy_log = LOG_DIR / "deployments.jsonl"
    with open(deploy_log, "a") as fh:
        fh.write(json.dumps({
            "ts": status["finished"],
            "event": "deploy",
            "trigger": "webhook",
            "id": deploy_id,
            "status": status["status"],
            "exit_code": status["exit_code"],
        }) + "\n")


@app.get("/health")
def health():
    return {"status": "ok", "ts": datetime.now(timezone.utc).isoformat()}


@app.post("/deploy/trigger")
def trigger(background_tasks: BackgroundTasks, _: str = Depends(_auth)):
    with _lock:
        if _current.get("status") == "running":
            raise HTTPException(status_code=409, detail="Deploy already in progress")
    deploy_id = str(uuid.uuid4())[:8]
    background_tasks.add_task(_run_deploy, deploy_id, CONFIG_FILE)
    return {"deploy_id": deploy_id, "status": "accepted", "ts": datetime.now(timezone.utc).isoformat()}


@app.get("/deploy/status")
def get_status(_: str = Depends(_auth)):
    with _lock:
        if _current:
            return _current
    return _read_status()
PYEOF

cat > \"\${HOME}/.config/systemd/user/plg-deployer.service\" << 'SVCEOF'
[Unit]
Description=PLG Deployer (webhook trigger)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${PLG_DEPLOYER_DIR}
Environment=PLG_DEPLOY_SECRET_KEY=${PLG_DEPLOY_SECRET_KEY}
Environment=PLG_CONFIG_FILE=${PLG_CONFIG_FILE}
Environment=PLG_LOG_DIR=${PLG_LOG_DIR}
Environment=PLG_DEPLOY_SCRIPT=${PLG_APP_DIR}/../deploy.sh
ExecStart=${PLG_DEPLOYER_DIR}/venv/bin/uvicorn deployer:app --host 0.0.0.0 --port ${PLG_DEPLOYER_PORT}
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
SVCEOF

systemctl --user daemon-reload
systemctl --user enable --now plg-deployer.service
sleep 3
state=\$(systemctl --user is-active plg-deployer.service 2>/dev/null || echo unknown)
echo \"plg-deployer: \${state}\"
"
  success "Deployer webhook service on :${PLG_DEPLOYER_PORT} — POST /deploy/trigger with X-Deploy-Key header"
}

if $PLG_RESTART_ONLY; then
  do_restart
  exit 0
fi

if $PLG_STATUS_ONLY; then
  do_status
  exit 0
fi

if $PLG_UPDATE_ONLY; then
  do_update
  exit 0
fi

if $PLG_UPDATE_CONFIG_ONLY; then
  do_update_config
  exit 0
fi

if $PLG_CLEAN; then
  do_full_clean
  $PLG_CLEAN_ONLY && exit 0
fi

if $PLG_CLEAN_SERVICES || $PLG_CLEAN_CONTAINERS || $PLG_CLEAN_VOLUMES || $PLG_CLEAN_DIRS || $PLG_CLEAN_VENV; then
  do_selective_clean
fi


if step_enabled 1; then
  header "Step 1 — System packages"
  run_remote "apt install" "bash --login -s" <<'ENDSSH'
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq

PYVER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo "Detected system Python: ${PYVER}"

PYVER_PKGS=""
for pkg in "python${PYVER}-venv" "python${PYVER}-dev"; do
  if apt-cache show "$pkg" &>/dev/null; then
    PYVER_PKGS="${PYVER_PKGS} ${pkg}"
  fi
done

sudo apt-get install -y -qq \
  git curl wget vim ufw \
  python3 python3-pip python3-venv python3-dev python3-full \
  libffi-dev libssl-dev build-essential \
  postgresql-client \
  xvfb libfontconfig wkhtmltopdf \
  podman podman-compose \
  pipx \
  ${PYVER_PKGS} \
  2>&1 | tail -5
echo "System packages done."
ENDSSH
  success "System packages installed"
fi


if step_enabled 2; then
  header "Step 2 — nvm + Node ${PLG_FRAPPE_NODE_VERSION} + yarn"
  NVM_BODY="
if [[ ! -d \"\${HOME}/.nvm\" ]]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
export NVM_DIR=\"\${HOME}/.nvm\"
source \"\${NVM_DIR}/nvm.sh\"
nvm install ${PLG_FRAPPE_NODE_VERSION}
nvm alias default ${PLG_FRAPPE_NODE_VERSION}
nvm use default
echo \"Node: \$(node --version)\"
npm install -g yarn
echo \"Yarn: \$(yarn --version)\"
grep -q 'nvm.sh' \"\${HOME}/.bashrc\" || cat >> \"\${HOME}/.bashrc\" << 'BASHRC'
export NVM_DIR=\"\$HOME/.nvm\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"
export PATH=\"\$HOME/.local/bin:\$PATH\"
BASHRC
"
  run_remote_heredoc "nvm + Node" "$NVM_BODY"
  success "Node.js ${PLG_FRAPPE_NODE_VERSION} and yarn ready"
fi


if step_enabled 3; then
  header "Step 3 — bench CLI"
  BENCH_BODY="
pip3 install frappe-bench --user --quiet --break-system-packages
BENCH_BIN=\"\${HOME}/.local/bin/bench\"
[[ -f \"\${BENCH_BIN}\" ]] || { echo 'ERROR: bench binary not at ~/.local/bin/bench'; exit 1; }
echo \"bench: \$(\${BENCH_BIN} --version)\"
"
  run_remote_heredoc "pip install frappe-bench" "$BENCH_BODY"
  success "bench CLI installed"
fi


if step_enabled 4; then
  header "Step 4 — cgroup delegation"
  run_remote "delegate.conf" "bash -s" <<'ENDSSH'
sudo mkdir -p /etc/systemd/system/user@.service.d/
sudo tee /etc/systemd/system/user@.service.d/delegate.conf > /dev/null <<'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reload
ENDSSH
  success "cgroup delegation configured"
fi


if step_enabled 5; then
  header "Step 5 — Podman registry"
  run_remote "docker.io registry" "bash -s" <<'ENDSSH'
sudo mkdir -p /etc/containers/registries.conf.d/
sudo tee /etc/containers/registries.conf.d/docker.conf > /dev/null <<'EOF'
[[registry]]
prefix = "docker.io"
location = "docker.io"
EOF
ENDSSH
  success "Podman registry configured"
fi


if step_enabled 6; then
  header "Step 6 — Clone tap_plg"
  CLONE_BODY="
if [[ -d ${PLG_APP_DIR}/.git ]]; then
  cd ${PLG_APP_DIR}
  git fetch --all
  git checkout ${PLG_GIT_BRANCH}
  git pull origin ${PLG_GIT_BRANCH}
else
  git clone ${PLG_GIT_REPO} ${PLG_APP_DIR}
  cd ${PLG_APP_DIR}
  git checkout ${PLG_GIT_BRANCH}
fi
echo \"Cloned: \$(git log --oneline -1)\"
"
  run_remote_heredoc "Clone tap_plg" "$CLONE_BODY"
  success "tap_plg cloned → ${PLG_GIT_BRANCH}"
fi


if step_enabled 7; then
  header "Step 7 — tap_plg Python venv"
  VENV_BODY="
cd ${PLG_APP_DIR}
if command -v ${PLG_FRAPPE_PYTHON} &>/dev/null; then
  PYTHON_BIN=${PLG_FRAPPE_PYTHON}
else
  PYTHON_BIN=\$(command -v python3)
  echo \"${PLG_FRAPPE_PYTHON} not found — falling back to \${PYTHON_BIN}\"
fi
\${PYTHON_BIN} -m venv venv
source venv/bin/activate
pip install --upgrade pip --quiet
pip install -r requirements.txt --quiet
echo \"Python: \$(python --version)\"
echo \"Packages: \$(pip list | wc -l)\"
"
  run_remote_heredoc "venv + deps" "$VENV_BODY"
  success "tap_plg Python environment ready"
fi


if step_enabled 8; then
  header "Step 8 — Write tap_plg .env"

  if [[ "${PLG_CLIP_MODEL_SOURCE}" == "local" ]]; then
    PLG_CLIP_PATH_LINE="CLIP_LOCAL_MODEL_PATH=${PLG_CLIP_LOCAL_MODEL_PATH}"
  else
    PLG_CLIP_PATH_LINE="CLIP_LOCAL_MODEL_PATH="
  fi

  ENV_CONTENT="RABBITMQ_HOST=${PLG_RABBITMQ_HOST}
RABBITMQ_PORT=${PLG_RABBITMQ_PORT}
RABBITMQ_USER=${PLG_RABBITMQ_USER}
RABBITMQ_PASS=${PLG_RABBITMQ_PASS}
RABBITMQ_MANAGEMENT_PORT=${PLG_RABBITMQ_MANAGEMENT_PORT}
RABBITMQ_PREFETCH_COUNT=${PLG_RABBITMQ_PREFETCH_COUNT}
MAX_RETRIES=${PLG_MAX_RETRIES}
SUBMISSION_QUEUE=${PLG_SUBMISSION_QUEUE}
FEEDBACK_QUEUE=${PLG_FEEDBACK_QUEUE}
DEAD_LETTER_QUEUE=${PLG_DEAD_LETTER_QUEUE}
POSTGRES_HOST=${PLG_POSTGRES_HOST}
POSTGRES_PORT=${PLG_POSTGRES_PORT}
POSTGRES_DB=${PLG_POSTGRES_DB}
POSTGRES_USER=${PLG_POSTGRES_USER}
POSTGRES_PASSWORD=${PLG_POSTGRES_PASSWORD}
POSTGRES_POOL_SIZE=${PLG_POSTGRES_POOL_SIZE}
POSTGRES_MAX_OVERFLOW=${PLG_POSTGRES_MAX_OVERFLOW}
EXACT_DUPLICATE_THRESHOLD=${PLG_EXACT_DUPLICATE_THRESHOLD}
NEAR_DUPLICATE_THRESHOLD=${PLG_NEAR_DUPLICATE_THRESHOLD}
SEMANTIC_MATCH_THRESHOLD=${PLG_SEMANTIC_MATCH_THRESHOLD}
HASH_MATCH_THRESHOLD=${PLG_HASH_MATCH_THRESHOLD}
MAX_IMAGE_SIZE_MB=${PLG_MAX_IMAGE_SIZE_MB}
IMAGE_DOWNLOAD_TIMEOUT=${PLG_IMAGE_DOWNLOAD_TIMEOUT}
IMAGE_MIN_VARIANCE=${PLG_IMAGE_MIN_VARIANCE}
IMAGE_MIN_UNIQUE_COLORS=${PLG_IMAGE_MIN_UNIQUE_COLORS}
IMAGE_MAX_SOLID_COLOR_RATIO=${PLG_IMAGE_MAX_SOLID_COLOR_RATIO}
CLIP_MODEL=${PLG_CLIP_MODEL}
CLIP_DEVICE=${PLG_CLIP_DEVICE}
CLIP_PRETRAINED=${PLG_CLIP_PRETRAINED}
${PLG_CLIP_PATH_LINE}
DISABLE_SSL_VERIFY=${PLG_DISABLE_SSL_VERIFY}
PYTHONHTTPSVERIFY=0
USE_PGVECTOR=${PLG_USE_PGVECTOR}
FAISS_INDEX_PATH=${PLG_APP_DIR}/data/faiss_index.bin
FAISS_METADATA_PATH=${PLG_APP_DIR}/data/faiss_metadata.json
FAISS_DIMENSION=${PLG_FAISS_DIMENSION}
FAISS_TOP_K=${PLG_FAISS_TOP_K}
REFERENCE_IMAGES_DIR=${PLG_APP_DIR}/data/reference_images
TEMP_IMAGES_DIR=${PLG_APP_DIR}/data/temp_images
LOG_LEVEL=${PLG_LOG_LEVEL}
MOCK_GLIFIC=${PLG_MOCK_GLIFIC}
RESUBMISSION_WINDOW_MINUTES=${PLG_RESUBMISSION_WINDOW_MINUTES}"

  WRITE_ENV_BODY="
cat > ${PLG_APP_DIR}/.env << 'INNEREOF'
${ENV_CONTENT}
INNEREOF
sed -i 's/\r//' ${PLG_APP_DIR}/.env
echo \".env: \$(wc -l < ${PLG_APP_DIR}/.env) lines\"
"
  run_remote_heredoc "Write .env" "$WRITE_ENV_BODY"
  success ".env written"
fi


if step_enabled 9; then
  header "Step 9 — Pull container images"
  if $PLG_PARALLEL_PULL; then
    PULL_BODY="
podman pull ${PLG_POSTGRES_IMAGE} --quiet &
podman pull ${PLG_RABBITMQ_IMAGE} --quiet &
podman pull docker.io/library/redis:7-alpine --quiet &
wait
echo 'All images pulled (parallel).'
"
  else
    PULL_BODY="
podman pull ${PLG_POSTGRES_IMAGE} --quiet
podman pull ${PLG_RABBITMQ_IMAGE} --quiet
podman pull docker.io/library/redis:7-alpine --quiet
echo 'All images pulled.'
"
  fi
  run_remote_heredoc "Pull images" "$PULL_BODY"
  success "Container images pulled"
fi


if step_enabled 10; then
  if [[ "${PLG_DOWNLOAD_CLIP_MODEL}" == "true" ]] && ! $PLG_SKIP_MODEL; then
    header "Step 10 — Download CLIP model"
    MODEL_BODY="
cd ${PLG_APP_DIR}
source venv/bin/activate
python scripts/download_clip_model.py --model ViT-L-14
echo 'CLIP model downloaded.'
"
    run_remote_heredoc "Download CLIP model" "$MODEL_BODY"
    success "CLIP model downloaded"
  else
    info "Step 10 — Skipping CLIP model download"
  fi
fi


if step_enabled 11; then
  header "Step 11 — Redis containers"
  INFRA_SVC_BODY="
mkdir -p \"\${HOME}/.config/systemd/user/\"

cat > \"\${HOME}/.config/systemd/user/plg-redis-cache.service\" << 'SVCEOF'
[Unit]
Description=PLG Redis cache
Wants=network-online.target
After=network-online.target
RequiresMountsFor=%t/containers

[Service]
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=on-failure
TimeoutStopSec=70
ExecStart=/usr/bin/podman run \
        --cidfile=%t/%n.ctr-id \
        --cgroups=no-conmon \
        --rm \
        --sdnotify=conmon \
        --replace \
        -d \
        --name plg-redis-cache \
        -p 127.0.0.1:${PLG_FRAPPE_REDIS_CACHE_PORT}:6379 \
        docker.io/library/redis:7-alpine
ExecStop=/usr/bin/podman stop --ignore -t 10 --cidfile=%t/%n.ctr-id
ExecStopPost=/usr/bin/podman rm -f --ignore -t 10 --cidfile=%t/%n.ctr-id
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
SVCEOF

cat > \"\${HOME}/.config/systemd/user/plg-redis-queue.service\" << 'SVCEOF'
[Unit]
Description=PLG Redis queue
Wants=network-online.target
After=network-online.target
RequiresMountsFor=%t/containers

[Service]
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=on-failure
TimeoutStopSec=70
ExecStart=/usr/bin/podman run \
        --cidfile=%t/%n.ctr-id \
        --cgroups=no-conmon \
        --rm \
        --sdnotify=conmon \
        --replace \
        -d \
        --name plg-redis-queue \
        -p 127.0.0.1:${PLG_FRAPPE_REDIS_QUEUE_PORT}:6379 \
        docker.io/library/redis:7-alpine
ExecStop=/usr/bin/podman stop --ignore -t 10 --cidfile=%t/%n.ctr-id
ExecStopPost=/usr/bin/podman rm -f --ignore -t 10 --cidfile=%t/%n.ctr-id
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
SVCEOF

systemctl --user daemon-reload
systemctl --user enable --now plg-redis-cache.service
systemctl --user enable --now plg-redis-queue.service

sleep 5
podman ps --filter name=plg
"
  run_remote_heredoc "Start Redis" "$INFRA_SVC_BODY"
  success "Redis containers running"
fi


if step_enabled 12; then
  header "Step 12 — Start Postgres"
  _PG_INIT_WAIT=20
  $PLG_NO_WAIT && _PG_INIT_WAIT=0
  POSTGRES_BODY="
mkdir -p \"\${HOME}/.config/systemd/user/\"

cat > \"\${HOME}/.config/systemd/user/plg-postgres.service\" << 'SVCEOF'
[Unit]
Description=PLG Postgres pgvector
Wants=network-online.target
After=network-online.target
RequiresMountsFor=%t/containers

[Service]
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=on-failure
TimeoutStopSec=70
ExecStart=/usr/bin/podman run \
        --cidfile=%t/%n.ctr-id \
        --cgroups=no-conmon \
        --rm \
        --sdnotify=conmon \
        --replace \
        -d \
        --name ${PLG_POSTGRES_CONTAINER_NAME} \
        -p 127.0.0.1:${PLG_POSTGRES_PORT}:5432 \
        -e POSTGRES_DB=${PLG_POSTGRES_DB} \
        -e POSTGRES_USER=${PLG_POSTGRES_USER} \
        -e POSTGRES_PASSWORD=${PLG_POSTGRES_PASSWORD} \
        -e PGDATA=/var/lib/postgresql/data/pgdata \
        -v ${PLG_POSTGRES_VOLUME_NAME}:/var/lib/postgresql/data \
        -v ${PLG_APP_DIR}/database/init.sql:/docker-entrypoint-initdb.d/init.sql \
        ${PLG_POSTGRES_IMAGE}
ExecStop=/usr/bin/podman stop --ignore -t 10 --cidfile=%t/%n.ctr-id
ExecStopPost=/usr/bin/podman rm -f --ignore -t 10 --cidfile=%t/%n.ctr-id
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
SVCEOF

systemctl --user daemon-reload
systemctl --user enable --now plg-postgres.service

echo 'Waiting ${_PG_INIT_WAIT}s for Postgres to initialise...'
sleep ${_PG_INIT_WAIT}

for i in 1 2 3 4 5 6; do
  if podman exec ${PLG_POSTGRES_CONTAINER_NAME} pg_isready &>/dev/null; then
    echo 'Postgres accepting connections.'
    break
  fi
  echo \"Attempt \$i/6 — waiting 10s...\"
  sleep 10
  [[ \$i -eq 6 ]] && { echo 'ERROR: Postgres not ready after 80s'; exit 1; }
done
"
  run_remote_heredoc "Start Postgres" "$POSTGRES_BODY"
  success "Postgres ready"
fi


if step_enabled 13; then
  header "Step 13 — bench init"
  BENCH_INIT_BODY="
BENCH=\"\${HOME}/.local/bin/bench\"
[[ -f \"\${BENCH}\" ]] || { echo 'ERROR: bench not found at ~/.local/bin/bench'; exit 1; }
echo \"Using bench: \$(\${BENCH} --version)\"

if command -v ${PLG_FRAPPE_PYTHON} &>/dev/null; then
  PYTHON_BIN=${PLG_FRAPPE_PYTHON}
else
  PYTHON_BIN=\$(command -v python3)
  echo \"${PLG_FRAPPE_PYTHON} not found — falling back to \${PYTHON_BIN}\"
fi

if [[ ! -d ${PLG_FRAPPE_BENCH_DIR}/apps/frappe ]]; then
  \${BENCH} init \
    --frappe-branch ${PLG_FRAPPE_BRANCH} \
    --python \${PYTHON_BIN} \
    --skip-redis-config-generation \
    ${PLG_FRAPPE_BENCH_DIR}
else
  echo 'Frappe bench already initialised, skipping bench init.'
fi

cd ${PLG_FRAPPE_BENCH_DIR}

\${BENCH} set-config -g db_host 127.0.0.1
\${BENCH} set-config -g db_port ${PLG_POSTGRES_PORT}
\${BENCH} set-config -g redis_cache    redis://127.0.0.1:${PLG_FRAPPE_REDIS_CACHE_PORT}
\${BENCH} set-config -g redis_queue    redis://127.0.0.1:${PLG_FRAPPE_REDIS_QUEUE_PORT}
\${BENCH} set-config -g redis_socketio redis://127.0.0.1:${PLG_FRAPPE_REDIS_QUEUE_PORT}
\${BENCH} set-config -g webserver_port ${PLG_FRAPPE_WEB_PORT}
\${BENCH} set-config -g socketio_port  ${PLG_FRAPPE_SOCKETIO_PORT}
\${BENCH} set-config -g serve_default_site true
\${BENCH} set-config -g default_site ${PLG_FRAPPE_SITE_NAME}

echo 'Bench initialised.'
"
  run_remote_heredoc "bench init" "$BENCH_INIT_BODY"
  success "Frappe bench initialised at ${PLG_FRAPPE_BENCH_DIR}"
fi


if step_enabled 14; then
  header "Step 14 — Create Frappe site (Postgres)"
  SITE_BODY="
BENCH=\"\${HOME}/.local/bin/bench\"
cd ${PLG_FRAPPE_BENCH_DIR}

if [[ ! -d ${PLG_FRAPPE_BENCH_DIR}/sites/${PLG_FRAPPE_SITE_NAME} ]]; then
  \${BENCH} new-site ${PLG_FRAPPE_SITE_NAME} \
    --db-type postgres \
    --db-host 127.0.0.1 \
    --db-port ${PLG_POSTGRES_PORT} \
    --db-root-username ${PLG_POSTGRES_USER} \
    --db-root-password ${PLG_POSTGRES_PASSWORD} \
    --admin-password ${PLG_FRAPPE_ADMIN_PASSWORD}
else
  echo 'Site already exists, skipping new-site.'
fi

\${BENCH} use ${PLG_FRAPPE_SITE_NAME}
echo ${PLG_FRAPPE_SITE_NAME} > ${PLG_FRAPPE_BENCH_DIR}/sites/currentsite.txt

mkdir -p \${HOME}/logs
ln -sfn \${HOME}/logs ${PLG_FRAPPE_BENCH_DIR}/logs 2>/dev/null || true

cat > ${PLG_FRAPPE_BENCH_DIR}/sites/frappe_wsgi.py << 'WSGIEOF'
import sys
import os

sys.path.insert(0, '${PLG_FRAPPE_BENCH_DIR}/apps/frappe')

import frappe.app as _fapp

_fapp._sites_path = '${PLG_FRAPPE_BENCH_DIR}/sites'
_fapp._site = '${PLG_FRAPPE_SITE_NAME}'

_base = _fapp.application_with_statics()

_SITE = '${PLG_FRAPPE_SITE_NAME}'

class _SiteMiddleware:
    def __init__(self, app):
        self.app = app
    def __call__(self, environ, start_response):
        environ['HTTP_X_FRAPPE_SITE_NAME'] = _SITE
        return self.app(environ, start_response)

application = _SiteMiddleware(_base)
WSGIEOF

echo 'Site created and WSGI wrapper written: ${PLG_FRAPPE_SITE_NAME}'
"
  run_remote_heredoc "bench new-site" "$SITE_BODY"
  success "Frappe site created: ${PLG_FRAPPE_SITE_NAME}"
fi


if step_enabled 15; then
  header "Step 15 — Install plagiarism_app"
  APP_INSTALL_BODY="
BENCH=\"\${HOME}/.local/bin/bench\"
cd ${PLG_FRAPPE_BENCH_DIR}

if [[ ! -d ${PLG_FRAPPE_BENCH_DIR}/apps/plagiarism_app ]]; then
  \${BENCH} get-app \
    --branch ${PLG_PLAGIARISM_APP_BRANCH} \
    ${PLG_PLAGIARISM_APP_REPO}
else
  echo 'plagiarism_app already present, skipping get-app.'
fi

\${BENCH} --site ${PLG_FRAPPE_SITE_NAME} install-app plagiarism_app
\${BENCH} --site ${PLG_FRAPPE_SITE_NAME} migrate

echo 'plagiarism_app installed and migrated.'
"
  run_remote_heredoc "Install plagiarism_app" "$APP_INSTALL_BODY"
  success "plagiarism_app installed"
fi


if step_enabled 16; then
  if [[ "${PLG_SETUP_SYSTEMD:-false}" == "true" ]]; then
    header "Step 16 — Systemd service units"

    SYSTEMD_BODY="
mkdir -p \"\${HOME}/.config/systemd/user/\"

cat > \"\${HOME}/.config/systemd/user/plg-rabbitmq.service\" << 'SVCEOF'
[Unit]
Description=PLG RabbitMQ
Wants=network-online.target
After=network-online.target
RequiresMountsFor=%t/containers

[Service]
Environment=PODMAN_SYSTEMD_UNIT=%n
Restart=on-failure
TimeoutStopSec=70
ExecStart=/usr/bin/podman run \
        --cidfile=%t/%n.ctr-id \
        --cgroups=no-conmon \
        --rm \
        --sdnotify=conmon \
        --replace \
        -d \
        --name ${PLG_RABBITMQ_CONTAINER_NAME} \
        -p 127.0.0.1:${PLG_RABBITMQ_PORT}:5672 \
        -p 127.0.0.1:${PLG_RABBITMQ_MANAGEMENT_PORT}:15672 \
        -e RABBITMQ_DEFAULT_USER=${PLG_RABBITMQ_USER} \
        -e RABBITMQ_DEFAULT_PASS=${PLG_RABBITMQ_PASS} \
        ${PLG_RABBITMQ_IMAGE}
ExecStop=/usr/bin/podman stop --ignore -t 10 --cidfile=%t/%n.ctr-id
ExecStopPost=/usr/bin/podman rm -f --ignore -t 10 --cidfile=%t/%n.ctr-id
Type=notify
NotifyAccess=all

[Install]
WantedBy=default.target
SVCEOF

cat > \"\${HOME}/.config/systemd/user/plg_app.service\" << 'SVCEOF'
[Unit]
Description=PLG Plagiarism Worker
After=plg-postgres.service plg-rabbitmq.service
Requires=plg-postgres.service plg-rabbitmq.service

[Service]
Type=simple
WorkingDirectory=${PLG_APP_DIR}
EnvironmentFile=${PLG_APP_DIR}/.env
ExecStart=${PLG_VENV_DIR}/bin/python3 ${PLG_APP_DIR}/app.py
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
SVCEOF

cat > \"\${HOME}/.config/systemd/user/plg_api.service\" << 'SVCEOF'
[Unit]
Description=PLG Plagiarism FastAPI
After=plg-postgres.service plg-rabbitmq.service
Requires=plg-postgres.service

[Service]
Type=simple
WorkingDirectory=${PLG_APP_DIR}/api
EnvironmentFile=${PLG_APP_DIR}/.env
ExecStart=${PLG_VENV_DIR}/bin/uvicorn api:app --host ${PLG_API_HOST} --port ${PLG_API_PORT}
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
SVCEOF

cat > \"\${HOME}/.config/systemd/user/plg-frappe-web.service\" << 'SVCEOF'
[Unit]
Description=PLG Frappe web
After=plg-postgres.service plg-redis-cache.service plg-redis-queue.service
Requires=plg-postgres.service plg-redis-cache.service plg-redis-queue.service

[Service]
Type=simple
WorkingDirectory=${PLG_FRAPPE_BENCH_DIR}/sites
ExecStartPre=/bin/bash -c 'echo ${PLG_FRAPPE_SITE_NAME} > ${PLG_FRAPPE_BENCH_DIR}/sites/currentsite.txt && mkdir -p \${HOME}/logs'
ExecStart=${PLG_FRAPPE_BENCH_DIR}/env/bin/gunicorn \
  --bind=0.0.0.0:${PLG_FRAPPE_WEB_PORT} \
  --workers=${PLG_FRAPPE_GUNICORN_WORKERS} \
  --worker-class=gthread \
  --threads=${PLG_FRAPPE_GUNICORN_THREADS} \
  --timeout=${PLG_FRAPPE_GUNICORN_TIMEOUT} \
  frappe_wsgi:application
Restart=always
RestartSec=10
Environment=PYTHONPATH=${PLG_FRAPPE_BENCH_DIR}/apps/frappe

[Install]
WantedBy=default.target
SVCEOF

cat > \"\${HOME}/.config/systemd/user/plg-frappe-worker.service\" << 'SVCEOF'
[Unit]
Description=PLG Frappe worker
After=plg-redis-queue.service plg-postgres.service
Requires=plg-redis-queue.service plg-postgres.service

[Service]
Type=simple
WorkingDirectory=${PLG_FRAPPE_BENCH_DIR}
ExecStart=${PLG_FRAPPE_BENCH_DIR}/env/bin/python \
  -m frappe.utils.bench_helper worker --queue short,default,long
Restart=always
RestartSec=10
Environment=FRAPPE_BENCH_ROOT=${PLG_FRAPPE_BENCH_DIR}
Environment=FRAPPE_SITE=${PLG_FRAPPE_SITE_NAME}

[Install]
WantedBy=default.target
SVCEOF

cat > \"\${HOME}/.config/systemd/user/plg-frappe-schedule.service\" << 'SVCEOF'
[Unit]
Description=PLG Frappe scheduler
After=plg-redis-queue.service plg-postgres.service
Requires=plg-redis-queue.service plg-postgres.service

[Service]
Type=simple
WorkingDirectory=${PLG_FRAPPE_BENCH_DIR}
ExecStart=${PLG_FRAPPE_BENCH_DIR}/env/bin/python \
  -m frappe.utils.bench_helper schedule
Restart=always
RestartSec=10
Environment=FRAPPE_BENCH_ROOT=${PLG_FRAPPE_BENCH_DIR}
Environment=FRAPPE_SITE=${PLG_FRAPPE_SITE_NAME}

[Install]
WantedBy=default.target
SVCEOF

echo 'Service files written.'
"
    run_remote_heredoc "Write service files" "$SYSTEMD_BODY"
    success "Systemd service files created"

    if [[ "${PLG_ENABLE_LINGER:-false}" == "true" ]]; then
      run_remote "Enable linger" \
        "loginctl enable-linger ${PLG_SERVER_USER} && loginctl show-user ${PLG_SERVER_USER} | grep Linger"
      success "Linger enabled"
    fi

    _SVC_START_WAIT=10
    _SVC_SETTLE_WAIT=5
    $PLG_NO_WAIT && _SVC_START_WAIT=0
    $PLG_NO_WAIT && _SVC_SETTLE_WAIT=0

    START_BODY="
systemctl --user daemon-reload

systemctl --user enable --now plg-postgres.service
systemctl --user enable --now plg-rabbitmq.service
sleep ${_SVC_START_WAIT}

systemctl --user enable --now plg_app.service
systemctl --user enable --now plg_api.service

systemctl --user enable --now plg-frappe-web.service
systemctl --user enable --now plg-frappe-worker.service
systemctl --user enable --now plg-frappe-schedule.service

sleep ${_SVC_SETTLE_WAIT}

echo '=== Containers ==='
podman ps

echo ''
echo '=== Service status ==='
for svc in plg-postgres plg-rabbitmq plg-redis-cache plg-redis-queue plg_app plg_api plg-frappe-web plg-frappe-worker plg-frappe-schedule; do
  state=\$(systemctl --user is-active \${svc}.service 2>/dev/null || echo unknown)
  printf '  %-42s %s\n' \"\${svc}.service\" \"\$state\"
done
"
    run_remote_heredoc "Start all services" "$START_BODY"
    success "All services started"
  else
    info "Step 16 — Skipping systemd setup (PLG_SETUP_SYSTEMD=false)"
  fi
fi


if step_enabled 17; then
  if [[ "${PLG_OPEN_FIREWALL_PORT:-false}" == "true" ]]; then
    header "Step 17 — Firewall"
    FIREWALL_BODY="
if command -v ufw &>/dev/null; then
  sudo ufw allow ${PLG_API_PORT}/tcp        2>/dev/null || true
  sudo ufw allow ${PLG_FRAPPE_WEB_PORT}/tcp 2>/dev/null || true
  sudo ufw allow ${PLG_OBSERVER_PORT}/tcp   2>/dev/null || true
  sudo ufw allow ${PLG_DEPLOYER_PORT}/tcp   2>/dev/null || true
  echo 'ufw: opened ${PLG_API_PORT}, ${PLG_FRAPPE_WEB_PORT}, ${PLG_OBSERVER_PORT}, ${PLG_DEPLOYER_PORT}'
else
  echo 'ufw not found — configure cloud NSG manually'
fi
"
    run_remote_heredoc "Open ports" "$FIREWALL_BODY"
    warn "Also open ports ${PLG_API_PORT}, ${PLG_FRAPPE_WEB_PORT}, ${PLG_OBSERVER_PORT}, ${PLG_DEPLOYER_PORT} in your cloud NSG."
  else
    info "Step 17 — Skipping firewall (PLG_OPEN_FIREWALL_PORT=false)"
  fi
fi


if step_enabled 19; then
  do_write_observer
fi


if step_enabled 20; then
  do_write_deployer
fi


if step_enabled 18; then
  header "Step 18 — Health check"
  PLG_WAIT 3
  do_status
fi


echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}${GREEN}  Deployment complete!${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  PLG API     ${CYAN}http://${PLG_SERVER_HOST}:${PLG_API_PORT}/docs${RESET}"
echo -e "  Frappe      ${CYAN}http://${PLG_SERVER_HOST}:${PLG_FRAPPE_WEB_PORT}${RESET}  (${PLG_FRAPPE_ADMIN_USER} / ${PLG_FRAPPE_ADMIN_PASSWORD})"
echo -e "  RabbitMQ    ${CYAN}http://${PLG_SERVER_HOST}:${PLG_RABBITMQ_MANAGEMENT_PORT}${RESET}  (${PLG_RABBITMQ_USER} / ${PLG_RABBITMQ_PASS})"
echo -e "  Observer    ${CYAN}http://${PLG_SERVER_HOST}:${PLG_OBSERVER_PORT}/docs${RESET}  (X-Deploy-Key: \${PLG_DEPLOY_SECRET_KEY})"
echo -e "  Deployer    ${CYAN}http://${PLG_SERVER_HOST}:${PLG_DEPLOYER_PORT}/docs${RESET}  POST /deploy/trigger  GET /deploy/status"
echo ""
echo -e "  ${YELLOW}Isolated ports:${RESET}"
echo -e "    Redis cache   127.0.0.1:${PLG_FRAPPE_REDIS_CACHE_PORT}"
echo -e "    Redis queue   127.0.0.1:${PLG_FRAPPE_REDIS_QUEUE_PORT}"
echo -e "    Frappe web    0.0.0.0:${PLG_FRAPPE_WEB_PORT}"
echo -e "    PLG API       0.0.0.0:${PLG_API_PORT}"
echo -e "    Postgres      127.0.0.1:${PLG_POSTGRES_PORT}"
echo -e "    RabbitMQ      127.0.0.1:${PLG_RABBITMQ_PORT}"
echo -e "    Observer      0.0.0.0:${PLG_OBSERVER_PORT}"
echo -e "    Deployer      0.0.0.0:${PLG_DEPLOYER_PORT}"
echo ""
echo -e "  ${YELLOW}GitHub Actions webhook (curl example):${RESET}"
echo -e "    curl -X POST http://${PLG_SERVER_HOST}:${PLG_DEPLOYER_PORT}/deploy/trigger \\"
echo -e "         -H 'X-Deploy-Key: \${PLG_DEPLOY_SECRET_KEY}'"
echo ""
echo -e "  ${YELLOW}Observer API (curl examples):${RESET}"
echo -e "    curl -H 'X-Deploy-Key: \${PLG_DEPLOY_SECRET_KEY}' http://${PLG_SERVER_HOST}:${PLG_OBSERVER_PORT}/health"
echo -e "    curl -H 'X-Deploy-Key: \${PLG_DEPLOY_SECRET_KEY}' http://${PLG_SERVER_HOST}:${PLG_OBSERVER_PORT}/logs"
echo -e "    curl -H 'X-Deploy-Key: \${PLG_DEPLOY_SECRET_KEY}' http://${PLG_SERVER_HOST}:${PLG_OBSERVER_PORT}/usage"
echo -e "    curl -H 'X-Deploy-Key: \${PLG_DEPLOY_SECRET_KEY}' http://${PLG_SERVER_HOST}:${PLG_OBSERVER_PORT}/deployments"
echo ""
echo -e "  ${YELLOW}Useful commands:${RESET}"
echo -e "    ssh $SSH_OPTS ${TARGET} 'journalctl --user -u plg_app.service -f'"
echo -e "    ssh $SSH_OPTS ${TARGET} 'journalctl --user -u plg-frappe-web.service -f'"
echo -e "    ssh $SSH_OPTS ${TARGET} 'journalctl --user -u plg-observer.service -f'"
echo -e "    ssh $SSH_OPTS ${TARGET} 'journalctl --user -u plg-deployer.service -f'"
echo -e "    ssh $SSH_OPTS ${TARGET} 'podman ps'"
echo -e "    ssh $SSH_OPTS ${TARGET} 'cd ${PLG_FRAPPE_BENCH_DIR} && ~/.local/bin/bench migrate'"
echo ""
echo -e "  ${YELLOW}Re-run specific steps:${RESET}  $0 --steps 14,15,16"
echo -e "  ${YELLOW}Quick ops:${RESET}"
echo -e "    $0 --clean-only          Wipe everything"
echo -e "    $0 --clean               Wipe then redeploy"
echo -e "    $0 --restart             Restart all services"
echo -e "    $0 --status              Show health check"
echo -e "    $0 --update              Safe atomic code update (validates before swap)"
echo -e "    $0 --update-config       Re-write .env + restart app (no code change)"
echo -e "    $0 --clean-services      Remove only service units"
echo -e "    $0 --clean-containers    Remove only containers"
echo -e "    $0 --clean-volumes       Remove only volumes"
echo -e "    $0 --clean-dirs          Remove only app/bench dirs"
echo -e "    $0 --clean-venv          Remove only Python venv"
echo -e "    $0 --parallel-pull       Pull images in parallel"
echo -e "    $0 --no-wait             Skip all sleep delays"
echo -e "    $0 --force               Skip confirmation prompts"
echo ""
echo -e "  ${YELLOW}NOTE:${RESET} Open ports ${PLG_API_PORT}, ${PLG_FRAPPE_WEB_PORT}, ${PLG_OBSERVER_PORT}, ${PLG_DEPLOYER_PORT} in your cloud NSG."
echo ""