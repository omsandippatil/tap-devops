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
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"          # <── repo root, one level up from setup/
CONFIG_FILE="${REPO_ROOT}/config.env"

DASHBOARD_HOST=""
DASHBOARD_USER="azureuser"
DASHBOARD_SSH_PORT=22
PEM_FILE=""
DASHBOARD_PORT=9000
DASHBOARD_DIR="/home/azureuser/tap-dashboard"
DRY_RUN=false
FORCE=false
UPDATE_ONLY=false
RESTART_ONLY=false
NODE_VERSION=20

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Reads DASHBOARD_HOST and DASHBOARD_PEM_FILE from config.env by default.

Options:
  --host HOST          Remote server IP or hostname (overrides config.env)
  --pem  PATH          Path to .pem private key file (overrides config.env)
  --user USER          SSH username (default: azureuser)
  --port PORT          SSH port (default: 22)
  --dashboard-port N   Dashboard HTTP port (default: 9000)
  --dir  PATH          Remote install directory (default: /home/azureuser/tap-dashboard)
  --config FILE        Path to config.env (default: <repo-root>/config.env)
  --node-version N     Node.js version to install (default: 20)
  --update             Pull latest code and restart (no full reinstall)
  --restart            Restart dashboard service only
  --dry-run            Print SSH commands, do not execute
  --force              Skip confirmation prompts
  --help               Show this help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)           [[ $# -ge 2 ]] || die "--host requires a value";           DASHBOARD_HOST="$2";     shift 2 ;;
    --pem)            [[ $# -ge 2 ]] || die "--pem requires a value";            PEM_FILE="$2";           shift 2 ;;
    --user)           [[ $# -ge 2 ]] || die "--user requires a value";           DASHBOARD_USER="$2";     shift 2 ;;
    --port)           [[ $# -ge 2 ]] || die "--port requires a value";           DASHBOARD_SSH_PORT="$2"; shift 2 ;;
    --dashboard-port) [[ $# -ge 2 ]] || die "--dashboard-port requires a value"; DASHBOARD_PORT="$2";     shift 2 ;;
    --dir)            [[ $# -ge 2 ]] || die "--dir requires a value";            DASHBOARD_DIR="$2";      shift 2 ;;
    --config)         [[ $# -ge 2 ]] || die "--config requires a value";         CONFIG_FILE="$2";        shift 2 ;;
    --node-version)   [[ $# -ge 2 ]] || die "--node-version requires a value";   NODE_VERSION="$2";       shift 2 ;;
    --update)         UPDATE_ONLY=true;  shift ;;
    --restart)        RESTART_ONLY=true; shift ;;
    --dry-run)        DRY_RUN=true;      shift ;;
    --force)          FORCE=true;        shift ;;
    --help)           usage ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# ── Load config.env ──────────────────────────────────────────────────────────
if [[ -f "$CONFIG_FILE" ]]; then
  set -a; source "$CONFIG_FILE"; set +a
  info "Loaded config: $CONFIG_FILE"
else
  warn "Config file not found: $CONFIG_FILE"
fi

# CLI flags take precedence; fall back to config.env vars, then defaults
[[ -n "${DASHBOARD_HOST:-}" ]]     || DASHBOARD_HOST="${DASHBOARD_SERVER_HOST:-}"
[[ -n "${PEM_FILE:-}" ]]           || PEM_FILE="${DASHBOARD_PEM_FILE:-}"
[[ -n "${DASHBOARD_USER:-}" ]]     || DASHBOARD_USER="${DASHBOARD_SERVER_USER:-azureuser}"
[[ -n "${DASHBOARD_SSH_PORT:-}" ]] || DASHBOARD_SSH_PORT="${DASHBOARD_SSH_PORT:-22}"
[[ -n "${DASHBOARD_PORT:-}" ]]     || DASHBOARD_PORT="${DASHBOARD_PORT:-9000}"
[[ -n "${NODE_VERSION:-}" ]]       || NODE_VERSION=20

[[ -n "$DASHBOARD_HOST" ]] || die "DASHBOARD_HOST not set — add DASHBOARD_SERVER_HOST to config.env or pass --host"
[[ -n "$PEM_FILE" ]]       || die "PEM_FILE not set — add DASHBOARD_PEM_FILE to config.env or pass --pem"
[[ -f "$PEM_FILE" ]]       || die "PEM file not found: $PEM_FILE"

chmod 600 "$PEM_FILE"

SSH_OPTS="-i ${PEM_FILE} -p ${DASHBOARD_SSH_PORT} -o StrictHostKeyChecking=no -o ConnectTimeout=15"
SCP_OPTS="-i ${PEM_FILE} -P ${DASHBOARD_SSH_PORT} -o StrictHostKeyChecking=no"
TARGET="${DASHBOARD_USER}@${DASHBOARD_HOST}"

# ── Locate dashboard source files ────────────────────────────────────────────
# Canonical location: <repo-root>/dashboard/   (e.g. tap-devops/dashboard/)
# Fallback 1: dashboard/ subdirectory next to this script (setup/dashboard/)
# Fallback 2: script's own directory (legacy / flat-layout)
if   [[ -d "${REPO_ROOT}/dashboard" ]];  then FILES_DIR="${REPO_ROOT}/dashboard"
elif [[ -d "${SCRIPT_DIR}/dashboard" ]]; then FILES_DIR="${SCRIPT_DIR}/dashboard"
else                                          FILES_DIR="${SCRIPT_DIR}"
fi
info "Dashboard source: ${FILES_DIR}"

# ── Helpers ──────────────────────────────────────────────────────────────────
remote() {
  local desc="$1"; shift
  info "Remote: $desc"
  if $DRY_RUN; then echo -e "  ${YELLOW}$ $*${RESET}"; return 0; fi
  ssh $SSH_OPTS "$TARGET" "$@" 2>&1
}

remote_heredoc() {
  local desc="$1"
  local body="$2"
  info "Remote script: $desc"
  if $DRY_RUN; then echo -e "  ${YELLOW}[heredoc: $desc]${RESET}"; return 0; fi
  ssh $SSH_OPTS "$TARGET" "bash -s" <<EOF
set -euo pipefail
${body}
EOF
}

upload() {
  local src="$1"
  local dst="$2"
  info "Upload: $src → ${TARGET}:${dst}"
  if $DRY_RUN; then echo -e "  ${YELLOW}scp ${src} ${TARGET}:${dst}${RESET}"; return 0; fi
  scp $SCP_OPTS "$src" "${TARGET}:${dst}"
}

confirm() {
  $FORCE && return 0
  echo -e "${YELLOW}$1${RESET}"
  read -rp "Continue? [y/N] " ans
  [[ "${ans,,}" == "y" ]] || { info "Aborted."; exit 0; }
}

# ── Pre-flight ────────────────────────────────────────────────────────────────
header "Pre-flight"
info "Target  : ${TARGET}"
info "Dir     : ${DASHBOARD_DIR}"
info "Port    : ${DASHBOARD_PORT}"
info "Config  : ${CONFIG_FILE}"
info "Sources : ${FILES_DIR}"

if ! $DRY_RUN; then
  ssh $SSH_OPTS "$TARGET" "echo 'SSH_OK'" > /dev/null \
    || die "Cannot connect to ${TARGET}. Check host, pem, user, port."
fi
success "SSH connection verified"

# ── --restart ─────────────────────────────────────────────────────────────────
if $RESTART_ONLY; then
  header "Restart dashboard service"
  remote_heredoc "restart" "
systemctl --user restart tap-dashboard.service 2>/dev/null || true
sleep 2
state=\$(systemctl --user is-active tap-dashboard.service 2>/dev/null || echo unknown)
echo \"tap-dashboard: \${state}\"
"
  success "Dashboard restarted"
  exit 0
fi

# ── --update ──────────────────────────────────────────────────────────────────
if $UPDATE_ONLY; then
  header "Update: upload files and restart"
  for f in server.js db.js ssh.js github.js package.json; do
    src="${FILES_DIR}/${f}"
    [[ -f "$src" ]] && upload "$src" "${DASHBOARD_DIR}/${f}" \
                    || warn "Not found, skipping: $f"
  done
  if [[ -f "${FILES_DIR}/public/index.html" ]]; then
    upload "${FILES_DIR}/public/index.html" "${DASHBOARD_DIR}/public/index.html"
  fi
  upload "$CONFIG_FILE" "${DASHBOARD_DIR}/.env"
  remote_heredoc "npm install and restart" "
cd ${DASHBOARD_DIR}
export NVM_DIR=\"\${HOME}/.nvm\"
source \"\${NVM_DIR}/nvm.sh\"
npm install --omit=dev --quiet
systemctl --user restart tap-dashboard.service 2>/dev/null || true
sleep 2
state=\$(systemctl --user is-active tap-dashboard.service 2>/dev/null || echo unknown)
echo \"tap-dashboard: \${state}\"
"
  success "Dashboard updated"
  remote_heredoc "health check" "
sleep 2
curl -sf http://localhost:${DASHBOARD_PORT}/api/auth/status | grep -q 'authenticated' \
  && echo 'Dashboard HTTP: OK' \
  || echo 'Dashboard HTTP: not yet responding'
"
  echo ""
  echo -e "  Dashboard   ${CYAN}http://${DASHBOARD_HOST}:${DASHBOARD_PORT}${RESET}"
  echo ""
  exit 0
fi

# ── Full install ──────────────────────────────────────────────────────────────
confirm "This will install Node.js ${NODE_VERSION}, npm dependencies, and set up the TAP dashboard on ${TARGET}."

header "Step 1 — System packages"
remote_heredoc "apt packages" "
export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq curl git build-essential python3 python3-dev make g++ 2>&1 | tail -5
echo 'System packages done.'
"
success "System packages ready"

header "Step 2 — Node.js ${NODE_VERSION} via nvm"
remote_heredoc "nvm + node" "
if [[ ! -d \"\${HOME}/.nvm\" ]]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
fi
export NVM_DIR=\"\${HOME}/.nvm\"
source \"\${NVM_DIR}/nvm.sh\"
nvm install ${NODE_VERSION}
nvm alias default ${NODE_VERSION}
nvm use default
echo \"Node: \$(node --version)\"
echo \"npm:  \$(npm --version)\"
grep -q 'nvm.sh' \"\${HOME}/.bashrc\" || cat >> \"\${HOME}/.bashrc\" << 'BASHRC'
export NVM_DIR=\"\$HOME/.nvm\"
[ -s \"\$NVM_DIR/nvm.sh\" ] && source \"\$NVM_DIR/nvm.sh\"
export PATH=\"\$HOME/.local/bin:\$PATH\"
BASHRC
"
success "Node.js ${NODE_VERSION} ready"

header "Step 3 — Create dashboard directory"
remote_heredoc "mkdir" "
mkdir -p ${DASHBOARD_DIR}/{data/keys,public}
echo 'Directory structure created.'
"
success "Dashboard directory ready"

header "Step 4 — Upload dashboard files"
UPLOADED_ANY=false
for f in server.js db.js ssh.js github.js package.json; do
  src="${FILES_DIR}/${f}"
  if [[ -f "$src" ]]; then
    upload "$src" "${DASHBOARD_DIR}/${f}"
    UPLOADED_ANY=true
  else
    warn "File not found, skipping: $f (looked in ${FILES_DIR})"
  fi
done

if [[ -f "${FILES_DIR}/public/index.html" ]]; then
  upload "${FILES_DIR}/public/index.html" "${DASHBOARD_DIR}/public/index.html"
fi

upload "$CONFIG_FILE" "${DASHBOARD_DIR}/.env"
success "Config uploaded as .env"

header "Step 5 — npm install"
if $UPLOADED_ANY; then
  remote_heredoc "npm install" "
export NVM_DIR=\"\${HOME}/.nvm\"
source \"\${NVM_DIR}/nvm.sh\"
cd ${DASHBOARD_DIR}
npm install --omit=dev 2>&1 | tail -10
echo 'npm install done.'
"
  success "Dependencies installed"
else
  die "No JS source files found in '${FILES_DIR}'. Expected server.js, db.js, ssh.js, github.js, package.json."
fi

header "Step 6 — Systemd user service"
remote_heredoc "write service file" "
export NVM_DIR=\"\${HOME}/.nvm\"
source \"\${NVM_DIR}/nvm.sh\"
NODE_BIN=\"\$(which node)\"

mkdir -p \"\${HOME}/.config/systemd/user/\"

cat > \"\${HOME}/.config/systemd/user/tap-dashboard.service\" << SVCEOF
[Unit]
Description=TAP DevOps Dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${DASHBOARD_DIR}
EnvironmentFile=${DASHBOARD_DIR}/.env
Environment=NODE_ENV=production
ExecStart=\${NODE_BIN} server.js
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
SVCEOF

loginctl enable-linger ${DASHBOARD_USER} 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable --now tap-dashboard.service
sleep 3
state=\$(systemctl --user is-active tap-dashboard.service 2>/dev/null || echo unknown)
echo \"tap-dashboard: \${state}\"
"
success "Systemd service installed and started"

header "Step 7 — Firewall"
remote_heredoc "open port" "
if command -v ufw &>/dev/null; then
  sudo ufw allow ${DASHBOARD_PORT}/tcp 2>/dev/null || true
  echo 'ufw: opened ${DASHBOARD_PORT}'
else
  echo 'ufw not found — open port ${DASHBOARD_PORT} in your cloud NSG manually'
fi
"

header "Step 8 — Health check"
sleep 4
remote_heredoc "health check" "
for i in 1 2 3 4 5; do
  if curl -sf http://localhost:${DASHBOARD_PORT}/api/auth/status | grep -q 'authenticated'; then
    echo 'Dashboard HTTP: OK'
    break
  fi
  echo \"Attempt \$i/5 — waiting 3s...\"
  sleep 3
  [[ \$i -eq 5 ]] && echo 'Dashboard not yet responding — check: journalctl --user -u tap-dashboard.service -n 30'
done
"

echo ""
echo -e "${BOLD}${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo -e "${BOLD}${GREEN}  Dashboard deployed!${RESET}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
echo ""
echo -e "  URL       ${CYAN}http://${DASHBOARD_HOST}:${DASHBOARD_PORT}${RESET}"
echo -e "  Install   ${CYAN}${DASHBOARD_DIR}${RESET}"
echo ""
echo -e "  ${YELLOW}Useful commands:${RESET}"
echo -e "    ssh $SSH_OPTS ${TARGET} 'journalctl --user -u tap-dashboard.service -f'"
echo -e "    ssh $SSH_OPTS ${TARGET} 'systemctl --user restart tap-dashboard.service'"
echo ""
echo -e "  ${YELLOW}Quick ops:${RESET}"
echo -e "    $0 --restart"
echo -e "    $0 --update"
echo ""
warn "Open port ${DASHBOARD_PORT} in your cloud NSG / security group if not done already."
echo ""