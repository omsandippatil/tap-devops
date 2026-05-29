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
INSTALL_DIR="${HOME}/tap-devops"
SERVICE_NAME="tap-dashboard"

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
  --dashboard-port N   Dashboard HTTP port (default: 9000)
  --config FILE        Path to config.env (default: <repo-root>/config.env)
  --node-version N     Node.js version (default: 20)
  --upload             Copy scripts and replace in install dir
  --update             Copy files and restart service
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
    --dashboard-port) DASHBOARD_PORT="$2";  shift 2 ;;
    --config)         CONFIG_FILE="$2";     shift 2 ;;
    --node-version)   NODE_VERSION="$2";    shift 2 ;;
    --upload)         UPLOAD_ONLY=true;     shift ;;
    --update)         UPDATE_ONLY=true;     shift ;;
    --restart)        RESTART_ONLY=true;    shift ;;
    --clean)          CLEAN=true;           shift ;;
    --clean-only)     CLEAN_ONLY=true;      shift ;;
    --dry-run)        DRY_RUN=true;         shift ;;
    --force)          FORCE=true;           shift ;;
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

DASHBOARD_PORT="${DASHBOARD_PORT:-${DASHBOARD_PORT:-9000}}"

[[ -d "$DASHBOARD_FILES" ]] || die "Dashboard source not found: ${DASHBOARD_FILES}"
[[ -d "$SETUP_FILES" ]]    || die "Setup scripts dir not found: ${SETUP_FILES}"

run() {
  local desc="$1"; shift
  info "Run: $desc"
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${RESET} $desc"
    return 0
  fi
  "$@"
}

run_shell() {
  local desc="$1" body="$2"
  info "Step: $desc"
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${RESET} $desc"
    return 0
  fi
  bash -euo pipefail -c "$body"
}

run_shell_soft() {
  local desc="$1" body="$2"
  info "Step: $desc"
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run]${RESET} $desc"
    return 0
  fi
  bash +e -c "$body" || true
}

copy_file() {
  local src="$1" dst="$2"
  info "Copy: $(basename "$src") → ${dst}"
  if $DRY_RUN; then
    echo -e "  ${YELLOW}[dry-run: cp $(basename "$src")]${RESET}"
    return 0
  fi
  cp "$src" "$dst"
}

confirm() {
  $FORCE && return 0
  echo -e "${YELLOW}$1${RESET}"
  read -rp "Continue? [y/N] " ans
  [[ "${ans,,}" == "y" ]] || { info "Aborted."; exit 0; }
}

detect_os() {
  info "Detecting OS..."
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID}"
    OS_VER="${VERSION_ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  elif [[ "$(uname)" == "Darwin" ]]; then
    OS_ID="darwin"
    OS_VER="$(sw_vers -productVersion)"
    OS_LIKE=""
  else
    OS_ID="unknown"
    OS_VER="unknown"
    OS_LIKE=""
  fi
  success "Detected: ${OS_ID} ${OS_VER} (like: ${OS_LIKE:-none})"
}

install_system_deps() {
  detect_os

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

  run_shell "install system packages (${OS_ID})" "$pkg_cmd"
  success "System packages ready"
}

