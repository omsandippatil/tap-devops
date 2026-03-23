const { NodeSSH } = require('node-ssh');
const db = require('./db');

function getSSHConfig(appConfig) {
  const cfg = {
    host: appConfig.host,
    username: appConfig.ssh_user,
    readyTimeout: parseInt(appConfig.ssh_timeout || '20000', 10),
  };
  const keyPath = appConfig.ssh_key_path || process.env.DASHBOARD_PEM;
  if (keyPath) cfg.privateKeyPath = keyPath;
  return cfg;
}

async function exec(appId, command) {
  const app = db.getApp(appId);
  if (!app) throw new Error(`Unknown app: ${appId}`);
  const cfg = getSSHConfig(app.config);
  const ssh = new NodeSSH();
  try {
    await ssh.connect(cfg);
    const result = await ssh.execCommand(command, { execOptions: { pty: false } });
    return { stdout: result.stdout, stderr: result.stderr, code: result.code };
  } finally {
    ssh.dispose();
  }
}

async function testConnection(host, sshUser, pemPath, timeout = 10000) {
  const ssh = new NodeSSH();
  try {
    await ssh.connect({ host, username: sshUser, privateKeyPath: pemPath, readyTimeout: timeout });
    const r = await ssh.execCommand('echo ok && uname -a && uptime');
    ssh.dispose();
    return { ok: true, info: r.stdout.trim() };
  } catch (e) {
    try { ssh.dispose(); } catch {}
    return { ok: false, error: e.message };
  }
}

async function getMetrics(appId) {
  try {
    const cmd = [
      `cpu=$(top -bn1 | grep 'Cpu(s)' | awk '{print $2}' | tr -d '%us,' | head -1)`,
      `[ -z "$cpu" ] && cpu=$(top -bn1 | grep '%Cpu' | awk '{print $2}' | tr -d 'us,' | head -1)`,
      `mem=$(free | awk '/Mem:/{printf "%.1f",$3/$2*100}')`,
      `disk=$(df / --output=pcent | tail -1 | tr -d '% ')`,
      `up=$(uptime -p 2>/dev/null | sed 's/up //' || uptime | awk -F'up ' '{print $2}' | awk -F',' '{print $1}')`,
      'echo "{\\"cpu\\":${cpu:-0},\\"mem\\":${mem:-0},\\"disk\\":${disk:-0},\\"uptime\\":\\"${up:-unknown}\\"}"',
    ].join(';');
    const { stdout } = await exec(appId, cmd);
    return JSON.parse(stdout.trim());
  } catch {
    return { cpu: null, mem: null, disk: null, uptime: null };
  }
}

async function getDockerStatus(appId) {
  try {
    const { stdout } = await exec(appId,
      `docker ps --format '{"name":"{{.Names}}","status":"{{.Status}}","image":"{{.Image}}","ports":"{{.Ports}}"}' 2>/dev/null | head -20`
    );
    return stdout.trim().split('\n').filter(Boolean).map(l => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  } catch {
    return [];
  }
}

async function getLogs(appId, lines = 200) {
  const app = db.getApp(appId);
  if (!app) throw new Error(`Unknown app: ${appId}`);
  const cfg = app.config;
  const logCmd = buildLogCommand(cfg, lines);
  try {
    const { stdout, stderr } = await exec(appId, logCmd);
    return stdout || stderr || '(no output)';
  } catch (e) {
    return `Error: ${e.message}`;
  }
}

function buildLogCommand(cfg, lines) {
  if (cfg.log_paths) {
    const paths = cfg.log_paths.split(',').map(p => p.trim()).filter(Boolean);
    return `tail -n ${lines} ${paths.map(p => `'${p}'`).join(' ')} 2>/dev/null`;
  }
  if (cfg.log_command) {
    return cfg.log_command.replace('{{lines}}', lines);
  }
  if (cfg.type === 'frappe' && cfg.bench_dir) {
    return `tail -n ${lines} ${cfg.bench_dir}/logs/web.log ${cfg.bench_dir}/logs/schedule.log 2>/dev/null`;
  }
  if (cfg.type === 'docker' && cfg.docker_compose_dir) {
    return `cd ${cfg.docker_compose_dir} && docker compose logs --tail=${lines} 2>/dev/null`;
  }
  if (cfg.systemd_service) {
    return `journalctl -u ${cfg.systemd_service} -n ${lines} --no-pager 2>/dev/null`;
  }
  return `journalctl -n ${lines} --no-pager 2>/dev/null`;
}

async function checkHealth(appId) {
  const app = db.getApp(appId);
  if (!app) throw new Error(`Unknown app: ${appId}`);
  const cfg = app.config;

  if (cfg.health_command) {
    try {
      const { code } = await exec(appId, cfg.health_command);
      return { healthy: code === 0, code };
    } catch {
      return { healthy: false, code: 0 };
    }
  }

  if (cfg.type === 'docker' && !cfg.health_port) {
    try {
      const { stdout } = await exec(appId,
        `docker ps --filter "status=running" --format '{{.Names}}' | wc -l`
      );
      const count = parseInt(stdout.trim(), 10);
      return { healthy: count > 0, code: count };
    } catch {
      return { healthy: false, code: 0 };
    }
  }

  const port = cfg.health_port || '8000';
  const hpath = cfg.health_path || '/';
  try {
    const { stdout } = await exec(appId,
      `curl -sf -o /dev/null -w "%{http_code}" --connect-timeout 8 http://127.0.0.1:${port}${hpath} 2>/dev/null || echo 000`
    );
    const code = parseInt(stdout.trim(), 10);
    return { healthy: code >= 200 && code < 500, code };
  } catch {
    return { healthy: false, code: 0 };
  }
}

async function getVersion(appId) {
  const app = db.getApp(appId);
  if (!app) throw new Error(`Unknown app: ${appId}`);
  const cfg = app.config;
  const cmd = cfg.version_command || buildVersionCommand(cfg);
  try {
    const { stdout } = await exec(appId, cmd);
    return stdout.trim().slice(0, 40) || 'unknown';
  } catch {
    return 'unknown';
  }
}

function buildVersionCommand(cfg) {
  if (cfg.app_dir) return `git -C ${cfg.app_dir} rev-parse --short HEAD 2>/dev/null || echo unknown`;
  if (cfg.bench_dir) return `git -C ${cfg.bench_dir}/apps/${cfg.app_name || ''} rev-parse --short HEAD 2>/dev/null || echo unknown`;
  if (cfg.docker_compose_dir) return `cd ${cfg.docker_compose_dir} && git rev-parse --short HEAD 2>/dev/null || echo unknown`;
  return 'echo unknown';
}

module.exports = { exec, testConnection, getMetrics, getLogs, checkHealth, getVersion, getSSHConfig, getDockerStatus };