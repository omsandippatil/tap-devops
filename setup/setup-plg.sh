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

PLG_CONFIG_FILE="${PLG_CONFIG_FILE:-./tap-devops/config.env}"
PLG_SKIP_MODEL="${PLG_SKIP_MODEL:-false}"
PLG_DRY_RUN="${PLG_DRY_RUN:-false}"
PLG_STEPS="${PLG_STEPS:-}"
PLG_CLEAN="${PLG_CLEAN:-false}"
PLG_CLEAN_ONLY="${PLG_CLEAN_ONLY:-false}"
PLG_RESTART_ONLY="${PLG_RESTART_ONLY:-false}"
PLG_STOP_ONLY="${PLG_STOP_ONLY:-false}"
PLG_STATUS_ONLY="${PLG_STATUS_ONLY:-false}"
PLG_UPDATE_ONLY="${PLG_UPDATE_ONLY:-false}"
PLG_UPDATE_CONFIG_ONLY="${PLG_UPDATE_CONFIG_ONLY:-false}"
PLG_CLEAN_SERVICES="${PLG_CLEAN_SERVICES:-false}"
PLG_CLEAN_CONTAINERS="${PLG_CLEAN_CONTAINERS:-false}"
PLG_CLEAN_VOLUMES="${PLG_CLEAN_VOLUMES:-false}"
PLG_CLEAN_DIRS="${PLG_CLEAN_DIRS:-false}"
PLG_CLEAN_VENV="${PLG_CLEAN_VENV:-false}"
PLG_FORCE="${PLG_FORCE:-false}"
PLG_VERBOSE="${PLG_VERBOSE:-false}"
PLG_NO_WAIT="${PLG_NO_WAIT:-false}"
PLG_PARALLEL_PULL="${PLG_PARALLEL_PULL:-false}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)           PLG_CONFIG_FILE="$2"; shift 2 ;;
    --skip-model)       PLG_SKIP_MODEL=true; shift ;;
    --dry-run)          PLG_DRY_RUN=true; shift ;;
    --steps)            PLG_STEPS="$2"; shift 2 ;;
    --clean)            PLG_CLEAN=true; shift ;;
    --clean-only)       PLG_CLEAN=true; PLG_CLEAN_ONLY=true; shift ;;
    --restart)          PLG_RESTART_ONLY=true; shift ;;
    --stop)             PLG_STOP_ONLY=true; shift ;;
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
    --help)
      echo "Usage: $0 [--config FILE] [--steps N,N-N] [--clean] [--clean-only]"
      echo "          [--restart] [--stop] [--status] [--update] [--update-config]"
      echo "          [--clean-services] [--clean-containers] [--clean-volumes]"
      echo "          [--clean-dirs] [--clean-venv] [--skip-model] [--dry-run]"
      echo "          [--force] [--verbose] [--no-wait] [--parallel-pull]"
      echo ""
      echo "All flags can also be set as environment variables (e.g. PLG_UPDATE_ONLY=true)."
      echo "See config.env for all configurable variables."
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ -f "$PLG_CONFIG_FILE" ]] || die "Config file not found: $PLG_CONFIG_FILE"
source "$PLG_CONFIG_FILE"
success "Loaded config: $PLG_CONFIG_FILE"

PLG_LOG_DIR="${PLG_LOG_DIR:-./tap-devops/logs}"
PLG_LOG_MAX_MB="${PLG_LOG_MAX_MB:-10}"
PLG_LOG_BACKUP_COUNT="${PLG_LOG_BACKUP_COUNT:-5}"

mkdir -p "${PLG_LOG_DIR}"

_rotate_log() {
  local logfile="$1"
  local max_bytes=$(( PLG_LOG_MAX_MB * 1024 * 1024 ))
  local actual_size=0
  if [[ -f "$logfile" ]]; then
    actual_size=$(stat -c%s "$logfile" 2>/dev/null || stat -f%z "$logfile" 2>/dev/null || echo 0)
  fi
  if (( actual_size >= max_bytes )); then
    local i
    for (( i=PLG_LOG_BACKUP_COUNT-1; i>=1; i-- )); do
      [[ -f "${logfile}.${i}" ]] && mv "${logfile}.${i}" "${logfile}.$((i+1))"
    done
    mv "$logfile" "${logfile}.1"
  fi
}

_log_to_file() {
  local logfile="$1"
  shift
  _rotate_log "$logfile"
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$logfile"
}

PLG_DEPLOY_LOG="${PLG_LOG_DIR}/plg-deploy.log"
PLG_APPID_LOG="${PLG_LOG_DIR}/appid-deploy.log"