install_node_isolated() {
  run_shell "nvm + node ${NODE_VERSION} (isolated)" "
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

copy_dashboard_files() {
  mkdir -p "${INSTALL_DIR}/public"
  for f in server.js db.js ssh.js github.js package.json; do
    [[ -f "${DASHBOARD_FILES}/${f}" ]] \
      && copy_file "${DASHBOARD_FILES}/${f}" "${INSTALL_DIR}/${f}" \
      || warn "Not found: $f"
  done
  [[ -f "${DASHBOARD_FILES}/public/index.html" ]] \
    && copy_file "${DASHBOARD_FILES}/public/index.html" "${INSTALL_DIR}/public/index.html" \
    || warn "index.html not found"
  copy_file "$CONFIG_FILE" "${INSTALL_DIR}/config.env"
}

copy_setup_scripts() {
  mkdir -p "${INSTALL_DIR}/setup"
  local copied=0
  for f in "${SETUP_FILES}"/*.sh; do
    [[ -f "$f" ]] || continue
    fname="$(basename "$f")"
    [[ "$fname" == "setup-dashboard.sh" ]] && { info "Skipping: $fname"; continue; }
    copy_file "$f" "${INSTALL_DIR}/setup/${fname}"
    copied=$(( copied + 1 ))
  done
  [[ $copied -gt 0 ]] && success "$copied setup script(s) copied" || warn "No setup scripts found"
  run_shell_soft "chmod setup scripts" "chmod +x '${INSTALL_DIR}/setup/'*.sh 2>/dev/null || true"
}

do_clean() {
  header "Clean — stop service and wipe ${INSTALL_DIR}"
  confirm "This will STOP ${SERVICE_NAME} and DELETE ${INSTALL_DIR} on this machine."
  $DRY_RUN && { echo -e "  ${YELLOW}[dry-run] would stop + wipe${RESET}"; return 0; }

  set +e
  UNIT_FILE="${HOME}/.config/systemd/user/${SERVICE_NAME}.service"
  systemctl --user stop "${SERVICE_NAME}.service" 2>/dev/null
  sleep 2
  state=$(systemctl --user is-active "${SERVICE_NAME}.service" 2>/dev/null || echo "inactive")
  [[ "$state" != "inactive" && "$state" != "failed" ]] && pkill -f "node server.js" 2>/dev/null || true
  systemctl --user disable "${SERVICE_NAME}.service" 2>/dev/null || true
  rm -f "${UNIT_FILE}"
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user reset-failed  2>/dev/null || true
  [[ -d "${INSTALL_DIR}" ]] && rm -rf "${INSTALL_DIR}" && echo "Deleted: ${INSTALL_DIR}" || echo "Already clean"
  set -e

  success "Service stopped and directory removed."
}

header "Pre-flight"
info "Repo root : ${REPO_ROOT}"
info "Install   : ${INSTALL_DIR}"
info "Port      : ${DASHBOARD_PORT}"
info "User      : ${USER}"

if $UPLOAD_ONLY; then
  header "Upload — replace scripts in install dir"
  mkdir -p "${INSTALL_DIR}"/{data/keys,public,setup}
  copy_setup_scripts
  copy_dashboard_files
  success "All files copied and replaced"
  exit 0
fi

if $RESTART_ONLY; then
  header "Restart"
  $DRY_RUN && { echo -e "  ${YELLOW}[dry-run] would restart ${SERVICE_NAME}${RESET}"; exit 0; }
  set +e
  systemctl --user restart "${SERVICE_NAME}.service"
  sleep 2
  echo "${SERVICE_NAME}: $(systemctl --user is-active "${SERVICE_NAME}.service" 2>/dev/null || echo unknown)"
  set -e
  success "Dashboard restarted"
  exit 0
fi

if $CLEAN_ONLY; then
  do_clean
  exit 0
fi

if $UPDATE_ONLY; then
  header "Update — copy files and restart"
  copy_dashboard_files
  copy_setup_scripts
  $DRY_RUN && { echo -e "  ${YELLOW}[dry-run] would npm install + restart${RESET}"; exit 0; }
  export NVM_DIR="${HOME}/.nvm"
  source "${NVM_DIR}/nvm.sh"
  cd "${INSTALL_DIR}"
  npm install --omit=dev --quiet
  systemctl --user restart "${SERVICE_NAME}.service"
  sleep 2
  echo "${SERVICE_NAME}: $(systemctl --user is-active "${SERVICE_NAME}.service" 2>/dev/null || echo unknown)"
  success "Dashboard updated"
  echo -e "\n  Dashboard  ${CYAN}http://localhost:${DASHBOARD_PORT}${RESET}"
  exit 0
fi

$CLEAN && do_clean

confirm "Install TAP DevOps Dashboard on this machine (Node ${NODE_VERSION})?"

header "Step 1 — Detect OS and install system packages"
install_system_deps

header "Step 2 — Node.js ${NODE_VERSION} (isolated via nvm)"
install_node_isolated

header "Step 3 — Create isolated directory structure"
run_shell "mkdir" "mkdir -p '${INSTALL_DIR}'/{data/keys,public,setup} && echo done"
success "Directories ready"

header "Step 4 — Copy dashboard files"
copy_dashboard_files
success "Dashboard files copied"

header "Step 5 — Copy setup scripts"
copy_setup_scripts

header "Step 6 — npm install (isolated)"
run_shell "npm install" "
export NVM_DIR=\"\${HOME}/.nvm\"
source \"\${NVM_DIR}/nvm.sh\"
cd '${INSTALL_DIR}'
npm install --omit=dev 2>&1 | tail -10
echo done
"
success "Dependencies installed"

header "Step 7 — Patch DB script paths"
run_shell_soft "fix db paths" "
DB='${INSTALL_DIR}/data/tap.db'
[[ ! -f \"\$DB\" ]] && { echo 'No DB yet — skipping'; exit 0; }
sqlite3 \"\$DB\" \"UPDATE apps SET setup_script = REPLACE(setup_script, '\$HOME/tap-devops/setup/', '${INSTALL_DIR}/setup/') WHERE setup_script LIKE '%tap-devops/setup/%';\"
sqlite3 \"\$DB\" \"UPDATE apps SET setup_script = REPLACE(setup_script, '/home/ubuntu/tap-devops/setup/', '${INSTALL_DIR}/setup/') WHERE setup_script LIKE '%tap-devops/setup/%';\"
sqlite3 \"\$DB\" 'SELECT app_id, setup_script FROM apps;'
"
success "DB paths patched"

header "Step 8 — Systemd user service"
if $DRY_RUN; then
  echo -e "  ${YELLOW}[dry-run] would write + enable ${SERVICE_NAME}.service${RESET}"
else
  export NVM_DIR="${HOME}/.nvm"
  [ -s "${NVM_DIR}/nvm.sh" ] && source "${NVM_DIR}/nvm.sh"

  NODE_BIN="$(command -v node 2>/dev/null || true)"
  [[ -z "${NODE_BIN}" ]] && die "node not found after install"
  info "node: ${NODE_BIN}"

  UNIT_DIR="${HOME}/.config/systemd/user"
  mkdir -p "${UNIT_DIR}"

  cat > "${UNIT_DIR}/${SERVICE_NAME}.service" <<UNIT
[Unit]
Description=TAP DevOps Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/config.env
Environment=NODE_ENV=production
ExecStart=${NODE_BIN} server.js
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
UNIT

  loginctl enable-linger "${USER}" 2>/dev/null || true
  systemctl --user daemon-reload
  systemctl --user enable --now "${SERVICE_NAME}.service"
  sleep 3
  echo "${SERVICE_NAME}: $(systemctl --user is-active "${SERVICE_NAME}.service" 2>/dev/null || echo unknown)"
fi
success "Service installed and started"

header "Step 9 — Firewall (GCP)"
run_shell_soft "open port ${DASHBOARD_PORT}" "
if command -v ufw &>/dev/null; then
  sudo ufw allow ${DASHBOARD_PORT}/tcp 2>/dev/null || true
  echo 'ufw: port ${DASHBOARD_PORT} opened'
elif command -v firewall-cmd &>/dev/null; then
  sudo firewall-cmd --permanent --add-port=${DASHBOARD_PORT}/tcp 2>/dev/null || true
  sudo firewall-cmd --reload 2>/dev/null || true
  echo 'firewalld: port ${DASHBOARD_PORT} opened'
else
  echo 'No local firewall tool found — ensure GCP VPC firewall rule allows TCP ${DASHBOARD_PORT}'
fi
"

header "Step 10 — Health check"
sleep 4
run_shell_soft "health check" "
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
run_shell_soft "verify" "
DB='${INSTALL_DIR}/data/tap.db'
[[ -f \"\$DB\" ]] && sqlite3 \"\$DB\" 'SELECT app_id, setup_script FROM apps;' || true
echo ''
echo 'Setup scripts:'
ls '${INSTALL_DIR}/setup/' 2>/dev/null || echo '(none)'
"

EXTERNAL_IP=$(curl -sf --max-time 3 "http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/externalIp" -H "Metadata-Flavor: Google" 2>/dev/null || echo "EXTERNAL_IP_NOT_FOUND")

echo ""
echo -e "${BOLD}${GREEN}━━━  Dashboard deployed  ━━━${RESET}"
echo ""
echo -e "  Local URL    ${CYAN}http://localhost:${DASHBOARD_PORT}${RESET}"
echo -e "  External URL ${CYAN}http://${EXTERNAL_IP}:${DASHBOARD_PORT}${RESET}"
echo -e "  Install      ${CYAN}${INSTALL_DIR}${RESET}"
echo -e "  Scripts      ${CYAN}${INSTALL_DIR}/setup/${RESET}"
echo ""
echo -e "  ${YELLOW}Logs:${RESET}    journalctl --user -u ${SERVICE_NAME}.service -f"
echo -e "  ${YELLOW}Restart:${RESET} $0 --restart"
echo -e "  ${YELLOW}Update:${RESET}  $0 --update"
echo -e "  ${YELLOW}Upload:${RESET}  $0 --upload"
echo -e "  ${YELLOW}Wipe:${RESET}    $0 --clean-only"
echo ""
warn "If port ${DASHBOARD_PORT} is blocked, add a GCP VPC firewall rule: allow ingress TCP ${DASHBOARD_PORT}."
echo ""
