// ssh.js — SSH command execution via ssh2
const { Client } = require('ssh2');
const fs = require('fs');

/**
 * Run a single command over SSH and collect output.
 * Returns { stdout, stderr, code }
 */
function runSSH({ host, port = 22, username, privateKeyPath }, command) {
  return new Promise((resolve, reject) => {
    const conn = new Client();
    let stdout = '';
    let stderr = '';

    conn.on('ready', () => {
      conn.exec(command, (err, stream) => {
        if (err) { conn.end(); return reject(err); }
        stream
          .on('close', (code) => { conn.end(); resolve({ stdout, stderr, code }); })
          .on('data', (d) => { stdout += d.toString(); })
          .stderr.on('data', (d) => { stderr += d.toString(); });
      });
    })
    .on('error', reject)
    .connect({
      host,
      port,
      username,
      privateKey: fs.readFileSync(privateKeyPath),
      readyTimeout: 15000,
    });
  });
}

/**
 * Stream a command over SSH, calling onData(chunk) as output arrives.
 * Returns a promise that resolves with { code } when done.
 */
function streamSSH({ host, port = 22, username, privateKeyPath }, command, onData) {
  return new Promise((resolve, reject) => {
    const conn = new Client();

    conn.on('ready', () => {
      conn.exec(command, { pty: false }, (err, stream) => {
        if (err) { conn.end(); return reject(err); }
        stream
          .on('close', (code) => { conn.end(); resolve({ code }); })
          .on('data', (d) => { onData(d.toString()); })
          .stderr.on('data', (d) => { onData(d.toString()); });
      });
    })
    .on('error', reject)
    .connect({
      host,
      port,
      username,
      privateKey: fs.readFileSync(privateKeyPath),
      readyTimeout: 15000,
    });
  });
}

/**
 * Build the remote status payload: services + containers + reachability
 */
async function fetchAppStatus(appCfg) {
  const { server_host, ssh_port, server_user, ssh_key_path } = appCfg;
  if (!server_host || !ssh_key_path) return { error: 'not_configured' };

  const env = JSON.parse(appCfg.env_json || '{}');
  const prefix = appCfg.app_id.toUpperCase();

  const services = [
    'plg_app', 'plg_api', 'plg-frappe-web',
    'plg-frappe-worker', 'plg-frappe-schedule',
    'plg-postgres', 'plg-rabbitmq',
    'plg-redis-cache', 'plg-redis-queue',
    'plg-observer', 'plg-deployer',
  ];

  const statusCmd = `
set -euo pipefail
echo "=CONTAINERS="
podman ps --format '{{.Names}}|{{.Status}}|{{.Ports}}' 2>/dev/null || echo ""
echo "=SERVICES="
for svc in ${services.join(' ')}; do
  state=$(systemctl --user is-active ${svc}.service 2>/dev/null || echo unknown)
  echo "${svc}|${state}"
done
echo "=DISK="
df -h / | tail -1 | awk '{print $3"|"$4"|"$5}'
echo "=MEM="
free -m | awk 'NR==2{printf "%d|%d", $3, $2}'
echo "=LOAD="
cat /proc/loadavg | awk '{print $1"|"$2"|"$3}'
`;

  try {
    const { stdout } = await runSSH(
      { host: server_host, port: ssh_port || 22, username: server_user, privateKeyPath: ssh_key_path },
      `bash -s <<'EOFSTATUS'\n${statusCmd}\nEOFSTATUS`
    );

    const lines = stdout.split('\n');
    let section = '';
    const containers = [];
    const svcs = {};
    let disk = {}, mem = {}, load = {};

    for (const line of lines) {
      if (line.startsWith('=') && line.endsWith('=')) {
        section = line.replace(/=/g, '').trim();
        continue;
      }
      if (!line.trim()) continue;

      if (section === 'CONTAINERS') {
        const [name, status, ports] = line.split('|');
        if (name) containers.push({ name, status, ports: ports || '' });
      } else if (section === 'SERVICES') {
        const [name, state] = line.split('|');
        if (name) svcs[name] = state;
      } else if (section === 'DISK') {
        const [used, free, pct] = line.split('|');
        disk = { used, free, pct };
      } else if (section === 'MEM') {
        const [used, total] = line.split('|');
        mem = { used_mb: parseInt(used), total_mb: parseInt(total) };
      } else if (section === 'LOAD') {
        const [l1, l5, l15] = line.split('|');
        load = { l1, l5, l15 };
      }
    }

    const activeCount = Object.values(svcs).filter(s => s === 'active').length;
    const totalCount = Object.keys(svcs).length;
    const overallStatus = activeCount === 0 ? 'down' : activeCount < totalCount ? 'degraded' : 'healthy';

    return {
      ok: true,
      ts: new Date().toISOString(),
      overall: overallStatus,
      active_services: activeCount,
      total_services: totalCount,
      containers,
      services: svcs,
      disk,
      mem,
      load,
    };
  } catch (err) {
    return { ok: false, error: err.message, ts: new Date().toISOString(), overall: 'unreachable' };
  }
}

/**
 * Run deploy script on remote via SSH (streaming output).
 * onChunk called with each output chunk.
 */
async function runDeploy(appCfg, flags, onChunk) {
  const { server_host, ssh_port, server_user, ssh_key_path, setup_script, env_json } = appCfg;

  // Write env file to temp remote path and source it, then run the script
  const env = JSON.parse(env_json || '{}');
  const envLines = Object.entries(env).map(([k, v]) => `export ${k}="${String(v).replace(/"/g, '\\"')}"`).join('\n');

  // Build flag string
  const flagStr = Array.isArray(flags) ? flags.join(' ') : (flags || '');

  const remoteScript = `
${envLines}
export PLG_SERVER_USER="${appCfg.server_user}"
export PLG_SERVER_HOST="${server_host}"
export PLG_SSH_KEY_PATH="~/.ssh/id_rsa"
export PLG_SSH_PORT="${ssh_port || 22}"

# Run setup script (it lives on the remote)
SCRIPT_PATH="${setup_script}"
if [[ -f "\${SCRIPT_PATH}" ]]; then
  bash "\${SCRIPT_PATH}" ${flagStr}
else
  echo "ERROR: Setup script not found at \${SCRIPT_PATH}"
  echo "Available scripts:"
  ls ~/tap-devops/setup/ 2>/dev/null || echo "(none)"
  exit 1
fi
`;

  return streamSSH(
    { host: server_host, port: ssh_port || 22, username: server_user, privateKeyPath: ssh_key_path },
    `bash -s`,
    onChunk
  );
}

module.exports = { runSSH, streamSSH, fetchAppStatus, runDeploy };