_deploy_log() { _log_to_file "$PLG_DEPLOY_LOG" "$*"; }
_appid_log()  { _log_to_file "$PLG_APPID_LOG"  "$*"; }

_tee_deploy_log() {
  while IFS= read -r line; do
    echo "$line"
    _log_to_file "$PLG_DEPLOY_LOG" "$line"
  done
}

$PLG_DRY_RUN && warn "DRY RUN — SSH commands printed, not executed."

REQUIRED_VARS=(
  PLG_SERVER_USER PLG_SERVER_HOST PLG_SSH_KEY_PATH
  PLG_APP_DIR PLG_GIT_REPO PLG_GIT_BRANCH
  PLG_POSTGRES_USER PLG_POSTGRES_PASSWORD PLG_POSTGRES_DB PLG_POSTGRES_PORT
  PLG_DEPLOY_SECRET_KEY
)
for v in "${REQUIRED_VARS[@]}"; do
  [[ -n "${!v:-}" ]] || die "Required config var \$$v not set in $PLG_CONFIG_FILE"
done

PLG_SSH_PORT="${PLG_SSH_PORT:-22}"
SSH_OPTS="-i ${PLG_SSH_KEY_PATH} -p ${PLG_SSH_PORT} -o StrictHostKeyChecking=no -o ConnectTimeout=15"
TARGET="${PLG_SERVER_USER}@${PLG_SERVER_HOST}"
ALL_SERVICES="plg-app plg-api plg-postgres plg-rabbitmq plg-redis-cache plg-redis-queue"
APP_SERVICES="plg-app plg-api"

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
      lo="${token%-*}"; hi="${token#*-}"
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
  _deploy_log "Remote: $desc"
  if $PLG_DRY_RUN; then
    echo -e "  ${YELLOW}$ $*${RESET}"
    return 0
  fi
  ssh $SSH_OPTS "$TARGET" "$@" 2>&1 | _tee_deploy_log
}

run_remote_heredoc() {
  local desc="$1"
  local body="$2"
  info "Remote: $desc"
  _deploy_log "Remote: $desc"
  if $PLG_DRY_RUN; then
    echo -e "  ${YELLOW}[heredoc: $desc]${RESET}"
    return 0
  fi
  if $PLG_VERBOSE; then
    ssh $SSH_OPTS "$TARGET" "bash --login -s" 2>&1 <<EOF | _tee_deploy_log
${PLG_PATH_PREAMBLE}
set -euo pipefail
set -x
${body}
EOF
  else
    ssh $SSH_OPTS "$TARGET" "bash --login -s" 2>&1 <<EOF | _tee_deploy_log
${PLG_PATH_PREAMBLE}
set -euo pipefail
${body}
EOF
  fi
}

