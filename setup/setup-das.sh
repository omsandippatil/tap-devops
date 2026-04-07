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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${REPO_ROOT}/config.env"
DASHBOARD_FILES="${REPO_ROOT}/dashboard"
SETUP_FILES="${REPO_ROOT}/setup"
INSTALL_DIR="/home/azureuser/tap-devops"
SERVICE_NAME="tap-dashboard"

DASHBOARD_HOST=""
DASHBOARD_USER="azureuser"
DASHBOARD_SSH_PORT=22
PEM_FILE=""
DASHBOARD_PORT=9000
NODE_VERSION=20

DRY_RUN=false
FORCE=false
UPDATE_ONLY=false
RESTART_ONLY=false
CLEAN_ONLY=false
CLEAN=false
UPLOAD_ONLY=false

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --host HOST          Remote server IP or hostname
  --pem  PATH          Path to .pem private key file
  --user USER          SSH username (default: azureuser)
  --port PORT          SSH port (default: 22)
  --dashboard-port N   Dashboard HTTP port (default: 9000)
  --config FILE        Path to config.env (default: <repo-root>/config.env)
  --node-version N     Node.js version (default: 20)
  --upload             Upload scripts only and replace on server
  --update             Upload files and restart
  --restart            Restart service only
  --clean              Wipe then reinstall
  --clean-only         Stop service and delete all files, no reinstall
  --dry-run            Print commands, do not execute
  --force              Skip confirmation prompts
  --help               Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)           DASHBOARD_HOST="$2";     shift 2 ;;
    --pem)            PEM_FILE="$2";           shift 2 ;;
    --user)           DASHBOARD_USER="$2";     shift 2 ;;
    --port)           DASHBOARD_SSH_PORT="$2"; shift 2 ;;
    --dashboard-port) DASHBOARD_PORT="$2";     shift 2 ;;
    --config)         CONFIG_FILE="$2";        shift 2 ;;
    --node-version)   NODE_VERSION="$2";       shift 2 ;;
    --upload)         UPLOAD_ONLY=true;        shift ;;
    --update)         UPDATE_ONLY=true;        shift ;;
    --restart)        RESTART_ONLY=true;       shift ;;
    --clean)          CLEAN=true;              shift ;;
    --clean-only)     CLEAN_ONLY=true;         shift ;;
    --dry-run)        DRY_RUN=true;            shift ;;
    --force)          FORCE=true;              shift ;;
    --help)           usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [[ -f "$CONFIG_FILE" ]]; then
  set -a; source "$CONFIG_FILE"; set +a
  success "Loaded config: $CONFIG_FILE"
else
  warn "Config file not found: $CONFIG_FILE"
fi

[[ -n "${DASHBOARD_HOST:-}" ]] || DASHBOARD_HOST="${DASHBOARD_SERVER_HOST:-}"
[[ -n "${PEM_FILE:-}" ]]       || PEM_FILE="${DASHBOARD_PEM_FILE:-}"
[[ -n "${DASHBOARD_USER:-}" ]] || DASHBOARD_USER="${DASHBOARD_SERVER_USER:-azureuser}"

[[ -n "$DASHBOARD_HOST" ]] || die "DASHBOARD_HOST not set"
[[ -n "$PEM_FILE" ]]       || die "PEM_FILE not set"
[[ -f "$PEM_FILE" ]]       || die "PEM file not found: $PEM_FILE"
[[ -d "$DASHBOARD_FILES" ]] || die "Dashboard source not found: ${DASHBOARD_FILES}"
[[ -d "$SETUP_FILES" ]]    || die "Setup scripts dir not found: ${SETUP_FILES}"

chmod 600 "$PEM_FILE"

SSH_OPTS="-i ${PEM_FILE} -p ${DASHBOARD_SSH_PORT} -o StrictHostKeyChecking=no -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=10"
SCP_OPTS="-i ${PEM_FILE} -P ${DASHBOARD_SSH_PORT} -o StrictHostKeyChecking=no -o ConnectTimeout=20 -o ServerAliveInterval=30 -o ServerAliveCountMax=10"
TARGET="${DASHBOARD_USER}@${DASHBOARD_HOST}"

