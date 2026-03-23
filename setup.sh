#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

gen_pass()  { openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32; }
gen_token() { openssl rand -hex 32; }

DASHBOARD_SERVER=""
DASHBOARD_PEM=""
DASHBOARD_PORT="4000"
DASHBOARD_USER=""

CLOUD_USERS="azureuser ubuntu debian admin ec2-user centos gcp-data core"

usage() {
  echo "Usage: $0 --server HOST --pem PATH [--port PORT] [--user USER]"
  echo "  --server    IP/hostname of dashboard server"
  echo "  --pem       Path to SSH .pem key"
  echo "  --port      Dashboard port (default: 4000)"
  echo "  --user      SSH username (auto-detected if omitted)"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --server) DASHBOARD_SERVER="$2"; shift 2;;
    --pem)    DASHBOARD_PEM="$2";    shift 2;;
    --port)   DASHBOARD_PORT="$2";   shift 2;;
    --user)   DASHBOARD_USER="$2";   shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

[ -z "$DASHBOARD_SERVER" ] && read -rp "Dashboard server IP/host: " DASHBOARD_SERVER
[ -z "$DASHBOARD_PEM"    ] && read -rp "SSH .pem path: "           DASHBOARD_PEM
[ -f "$DASHBOARD_PEM"    ] || { echo "Not found: $DASHBOARD_PEM"; exit 1; }
chmod 600 "$DASHBOARD_PEM"

PROBE_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o BatchMode=yes"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=20"

detect_user() {
  for u in $CLOUD_USERS; do
    ssh $PROBE_OPTS -i "$DASHBOARD_PEM" "${u}@${DASHBOARD_SERVER}" "echo ok" >/dev/null 2>&1 && echo "$u" && return 0
  done
  return 1
}

if [ -z "$DASHBOARD_USER" ]; then
  echo "Auto-detecting SSH user on $DASHBOARD_SERVER ..."
  DASHBOARD_USER=$(detect_user) || { echo "Cannot reach $DASHBOARD_SERVER with any known user"; exit 1; }
fi
echo "Using $DASHBOARD_USER@$DASHBOARD_SERVER"

dssh() {
  local tries=0
  until ssh $SSH_OPTS -i "$DASHBOARD_PEM" "${DASHBOARD_USER}@${DASHBOARD_SERVER}" "$@"; do
    tries=$((tries + 1))
    [ $tries -ge 5 ] && { echo "SSH failed after $tries attempts"; return 1; }
    echo "  retry ${tries}/5 in 15s..."
    sleep 15
  done
}

dscp() {
  local tries=0
  until scp -q $SSH_OPTS -i "$DASHBOARD_PEM" "$@"; do
    tries=$((tries + 1))
    [ $tries -ge 5 ] && { echo "SCP failed after $tries attempts"; return 1; }
    echo "  scp retry ${tries}/5 in 15s..."
    sleep 15
  done
}

DASHBOARD_TOKEN=$(gen_token)
DASHBOARD_SECRET=$(gen_pass)

echo ""
echo "=== Installing dashboard on $DASHBOARD_SERVER:$DASHBOARD_PORT ==="

dssh "sudo mkdir -p /opt/tap-dashboard/keys /opt/tap-dashboard/scripts /opt/tap-dashboard/logs && sudo chown -R ${DASHBOARD_USER}:${DASHBOARD_USER} /opt/tap-dashboard && chmod 700 /opt/tap-dashboard/keys"

PEM_BASENAME="$(basename "$DASHBOARD_PEM")"
dscp "$DASHBOARD_PEM" "${DASHBOARD_USER}@${DASHBOARD_SERVER}:/opt/tap-dashboard/keys/${PEM_BASENAME}"
dssh "chmod 600 /opt/tap-dashboard/keys/${PEM_BASENAME}"

dscp -r "$SCRIPT_DIR/dashboard/." "${DASHBOARD_USER}@${DASHBOARD_SERVER}:/opt/tap-dashboard/"

if [ -d "$SCRIPT_DIR/scripts" ]; then
  dscp "$SCRIPT_DIR/scripts/"*.sh "${DASHBOARD_USER}@${DASHBOARD_SERVER}:/opt/tap-dashboard/scripts/" 2>/dev/null || true
fi

dssh "chmod +x /opt/tap-dashboard/scripts/*.sh 2>/dev/null || true"

cat > /tmp/dashboard.env << EOF
PORT=${DASHBOARD_PORT}
AUTH_TOKEN=${DASHBOARD_TOKEN}
SECRET=${DASHBOARD_SECRET}
DASHBOARD_HOST=${DASHBOARD_SERVER}
DASHBOARD_SSH_USER=${DASHBOARD_USER}
DASHBOARD_PEM=/opt/tap-dashboard/keys/${PEM_BASENAME}
DB_PATH=/opt/tap-dashboard/deploy.db
LOG_RETENTION_DAYS=7
SCRIPTS_DIR=/opt/tap-dashboard/scripts
GITHUB_TOKEN=
EOF

dscp /tmp/dashboard.env "${DASHBOARD_USER}@${DASHBOARD_SERVER}:/opt/tap-dashboard/.env"
rm -f /tmp/dashboard.env

cat > /tmp/tap-dashboard.service << EOF
[Unit]
Description=TAP Dashboard
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/tap-dashboard
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
EnvironmentFile=/opt/tap-dashboard/.env
User=${DASHBOARD_USER}

[Install]
WantedBy=multi-user.target
EOF

dscp /tmp/tap-dashboard.service "${DASHBOARD_USER}@${DASHBOARD_SERVER}:/tmp/tap-dashboard.service"
rm -f /tmp/tap-dashboard.service

dssh "bash -s" << 'ENDSSH'
set -e
command -v node >/dev/null 2>&1 || {
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash - >/dev/null 2>&1
  sudo apt-get install -y nodejs >/dev/null 2>&1
}
cd /opt/tap-dashboard
npm install --omit=dev --silent
sudo cp /tmp/tap-dashboard.service /etc/systemd/system/tap-dashboard.service
sudo rm -f /tmp/tap-dashboard.service
sudo systemctl daemon-reload
sudo systemctl enable --now tap-dashboard
sleep 3
sudo systemctl is-active --quiet tap-dashboard && echo "  dashboard running" || { echo "  WARN: checking logs..."; sudo journalctl -u tap-dashboard -n 20 --no-pager; }
ENDSSH

cat > "$SCRIPT_DIR/dashboard-credentials.txt" << EOF
TAP Dashboard
  URL:    http://${DASHBOARD_SERVER}:${DASHBOARD_PORT}
  Token:  ${DASHBOARD_TOKEN}
EOF
chmod 600 "$SCRIPT_DIR/dashboard-credentials.txt"

echo ""
echo "========================================"
echo "  DASHBOARD SETUP COMPLETE"
echo "========================================"
echo "  URL:   http://${DASHBOARD_SERVER}:${DASHBOARD_PORT}"
echo "  Token: ${DASHBOARD_TOKEN}"
echo ""
echo "  Saved to: $SCRIPT_DIR/dashboard-credentials.txt"