_build_env_content() {
  local hash_threshold_int
  hash_threshold_int=$(printf '%.0f' "${PLG_HASH_MATCH_THRESHOLD:-10}")

  local clip_path_line
  if [[ "${PLG_CLIP_MODEL_SOURCE:-}" == "local" ]]; then
    clip_path_line="CLIP_LOCAL_MODEL_PATH=${PLG_CLIP_LOCAL_MODEL_PATH}"
  else
    clip_path_line="CLIP_LOCAL_MODEL_PATH="
  fi

  local app_log_dir="${PLG_APP_LOG_DIR:-${PLG_APP_DIR}/logs}"
  local app_log_max_mb="${PLG_APP_LOG_MAX_MB:-${PLG_LOG_MAX_MB:-100}}"
  local app_log_backup_count="${PLG_APP_LOG_BACKUP_COUNT:-${PLG_LOG_BACKUP_COUNT:-5}}"

  printf '%s\n' \
    "RABBITMQ_HOST=${PLG_RABBITMQ_HOST}" \
    "RABBITMQ_PORT=${PLG_RABBITMQ_PORT}" \
    "RABBITMQ_USER=${PLG_RABBITMQ_USER}" \
    "RABBITMQ_PASS=${PLG_RABBITMQ_PASS}" \
    "RABBITMQ_MANAGEMENT_PORT=${PLG_RABBITMQ_MANAGEMENT_PORT}" \
    "RABBITMQ_PREFETCH_COUNT=${PLG_RABBITMQ_PREFETCH_COUNT}" \
    "MAX_RETRIES=${PLG_MAX_RETRIES}" \
    "SUBMISSION_QUEUE=${PLG_SUBMISSION_QUEUE}" \
    "FEEDBACK_QUEUE=${PLG_FEEDBACK_QUEUE}" \
    "DEAD_LETTER_QUEUE=${PLG_DEAD_LETTER_QUEUE}" \
    "POSTGRES_HOST=${PLG_POSTGRES_HOST}" \
    "POSTGRES_PORT=${PLG_POSTGRES_PORT}" \
    "POSTGRES_DB=${PLG_POSTGRES_DB}" \
    "POSTGRES_USER=${PLG_POSTGRES_USER}" \
    "POSTGRES_PASSWORD=${PLG_POSTGRES_PASSWORD}" \
    "POSTGRES_POOL_SIZE=${PLG_POSTGRES_POOL_SIZE}" \
    "POSTGRES_MAX_OVERFLOW=${PLG_POSTGRES_MAX_OVERFLOW}" \
    "EXACT_DUPLICATE_THRESHOLD=${PLG_EXACT_DUPLICATE_THRESHOLD}" \
    "NEAR_DUPLICATE_THRESHOLD=${PLG_NEAR_DUPLICATE_THRESHOLD}" \
    "SEMANTIC_MATCH_THRESHOLD=${PLG_SEMANTIC_MATCH_THRESHOLD}" \
    "HASH_MATCH_THRESHOLD=${hash_threshold_int}" \
    "MAX_IMAGE_SIZE_MB=${PLG_MAX_IMAGE_SIZE_MB}" \
    "IMAGE_DOWNLOAD_TIMEOUT=${PLG_IMAGE_DOWNLOAD_TIMEOUT}" \
    "IMAGE_MIN_VARIANCE=${PLG_IMAGE_MIN_VARIANCE}" \
    "IMAGE_MIN_UNIQUE_COLORS=${PLG_IMAGE_MIN_UNIQUE_COLORS}" \
    "IMAGE_MAX_SOLID_COLOR_RATIO=${PLG_IMAGE_MAX_SOLID_COLOR_RATIO}" \
    "CLIP_MODEL=${PLG_CLIP_MODEL}" \
    "CLIP_DEVICE=${PLG_CLIP_DEVICE}" \
    "CLIP_PRETRAINED=${PLG_CLIP_PRETRAINED}" \
    "${clip_path_line}" \
    "DISABLE_SSL_VERIFY=${PLG_DISABLE_SSL_VERIFY}" \
    "PYTHONHTTPSVERIFY=0" \
    "USE_PGVECTOR=${PLG_USE_PGVECTOR}" \
    "FAISS_INDEX_PATH=${PLG_APP_DIR}/data/faiss_index.bin" \
    "FAISS_METADATA_PATH=${PLG_APP_DIR}/data/faiss_metadata.json" \
    "FAISS_DIMENSION=${PLG_FAISS_DIMENSION}" \
    "FAISS_TOP_K=${PLG_FAISS_TOP_K}" \
    "REFERENCE_IMAGES_DIR=${PLG_APP_DIR}/data/reference_images" \
    "TEMP_IMAGES_DIR=${PLG_APP_DIR}/data/temp_images" \
    "LOG_LEVEL=${PLG_LOG_LEVEL}" \
    "LOG_DIR=${app_log_dir}" \
    "LOG_MAX_MB=${app_log_max_mb}" \
    "LOG_BACKUP_COUNT=${app_log_backup_count}" \
    "MOCK_GLIFIC=${PLG_MOCK_GLIFIC}" \
    "RESUBMISSION_WINDOW_MINUTES=${PLG_RESUBMISSION_WINDOW_MINUTES}"
}

header "Pre-flight"
_deploy_log "=== Deploy session started ==="
_appid_log  "=== Deploy session started ==="
[[ -f "$PLG_SSH_KEY_PATH" ]] || die "SSH key not found: $PLG_SSH_KEY_PATH"
chmod 600 "$PLG_SSH_KEY_PATH"
success "SSH key OK"

if ! $PLG_DRY_RUN; then
  ssh $SSH_OPTS "$TARGET" "echo 'SSH OK'" > /dev/null \
    || die "Cannot connect to ${TARGET}."
fi
success "SSH connection verified"
_deploy_log "SSH connection verified to ${TARGET}"

do_stop() {
  header "Stop all services"
  _deploy_log "Action: stop"
  run_remote_heredoc "Stop all services" "
set +e
for svc in ${ALL_SERVICES}; do
  systemctl --user stop \${svc}.service 2>/dev/null || true
done
echo ''
for svc in ${ALL_SERVICES}; do
  state=\$(systemctl --user is-active \${svc}.service 2>/dev/null || echo inactive)
  printf '  %-36s %s\n' \"\${svc}.service\" \"\$state\"
done
"
  success "All services stopped"
  _deploy_log "All services stopped"
}