ssh_with_retry() {
  local max=5 delay=8 attempt=1
  while true; do
    if ssh $SSH_OPTS "$TARGET" "$@" 2>&1; then
      return 0
    fi
    local rc=$?
    [[ $attempt -ge $max ]] && { error "SSH failed after $max attempts"; return $rc; }
    warn "SSH attempt $attempt/$max failed — retrying in ${delay}s..."
    attempt=$(( attempt + 1 ))
    sleep $delay
    delay=$(( delay + 4 ))
  done
}

remote() {
  local desc="$1" body="$2"
  info "Remote: $desc"
  $DRY_RUN && { echo -e "  ${YELLOW}[dry-run]${RESET} $desc"; return 0; }
  ssh_with_retry bash -s -- <<EOF
set -euo pipefail
${body}
EOF
}

remote_soft() {
  local desc="$1" body="$2"
  info "Remote: $desc"
  $DRY_RUN && { echo -e "  ${YELLOW}[dry-run]${RESET} $desc"; return 0; }
  ssh_with_retry bash -s -- <<EOF
set +e
${body}
EOF
}

upload() {
  local src="$1" dst="$2"
  info "Upload: $(basename "$src") → ${dst}"
  $DRY_RUN && { echo -e "  ${YELLOW}[dry-run: scp $(basename "$src")]${RESET}"; return 0; }
  local max=4 delay=6 attempt=1
  while true; do
    if scp $SCP_OPTS "$src" "${TARGET}:${dst}" 2>&1; then
      return 0
    fi
    local rc=$?
    [[ $attempt -ge $max ]] && { error "scp failed after $max attempts: $src"; return $rc; }
    warn "scp attempt $attempt/$max failed — retrying in ${delay}s..."
    attempt=$(( attempt + 1 ))
    sleep $delay
    delay=$(( delay + 4 ))
  done
}

confirm() {
  $FORCE && return 0
  echo -e "${YELLOW}$1${RESET}"
  read -rp "Continue? [y/N] " ans
  [[ "${ans,,}" == "y" ]] || { info "Aborted."; exit 0; }
}

wait_for_ssh() {
  info "Waiting for SSH on ${DASHBOARD_HOST}:${DASHBOARD_SSH_PORT}..."
  local max=18 delay=10 attempt=1
  while true; do
    ssh $SSH_OPTS "$TARGET" "echo SSH_OK" >/dev/null 2>&1 && { success "SSH ready"; return 0; }
    [[ $attempt -ge $max ]] && die "SSH unavailable after $(( max * delay ))s"
    warn "Attempt $attempt/$max — retrying in ${delay}s..."
    attempt=$(( attempt + 1 ))
    sleep $delay
  done
}

detect_remote_os() {
  info "Detecting remote OS..."
  REMOTE_OS=$(ssh_with_retry bash -s -- <<'DETECT'
set +e
if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  echo "${ID}:${VERSION_ID}:${ID_LIKE:-}"
elif [[ -f /etc/redhat-release ]]; then
  echo "rhel:unknown:"
elif [[ "$(uname)" == "Darwin" ]]; then
  echo "darwin:$(sw_vers -productVersion):"
else
  echo "unknown:unknown:"
fi
DETECT
  )
  OS_ID="${REMOTE_OS%%:*}"
  OS_REST="${REMOTE_OS#*:}"
  OS_VER="${OS_REST%%:*}"
  OS_LIKE="${OS_REST#*:}"
  success "Detected: ${OS_ID} ${OS_VER} (like: ${OS_LIKE:-none})"
}

install_system_deps() {
  detect_remote_os

  local pkg_cmd=""

  case "$OS_ID" in
    ubuntu|debian|linuxmint|pop)
      pkg_cmd="
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq curl git build-essential python3 python3-dev make g++ sqlite3 2>&1 | tail -5
"
      ;;
    fedora)
      pkg_cmd="
sudo dnf install -y curl git gcc gcc-c++ make python3 python3-devel sqlite 2>&1 | tail -5
"
      ;;
    rhel|centos|almalinux|rocky)
      pkg_cmd="
sudo yum install -y epel-release 2>/dev/null || true
sudo yum install -y curl git gcc gcc-c++ make python3 python3-devel sqlite 2>&1 | tail -5
"
      ;;
    arch|manjaro)
      pkg_cmd="
sudo pacman -Sy --noconfirm curl git base-devel python sqlite 2>&1 | tail -5
"
      ;;
    opensuse*|sles)
      pkg_cmd="