do_restart() {
  header "Restart all services"
  _deploy_log "Action: restart"
  run_remote_heredoc "Restart all services" "
set +e
for svc in ${ALL_SERVICES}; do
  systemctl --user restart \${svc}.service 2>/dev/null || true
done
sleep 4
echo ''
for svc in ${ALL_SERVICES}; do
  state=\$(systemctl --user is-active \${svc}.service 2>/dev/null || echo unknown)
  printf '  %-36s %s\n' \"\${svc}.service\" \"\$state\"
done
"
  success "Services restarted"
  _deploy_log "Services restarted"
}

do_status() {
  header "Health check"
  _deploy_log "Action: status"
  run_remote_heredoc "Status" "
set +e
echo '=== Containers ==='
podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

echo ''
echo '=== Systemd services ==='
for svc in ${ALL_SERVICES}; do
  state=\$(systemctl --user is-active \${svc}.service 2>/dev/null || echo unknown)
  printf '  %-36s %s\n' \"\${svc}.service\" \"\$state\"
done

echo ''
echo '=== Last 10 lines: plg-app ==='
journalctl --user -u plg-app.service -n 10 --no-pager 2>/dev/null || echo '(no logs)'

echo ''
echo '=== Last 10 lines: plg-api ==='
journalctl --user -u plg-api.service -n 10 --no-pager 2>/dev/null || echo '(no logs)'
"
}

do_full_clean() {
  header "Full clean"
  _deploy_log "Action: full clean"
  run_remote_heredoc "Full clean — everything" "
set +e

for svc in ${ALL_SERVICES}; do
  systemctl --user stop    \${svc}.service 2>/dev/null || true
  systemctl --user disable \${svc}.service 2>/dev/null || true
done
rm -f \"\${HOME}/.config/systemd/user/plg-\"*.service
systemctl --user daemon-reload 2>/dev/null || true

pkill -f uvicorn 2>/dev/null || true
pkill -f 'python3.*app.py' 2>/dev/null || true
sleep 2

podman stop \$(podman ps -aq) 2>/dev/null || true
podman rm -f \$(podman ps -aq) 2>/dev/null || true
podman volume rm \$(podman volume ls -q) 2>/dev/null || true
podman image prune -af 2>/dev/null || true

rm -rf ${PLG_APP_DIR}
rm -rf \${HOME}/\$(basename ${PLG_APP_DIR})__staging
find \${HOME} -maxdepth 1 -name '\$(basename ${PLG_APP_DIR})__backup_*' -type d -exec rm -rf {} + 2>/dev/null || true
find \${HOME} -maxdepth 3 -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true

rm -rf \${HOME}/.nvm
rm -rf \${HOME}/.npm
rm -rf \${HOME}/.yarn
rm -rf \${HOME}/.cache/pip
rm -rf \${HOME}/.cache/huggingface
rm -rf \${HOME}/.cache/torch
rm -rf \${HOME}/.local/share/containers
rm -rf \${HOME}/.config/containers

echo ''
echo '=== Remaining processes ==='
ps aux | grep -E 'python|uvicorn|podman|node' | grep -v grep || echo 'none'

echo ''
echo '=== Remaining containers ==='
podman ps -a 2>/dev/null || echo 'none'

echo ''
echo '=== Remaining volumes ==='
podman volume ls 2>/dev/null || echo 'none'

echo ''
echo '=== Home directory ==='
ls -la \${HOME}/

echo ''
echo '=== Disk usage ==='
df -h /
"
  success "Full clean complete"
  _deploy_log "Full clean complete"
}

do_selective_clean() {
  local did=0

  if $PLG_CLEAN_SERVICES; then
    header "Clean: services"
    _deploy_log "Action: clean services"
    run_remote_heredoc "Remove systemd services" "
set +e
for svc in ${ALL_SERVICES}; do
  systemctl --user stop    \${svc}.service 2>/dev/null || true
  systemctl --user disable \${svc}.service 2>/dev/null || true
  rm -f \"\${HOME}/.config/systemd/user/\${svc}.service\"
done
systemctl --user daemon-reload 2>/dev/null || true
"
    success "Services cleaned"
    did=1
  fi

  if $PLG_CLEAN_CONTAINERS; then
    header "Clean: containers"
    _deploy_log "Action: clean containers"
    run_remote_heredoc "Remove containers" "
set +e
pkill -f uvicorn 2>/dev/null || true
pkill -f 'python3.*app.py' 2>/dev/null || true
sleep 2
podman stop \$(podman ps -aq) 2>/dev/null || true
podman rm -f \$(podman ps -aq) 2>/dev/null || true
podman image prune -af 2>/dev/null || true
"
    success "Containers cleaned"
    did=1
  fi

  if $PLG_CLEAN_VOLUMES; then
    header "Clean: volumes"
    _deploy_log "Action: clean volumes"
    run_remote_heredoc "Remove volumes" "
set +e
podman volume rm \$(podman volume ls -q) 2>/dev/null || true
"
    success "Volumes cleaned"
    did=1
  fi

  if $PLG_CLEAN_DIRS; then
    header "Clean: directories"
    _deploy_log "Action: clean directories"
    run_remote_heredoc "Remove app directory and backups" "
set +e
rm -rf ${PLG_APP_DIR}
rm -rf \${HOME}/\$(basename ${PLG_APP_DIR})__staging
find \${HOME} -maxdepth 1 -name '\$(basename ${PLG_APP_DIR})__backup_*' -type d -exec rm -rf {} + 2>/dev/null || true
find \${HOME} -maxdepth 3 -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null || true
"
    success "Directories cleaned"
    did=1
  fi

  if $PLG_CLEAN_VENV; then
    header "Clean: venv"
    _deploy_log "Action: clean venv"
    run_remote_heredoc "Remove Python venv" "
set +e
rm -rf ${PLG_APP_DIR}/venv
rm -rf \${HOME}/.cache/pip
"
    success "Venv cleaned"
    did=1
  fi

  [[ "$did" -eq 1 ]] && success "Selective clean complete"
}