sudo zypper install -y curl git gcc gcc-c++ make python3 python3-devel sqlite3 2>&1 | tail -5
"
      ;;
    alpine)
      pkg_cmd="
sudo apk add --no-cache curl git build-base python3 py3-pip sqlite 2>&1 | tail -5
"
      ;;
    darwin)
      pkg_cmd="
if ! command -v brew &>/dev/null; then
  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"
fi
brew install curl git python3 sqlite 2>&1 | tail -5
"
      ;;
    *)
      if echo "$OS_LIKE" | grep -qiE 'debian|ubuntu'; then
        pkg_cmd="
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq curl git build-essential python3 python3-dev make g++ sqlite3 2>&1 | tail -5
"
      elif echo "$OS_LIKE" | grep -qiE 'rhel|fedora|centos'; then
        pkg_cmd="
sudo yum install -y curl git gcc gcc-c++ make python3 python3-devel sqlite 2>&1 | tail -5
"
      else
        warn "Unknown OS '${OS_ID}' — skipping system packages. Install curl, git, build tools, python3, sqlite manually."
        return 0
      fi
      ;;
  esac

  remote "install system packages (${OS_ID})" "$pkg_cmd"
  success "System packages ready"
}

install_node_isolated() {
  remote "nvm + node ${NODE_VERSION} (isolated)" "
if [[ ! -d \"\${HOME}/.nvm\" ]]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
export NVM_DIR=\"\${HOME}/.nvm\"
source \"\${NVM_DIR}/nvm.sh\"
nvm install ${NODE_VERSION}
nvm alias default ${NODE_VERSION}
nvm use default
node --version
npm --version
grep -q 'nvm.sh' \"\${HOME}/.bashrc\" || {
  echo 'export NVM_DIR=\"\$HOME/.nvm\"'      >> \"\${HOME}/.bashrc\"
  echo '[ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"' >> \"\${HOME}/.bashrc\"
}
"
  success "Node.js ${NODE_VERSION} isolated via nvm"
}

upload_dashboard_files() {
  for f in server.js db.js ssh.js github.js package.json; do
    [[ -f "${DASHBOARD_FILES}/${f}" ]] \
      && upload "${DASHBOARD_FILES}/${f}" "${INSTALL_DIR}/${f}" \
      || warn "Not found: $f"
  done
  [[ -f "${DASHBOARD_FILES}/public/index.html" ]] \
    && upload "${DASHBOARD_FILES}/public/index.html" "${INSTALL_DIR}/public/index.html" \
    || warn "index.html not found"
  upload "$CONFIG_FILE" "${INSTALL_DIR}/config.env"
}

upload_setup_scripts() {
  local uploaded=0
  for f in "${SETUP_FILES}"/*.sh; do
    [[ -f "$f" ]] || continue
    fname="$(basename "$f")"
    [[ "$fname" == "setup-das.sh" ]] && { info "Skipping: $fname"; continue; }
    upload "$f" "${INSTALL_DIR}/setup/${fname}"
    uploaded=$(( uploaded + 1 ))
  done
  [[ $uploaded -gt 0 ]] && success "$uploaded setup script(s) uploaded" || warn "No setup scripts found"
  remote_soft "chmod setup scripts" "chmod +x '${INSTALL_DIR}/setup/'*.sh 2>/dev/null || true"
}

do_clean() {
  header "Clean — stop service and wipe ${INSTALL_DIR}"
  confirm "This will STOP ${SERVICE_NAME} and DELETE ${INSTALL_DIR} on ${TARGET}."
  $DRY_RUN && { echo -e "  ${YELLOW}[dry-run] would stop + wipe${RESET}"; return 0; }

  ssh_with_retry bash -s -- "${SERVICE_NAME}" "${INSTALL_DIR}" "${DASHBOARD_USER}" <<'REMOTE'
set +e
SVC="$1"; IDIR="$2"; DUSER="$3"
UNIT_FILE="${HOME}/.config/systemd/user/${SVC}.service"

systemctl --user stop "${SVC}.service" 2>/dev/null
sleep 2
state=$(systemctl --user is-active "${SVC}.service" 2>/dev/null || echo "inactive")
[[ "$state" != "inactive" && "$state" != "failed" ]] && pkill -f "node server.js" 2>/dev/null || true
systemctl --user disable "${SVC}.service" 2>/dev/null || true
rm -f "${UNIT_FILE}"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user reset-failed  2>/dev/null || true
[[ -d "${IDIR}" ]] && rm -rf "${IDIR}" && echo "Deleted: ${IDIR}" || echo "Already clean"
REMOTE

  success "Service stopped and directory removed."
}

header "Pre-flight"
info "Repo root : ${REPO_ROOT}"
info "Target    : ${TARGET}"
info "Install   : ${INSTALL_DIR}"
info "Port      : ${DASHBOARD_PORT}"

! $DRY_RUN && wait_for_ssh

if $UPLOAD_ONLY; then
  header "Upload — replace scripts on server"
  remote "ensure directories exist" "mkdir -p '${INSTALL_DIR}'/{data/keys,public,setup}"
  upload_setup_scripts
  upload_dashboard_files
  success "All files uploaded and replaced"
  exit 0
fi

if $RESTART_ONLY; then
  header "Restart"
  $DRY_RUN && { echo -e "  ${YELLOW}[dry-run] would restart ${SERVICE_NAME}${RESET}"; exit 0; }
  ssh_with_retry bash -s -- "${SERVICE_NAME}" <<'REMOTE'
set +e
SVC="$1"
systemctl --user restart "${SVC}.service"
sleep 2
echo "${SVC}: $(systemctl --user is-active "${SVC}.service" 2>/dev/null || echo unknown)"
REMOTE
  success "Dashboard restarted"
  exit 0
fi

if $CLEAN_ONLY; then
  do_clean
  exit 0
fi

if $UPDATE_ONLY; then
  header "Update — upload files and restart"
  upload_dashboard_files
  upload_setup_scripts
  $DRY_RUN && { echo -e "  ${YELLOW}[dry-run] would npm install + restart${RESET}"; exit 0; }
  ssh_with_retry bash -s -- "${INSTALL_DIR}" "${SERVICE_NAME}" <<'REMOTE'
set -euo pipefail
IDIR="$1"; SVC="$2"
export NVM_DIR="${HOME}/.nvm"
source "${NVM_DIR}/nvm.sh"
cd "${IDIR}"
npm install --omit=dev --quiet
systemctl --user restart "${SVC}.service"
sleep 2
echo "${SVC}: $(systemctl --user is-active "${SVC}.service" 2>/dev/null || echo unknown)"
REMOTE
  success "Dashboard updated"
  echo -e "\n  Dashboard  ${CYAN}http://${DASHBOARD_HOST}:${DASHBOARD_PORT}${RESET}"
  exit 0
fi

$CLEAN && do_clean

confirm "Install TAP DevOps Dashboard on ${TARGET} (Node ${NODE_VERSION})?"

header "Step 1 — Detect OS and install system packages"
install_system_deps

header "Step 2 — Node.js ${NODE_VERSION} (isolated via nvm)"
install_node_isolated

header "Step 3 — Create isolated directory structure"
remote "mkdir" "mkdir -p '${INSTALL_DIR}'/{data/keys,public,setup} && echo done"
success "Directories ready"

header "Step 4 — Upload dashboard files"
upload_dashboard_files
success "Dashboard files uploaded"

header "Step 5 — Upload setup scripts"
upload_setup_scripts

header "Step 6 — npm install (isolated)"
remote "npm install" "
export NVM_DIR=\"\${HOME}/.nvm\"
source \"\${NVM_DIR}/nvm.sh\"
cd '${INSTALL_DIR}'
npm install --omit=dev 2>&1 | tail -10
echo done
"
success "Dependencies installed"

header "Step 7 — Patch DB script paths"
remote_soft "fix db paths" "
DB='${INSTALL_DIR}/data/tap.db'
[[ ! -f \"\$DB\" ]] && { echo 'No DB yet — skipping'; exit 0; }
sqlite3 \"\$DB\" \"UPDATE apps SET setup_script = REPLACE(setup_script, '\$HOME/tap-devops/setup/', '${INSTALL_DIR}/setup/') WHERE setup_script LIKE '%tap-devops/setup/%';\"
sqlite3 \"\$DB\" \"UPDATE apps SET setup_script = REPLACE(setup_script, '/home/azureuser/tap-devops/setup/', '${INSTALL_DIR}/setup/') WHERE setup_script LIKE '%tap-devops/setup/%';\"
sqlite3 \"\$DB\" 'SELECT app_id, setup_script FROM apps;'
"
success "DB paths patched"

header "Step 8 — Systemd user service"
$DRY_RUN && { echo -e "  ${YELLOW}[dry-run] would write + enable ${SERVICE_NAME}.service${RESET}"; } || \
ssh_with_retry bash -s -- "${INSTALL_DIR}" "${SERVICE_NAME}" "${DASHBOARD_USER}" "${DASHBOARD_PORT}" <<'REMOTE'
set +e
IDIR="$1"; SVC="$2"; DUSER="$3"; PORT="$4"

export NVM_DIR="${HOME}/.nvm"
[ -s "${NVM_DIR}/nvm.sh" ] && source "${NVM_DIR}/nvm.sh"

NODE_BIN="$(command -v node 2>/dev/null || true)"
[[ -z "${NODE_BIN}" ]] && { echo "[ERROR] node not found"; exit 1; }
echo "[INFO] node: ${NODE_BIN}"

UNIT_DIR="${HOME}/.config/systemd/user"
mkdir -p "${UNIT_DIR}"

cat > "${UNIT_DIR}/${SVC}.service" <<UNIT
[Unit]
Description=TAP DevOps Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${IDIR}
EnvironmentFile=${IDIR}/config.env
Environment=NODE_ENV=production
ExecStart=${NODE_BIN} server.js
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
UNIT

loginctl enable-linger "${DUSER}" 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable --now "${SVC}.service"
sleep 3
echo "${SVC}: $(systemctl --user is-active "${SVC}.service" 2>/dev/null || echo unknown)"
REMOTE
success "Service installed and started"

header "Step 9 — Firewall"
remote_soft "open port ${DASHBOARD_PORT}" "
if command -v ufw &>/dev/null; then
  sudo ufw allow ${DASHBOARD_PORT}/tcp 2>/dev/null || true
  echo 'ufw: port ${DASHBOARD_PORT} opened'
elif command -v firewall-cmd &>/dev/null; then
  sudo firewall-cmd --permanent --add-port=${DASHBOARD_PORT}/tcp 2>/dev/null || true
  sudo firewall-cmd --reload 2>/dev/null || true
  echo 'firewalld: port ${DASHBOARD_PORT} opened'
else
  echo 'No firewall tool found — open port ${DASHBOARD_PORT} in cloud NSG manually'
fi
"

header "Step 10 — Health check"
sleep 4
remote_soft "health check" "
for i in 1 2 3 4 5; do
  if curl -sf http://localhost:${DASHBOARD_PORT}/api/auth/status 2>/dev/null | grep -q 'authenticated'; then
    echo 'HTTP: OK'; break
  fi
  echo \"Attempt \$i/5 — waiting 3s...\"
  sleep 3
  [[ \$i -eq 5 ]] && echo 'Not yet responding. Run: journalctl --user -u ${SERVICE_NAME}.service -n 30'
done
"

header "Step 11 — Verify"
remote_soft "verify" "
DB='${INSTALL_DIR}/data/tap.db'
[[ -f \"\$DB\" ]] && sqlite3 \"\$DB\" 'SELECT app_id, setup_script FROM apps;' || true
echo ''
echo 'Setup scripts:'
ls '${INSTALL_DIR}/setup/' 2>/dev/null || echo '(none)'
"

echo ""
echo -e "${BOLD}${GREEN}━━━  Dashboard deployed  ━━━${RESET}"
echo ""
echo -e "  URL      ${CYAN}http://${DASHBOARD_HOST}:${DASHBOARD_PORT}${RESET}"
echo -e "  Install  ${CYAN}${INSTALL_DIR}${RESET}"
echo -e "  Scripts  ${CYAN}${INSTALL_DIR}/setup/${RESET}"
echo ""
echo -e "  ${YELLOW}Logs:${RESET}    ssh $SSH_OPTS ${TARGET} 'journalctl --user -u ${SERVICE_NAME}.service -f'"
echo -e "  ${YELLOW}Restart:${RESET} $0 --restart"
echo -e "  ${YELLOW}Update:${RESET}  $0 --update"
echo -e "  ${YELLOW}Upload:${RESET}  $0 --upload"
echo -e "  ${YELLOW}Wipe:${RESET}    $0 --clean-only"
echo ""
warn "If port ${DASHBOARD_PORT} is blocked, open it in your cloud NSG."
echo ""