do_update() {
  header "Update: pull latest code"
  _deploy_log "Action: update code from ${PLG_GIT_BRANCH}"
  run_remote_heredoc "Git pull into app dir" "
APP_DIR=${PLG_APP_DIR}
BRANCH=${PLG_GIT_BRANCH}
REPO=${PLG_GIT_REPO}
STAGING=\"\${APP_DIR}__staging\"
BACKUP=\"\${APP_DIR}__backup_\$(date +%Y%m%d_%H%M%S)\"
DEPLOY_LOG=\"\${APP_DIR}/observer/logs/deployments.jsonl\"
mkdir -p \"\${APP_DIR}/observer/logs\"
TS=\$(date -u +%Y-%m-%dT%H:%M:%SZ)

log_deploy() {
  local status=\"\$1\" msg=\"\$2\"
  echo \"{\\\"ts\\\":\\\"\${TS}\\\",\\\"event\\\":\\\"deploy\\\",\\\"branch\\\":\\\"\${BRANCH}\\\",\\\"status\\\":\\\"\${status}\\\",\\\"msg\\\":\\\"\${msg}\\\"}\" >> \"\${DEPLOY_LOG}\" 2>/dev/null || true
}

rm -rf \"\${STAGING}\"
git clone --depth 1 --branch \"\${BRANCH}\" \"\${REPO}\" \"\${STAGING}\"

if command -v ${PLG_FRAPPE_PYTHON:-python3} &>/dev/null; then
  PYTHON_BIN=${PLG_FRAPPE_PYTHON:-python3}
else
  PYTHON_BIN=\$(command -v python3)
fi

SYNTAX_ERRORS=0
while IFS= read -r -d '' f; do
  \${PYTHON_BIN} -m py_compile \"\$f\" 2>/tmp/plg_syntax_err || { cat /tmp/plg_syntax_err; SYNTAX_ERRORS=\$((SYNTAX_ERRORS+1)); }
done < <(find \"\${STAGING}\" -name '*.py' -not -path '*/venv/*' -not -path '*/.git/*' -print0)
if [[ \$SYNTAX_ERRORS -gt 0 ]]; then
  log_deploy 'failed' \"syntax errors: \${SYNTAX_ERRORS} files\"
  rm -rf \"\${STAGING}\"
  echo \"ABORT: \${SYNTAX_ERRORS} syntax error(s) — old code still running\"
  exit 1
fi

if [[ -d \"\${APP_DIR}\" ]]; then
  mkdir -p \"\${BACKUP}\"
  rsync -a --exclude='venv/' --exclude='.git/' \"\${APP_DIR}/\" \"\${BACKUP}/\"
  cp -a \"\${APP_DIR}/.env\"      \"\${STAGING}/.env\"      2>/dev/null || true
  cp -a \"\${APP_DIR}/data\"      \"\${STAGING}/data\"      2>/dev/null || true
  cp -rp \"\${APP_DIR}/observer\" \"\${STAGING}/observer\"  2>/dev/null || true
  cp -rp \"\${APP_DIR}/deployer\" \"\${STAGING}/deployer\"  2>/dev/null || true
  cp -rp \"\${APP_DIR}/stats\"    \"\${STAGING}/stats\"     2>/dev/null || true
  rm -rf \"\${APP_DIR}\"
fi

mv \"\${STAGING}\" \"\${APP_DIR}\"

log_deploy 'success' \"HEAD: \$(git -C \"\${APP_DIR}\" log --oneline -1)\"

find \"\${APP_DIR%/*}\" -maxdepth 1 -name \"\$(basename \${APP_DIR})__backup_*\" -type d \
  | sort | head -n -3 | xargs rm -rf 2>/dev/null || true

echo \"HEAD: \$(git -C \"\${APP_DIR}\" log --oneline -1)\"
"

  header "Update: restart app services"
  run_remote_heredoc "Restart app services" "
set +e
for svc in ${APP_SERVICES}; do
  systemctl --user restart \${svc}.service 2>/dev/null || true
done
sleep 4
echo ''
for svc in ${APP_SERVICES}; do
  state=\$(systemctl --user is-active \${svc}.service 2>/dev/null || echo unknown)
  printf '  %-36s %s\n' \"\${svc}.service\" \"\$state\"
done
"
  success "Update complete"
  _deploy_log "Update complete"
}

do_update_config() {
  header "Update config: re-write .env"
  _deploy_log "Action: update config"

  local env_content
  env_content="$(_build_env_content)"

  run_remote_heredoc "Re-write .env" "
cat > ${PLG_APP_DIR}/.env << 'INNEREOF'
${env_content}
INNEREOF
sed -i 's/\r//' ${PLG_APP_DIR}/.env
echo \".env: \$(wc -l < ${PLG_APP_DIR}/.env) lines written\"
"

  run_remote_heredoc "Restart app services" "
set +e
for svc in ${APP_SERVICES}; do
  systemctl --user restart \${svc}.service 2>/dev/null || true
done
sleep 4
echo ''
for svc in ${APP_SERVICES}; do
  state=\$(systemctl --user is-active \${svc}.service 2>/dev/null || echo unknown)
  printf '  %-36s %s\n' \"\${svc}.service\" \"\$state\"
done
"
  success "Config updated and services restarted"
  _deploy_log "Config updated and services restarted"
}

if $PLG_STOP_ONLY;          then do_stop;           _deploy_log "=== Session end ==="; exit 0; fi
if $PLG_RESTART_ONLY;       then do_restart;        _deploy_log "=== Session end ==="; exit 0; fi
if $PLG_STATUS_ONLY;        then do_status;         _deploy_log "=== Session end ==="; exit 0; fi
if $PLG_UPDATE_ONLY;        then do_update;         _deploy_log "=== Session end ==="; exit 0; fi
if $PLG_UPDATE_CONFIG_ONLY; then do_update_config;  _deploy_log "=== Session end ==="; exit 0; fi

if $PLG_CLEAN_SERVICES || $PLG_CLEAN_CONTAINERS || $PLG_CLEAN_VOLUMES || $PLG_CLEAN_DIRS || $PLG_CLEAN_VENV; then
  do_selective_clean
  if $PLG_CLEAN_ONLY; then _deploy_log "=== Session end ==="; exit 0; fi
fi

if $PLG_CLEAN; then
  do_full_clean
  if $PLG_CLEAN_ONLY; then _deploy_log "=== Session end ==="; exit 0; fi
fi

if step_enabled 1; then
  header "Step 1 — System packages"
  _deploy_log "Step 1: system packages"
  run_remote "apt install" "bash --login -s" <<'ENDSSH'
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq

PYVER=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYVER_PKGS=""
for pkg in "python${PYVER}-venv" "python${PYVER}-dev"; do
  apt-cache show "$pkg" &>/dev/null && PYVER_PKGS="${PYVER_PKGS} ${pkg}"
done

sudo apt-get install -y -qq \
  git curl wget vim ufw \
  python3 python3-pip python3-venv python3-dev python3-full \
  libffi-dev libssl-dev build-essential \
  postgresql-client \
  podman podman-compose \
  pipx \
  ${PYVER_PKGS} \
  2>&1 | tail -3
ENDSSH
  success "System packages installed"
  _deploy_log "Step 1 complete"
fi

if step_enabled 2; then
  header "Step 2 — cgroup delegation"
  _deploy_log "Step 2: cgroup delegation"
  run_remote "delegate.conf" "bash -s" <<'ENDSSH'
sudo mkdir -p /etc/systemd/system/user@.service.d/
sudo tee /etc/systemd/system/user@.service.d/delegate.conf > /dev/null <<'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF
sudo systemctl daemon-reload
ENDSSH
  success "cgroup delegation configured"
  _deploy_log "Step 2 complete"
fi

if step_enabled 3; then
  header "Step 3 — Podman registry"
  _deploy_log "Step 3: podman registry"
  run_remote "docker.io registry" "bash -s" <<'ENDSSH'
sudo mkdir -p /etc/containers/registries.conf.d/
sudo tee /etc/containers/registries.conf.d/docker.conf > /dev/null <<'EOF'
[[registry]]
prefix = "docker.io"
location = "docker.io"
EOF
ENDSSH
  success "Podman registry configured"
  _deploy_log "Step 3 complete"
fi

if step_enabled 4; then
  header "Step 4 — Clone app repo"
  _deploy_log "Step 4: clone ${PLG_GIT_REPO}@${PLG_GIT_BRANCH}"
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
echo \"HEAD: \$(git log --oneline -1)\"
"
  run_remote_heredoc "Clone repo" "$CLONE_BODY"
  success "Repo cloned → ${PLG_GIT_BRANCH}"
  _deploy_log "Step 4 complete"
fi

if step_enabled 5; then
  header "Step 5 — Python venv"
  _deploy_log "Step 5: python venv"
  VENV_BODY="
cd ${PLG_APP_DIR}
if command -v ${PLG_FRAPPE_PYTHON:-python3} &>/dev/null; then
  PYTHON_BIN=${PLG_FRAPPE_PYTHON:-python3}
else
  PYTHON_BIN=\$(command -v python3)
fi
\${PYTHON_BIN} -m venv venv
source venv/bin/activate
pip install --upgrade pip --quiet
pip install -r requirements.txt --quiet
echo \"Python: \$(python --version)  Packages: \$(pip list | wc -l)\"
"
  run_remote_heredoc "venv + deps" "$VENV_BODY"
  success "Python environment ready"
  _deploy_log "Step 5 complete"
fi

if step_enabled 6; then
  header "Step 6 — Write .env"
  _deploy_log "Step 6: write .env"

  local_env_content="$(_build_env_content)"

  WRITE_ENV_BODY="
cat > ${PLG_APP_DIR}/.env << 'INNEREOF'
${local_env_content}
INNEREOF
sed -i 's/\r//' ${PLG_APP_DIR}/.env
echo \".env: \$(wc -l < ${PLG_APP_DIR}/.env) lines\"
"
  run_remote_heredoc "Write .env" "$WRITE_ENV_BODY"
  success ".env written"
  _deploy_log "Step 6 complete"
fi

if step_enabled 7; then
  header "Step 7 — Pull container images"
  _deploy_log "Step 7: pull images"
  if $PLG_PARALLEL_PULL; then
    PULL_BODY="
podman pull ${PLG_POSTGRES_IMAGE} --quiet &
podman pull ${PLG_RABBITMQ_IMAGE} --quiet &
podman pull docker.io/library/redis:7-alpine --quiet &
wait
echo 'Images pulled (parallel).'
"
  else
    PULL_BODY="
podman pull ${PLG_POSTGRES_IMAGE} --quiet
podman pull ${PLG_RABBITMQ_IMAGE} --quiet
podman pull docker.io/library/redis:7-alpine --quiet
echo 'Images pulled.'
"
  fi
  run_remote_heredoc "Pull images" "$PULL_BODY"
  success "Container images ready"
  _deploy_log "Step 7 complete"
fi

if step_enabled 8; then
  if [[ "${PLG_DOWNLOAD_CLIP_MODEL:-false}" == "true" ]] && ! $PLG_SKIP_MODEL; then
    header "Step 8 — Download CLIP model"
    _deploy_log "Step 8: download CLIP model"
    MODEL_BODY="
cd ${PLG_APP_DIR}
source venv/bin/activate
python scripts/download_clip_model.py --model ViT-L-14
"
    run_remote_heredoc "Download CLIP model" "$MODEL_BODY"
    success "CLIP model downloaded"
    _deploy_log "Step 8 complete"
  else
    info "Step 8 — Skipping CLIP model download"
    _deploy_log "Step 8: skipped"
  fi
fi

if step_enabled 9; then
  header "Step 9 — Redis containers"
  _deploy_log "Step 9: redis"
  REDIS_BODY="
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
podman ps --filter name=plg-redis
"
  run_remote_heredoc "Start Redis" "$REDIS_BODY"
  success "Redis containers running"
  _deploy_log "Step 9 complete"
fi

if step_enabled 10; then
  header "Step 10 — Postgres container"
  _deploy_log "Step 10: postgres"
  _PG_INIT_WAIT=20
  $PLG_NO_WAIT && _PG_INIT_WAIT=0
  POSTGRES_BODY="
mkdir -p \"\${HOME}/.config/systemd/user/\"

cat > \"\${HOME}/.config/systemd/user/plg-postgres.service\" << 'SVCEOF'
[Unit]
Description=PLG Postgres
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

echo 'Waiting ${_PG_INIT_WAIT}s for Postgres...'
sleep ${_PG_INIT_WAIT}

for i in 1 2 3 4 5 6; do
  podman exec ${PLG_POSTGRES_CONTAINER_NAME} pg_isready &>/dev/null && { echo 'Postgres ready.'; break; }
  echo \"Attempt \$i/6 — waiting 10s...\"
  sleep 10
  [[ \$i -eq 6 ]] && { echo 'ERROR: Postgres not ready'; exit 1; }
done
"
  run_remote_heredoc "Start Postgres" "$POSTGRES_BODY"
  success "Postgres ready"
  _deploy_log "Step 10 complete"
fi

if step_enabled 11; then
  if [[ "${PLG_SETUP_SYSTEMD:-false}" == "true" ]]; then
    header "Step 11 — Systemd service units"
    _deploy_log "Step 11: systemd units"

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

cat > \"\${HOME}/.config/systemd/user/plg-app.service\" << 'SVCEOF'
[Unit]
Description=PLG Plagiarism Worker
After=plg-postgres.service plg-rabbitmq.service
Requires=plg-postgres.service plg-rabbitmq.service

[Service]
Type=simple
WorkingDirectory=${PLG_APP_DIR}
EnvironmentFile=${PLG_APP_DIR}/.env
ExecStart=${PLG_VENV_DIR}/bin/python3 ${PLG_APP_DIR}/app.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SVCEOF

cat > \"\${HOME}/.config/systemd/user/plg-api.service\" << 'SVCEOF'
[Unit]
Description=PLG FastAPI
After=plg-postgres.service plg-rabbitmq.service
Requires=plg-postgres.service

[Service]
Type=simple
WorkingDirectory=${PLG_APP_DIR}/api
EnvironmentFile=${PLG_APP_DIR}/.env
ExecStart=${PLG_VENV_DIR}/bin/uvicorn api:app --host ${PLG_API_HOST} --port ${PLG_API_PORT}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SVCEOF
"
    run_remote_heredoc "Write service files" "$SYSTEMD_BODY"
    success "Systemd service files written"

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
systemctl --user enable --now plg-app.service
systemctl --user enable --now plg-api.service
sleep ${_SVC_SETTLE_WAIT}

echo '=== Containers ==='
podman ps

echo ''
echo '=== Service status ==='
for svc in plg-postgres plg-rabbitmq plg-redis-cache plg-redis-queue plg-app plg-api; do
  state=\$(systemctl --user is-active \${svc}.service 2>/dev/null || echo unknown)
  printf '  %-36s %s\n' \"\${svc}.service\" \"\$state\"
done
"
    run_remote_heredoc "Start all services" "$START_BODY"
    success "All services started"
    _deploy_log "Step 11 complete"
  else
    info "Step 11 — Skipping systemd setup (PLG_SETUP_SYSTEMD=false)"
    _deploy_log "Step 11: skipped"
  fi
fi

if step_enabled 12; then
  if [[ "${PLG_OPEN_FIREWALL_PORT:-false}" == "true" ]]; then
    header "Step 12 — Firewall"
    _deploy_log "Step 12: open port ${PLG_API_PORT}"
    FIREWALL_BODY="
set +e
if command -v ufw &>/dev/null; then
  sudo ufw allow ${PLG_API_PORT}/tcp 2>/dev/null || true
  echo 'ufw: opened ${PLG_API_PORT}'
else
  echo 'ufw not found — configure cloud NSG manually'
fi
"
    run_remote_heredoc "Open ports" "$FIREWALL_BODY"
    warn "Also open port ${PLG_API_PORT} in your cloud NSG."
    _deploy_log "Step 12 complete"
  else
    info "Step 12 — Skipping firewall (PLG_OPEN_FIREWALL_PORT=false)"
    _deploy_log "Step 12: skipped"
  fi
fi

if step_enabled 13; then
  header "Step 13 — Health check"
  _deploy_log "Step 13: health check"
  PLG_WAIT 3
  do_status
  _deploy_log "Step 13 complete"
fi

echo ""
success "Deployment complete"
_deploy_log "=== Deployment complete ==="
_appid_log  "=== Deployment complete ==="
echo ""