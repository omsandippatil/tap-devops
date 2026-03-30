const { Client } = require('ssh2');
const fs = require('fs');

function connCfg(a) {
  return {
    host: a.server_host || a.host,
    port: a.ssh_port || a.port || 22,
    username: a.server_user || a.username || 'ubuntu',
    privateKeyPath: a.ssh_key_path || a.privateKeyPath,
  };
}

function runSSH(cfg, command) {
  return new Promise((resolve, reject) => {
    const conn = new Client();
    let stdout = '';
    let stderr = '';
    let privateKey;
    try {
      privateKey = fs.readFileSync(cfg.privateKeyPath);
    } catch (e) {
      return reject(new Error(`Cannot read SSH key: ${cfg.privateKeyPath} — ${e.message}`));
    }
    conn.on('ready', () => {
      conn.exec(command, (err, stream) => {
        if (err) {
          conn.end();
          return reject(err);
        }
        stream.on('data', (d) => {
          stdout += d.toString();
        });
        stream.stderr.on('data', (d) => {
          stderr += d.toString();
        });
        stream.on('close', (code) => {
          conn.end();
          resolve({ stdout, stderr, code });
        });
      });
    });
    conn.on('error', (err) => reject(new Error(`SSH connect failed: ${err.message}`)));
    conn.connect({
      host: cfg.host,
      port: cfg.port || 22,
      username: cfg.username,
      privateKey,
      readyTimeout: 20000,
      keepaliveInterval: 10000,
    });
  });
}

function streamSSH(cfg, command, onData, stdinData, onConnected) {
  return new Promise((resolve, reject) => {
    const conn = new Client();
    let privateKey;
    try {
      privateKey = fs.readFileSync(cfg.privateKeyPath);
    } catch (e) {
      return reject(new Error(`Cannot read SSH key: ${cfg.privateKeyPath} — ${e.message}`));
    }
    conn.on('ready', () => {
      if (onConnected) onConnected(conn);
      conn.exec(command, { pty: false }, (err, stream) => {
        if (err) {
          conn.end();
          return reject(err);
        }
        stream.on('data', (chunk) => {
          if (onData) onData(chunk.toString());
        });
        stream.stderr.on('data', (chunk) => {
          if (onData) onData(chunk.toString());
        });
        stream.on('close', (code) => {
          conn.end();
          resolve({ code: code || 0 });
        });
        stream.on('error', (err) => {
          conn.end();
          reject(err);
        });
        if (stdinData) {
          stream.stdin.write(stdinData);
          stream.stdin.end();
        }
      });
    });
    conn.on('error', (err) =>
      reject(new Error(`SSH connect failed to ${cfg.host}:${cfg.port} — ${err.message}`))
    );
    conn.connect({
      host: cfg.host,
      port: cfg.port || 22,
      username: cfg.username,
      privateKey,
      readyTimeout: 30000,
      keepaliveInterval: 15000,
      keepaliveCountMax: 5,
    });
  });
}

function shellSSH(cfg, onData, onReady) {
  return new Promise((resolve, reject) => {
    const conn = new Client();
    let privateKey;
    try {
      privateKey = fs.readFileSync(cfg.privateKeyPath);
    } catch (e) {
      return reject(new Error(`Cannot read SSH key: ${cfg.privateKeyPath} — ${e.message}`));
    }
    conn.on('ready', () => {
      conn.shell({ term: 'xterm-256color', cols: 220, rows: 50 }, (err, stream) => {
        if (err) {
          conn.end();
          return reject(err);
        }
        if (onReady) onReady(conn, stream);
        stream.on('data', (chunk) => {
          if (onData) onData(chunk.toString('binary'));
        });
        stream.stderr.on('data', (chunk) => {
          if (onData) onData(chunk.toString('binary'));
        });
        stream.on('close', () => {
          conn.end();
          resolve();
        });
        stream.on('error', (err) => {
          conn.end();
          reject(err);
        });
      });
    });
    conn.on('error', (err) =>
      reject(new Error(`SSH connect failed to ${cfg.host}:${cfg.port} — ${err.message}`))
    );
    conn.connect({
      host: cfg.host,
      port: cfg.port || 22,
      username: cfg.username,
      privateKey,
      readyTimeout: 30000,
      keepaliveInterval: 15000,
      keepaliveCountMax: 5,
    });
  });
}

async function fetchAppStatus(a) {
  const cfg = connCfg(a);
  if (!cfg.host || !cfg.privateKeyPath) {
    return { ok: false, overall: 'not_configured', error: 'Server not configured' };
  }

  const script = `set +e
echo "=== LOAD ==="
cat /proc/loadavg 2>/dev/null || uptime
echo "=== MEM ==="
free -m 2>/dev/null || true
echo "=== DISK ==="
df -h / 2>/dev/null | tail -1
echo "=== SERVICES ==="
systemctl --user list-units --type=service --no-legend 2>/dev/null | awk '{print $1}' | while read svc; do
  state=$(systemctl --user is-active "$svc" 2>/dev/null)
  echo "\${svc%.service}=\${state}"
done
echo "=== CONTAINERS ==="
podman ps --format "{{.Names}}|{{.Status}}|{{.Ports}}" 2>/dev/null || docker ps --format "{{.Names}}|{{.Status}}|{{.Ports}}" 2>/dev/null || true
echo "=== END ==="`;

  let result;
  try {
    result = await runSSH(cfg, `bash -s <<'STATUSEOF'\n${script}\nSTATUSEOF`);
  } catch (e) {
    return { ok: false, overall: 'unreachable', error: e.message };
  }

  const out = result.stdout || '';
  const status = { ok: true, services: {}, containers: [] };

  const section = (name) => {
    const start = `=== ${name} ===`;
    const startIdx = out.indexOf(start);
    if (startIdx === -1) return '';
    const afterStart = out.indexOf('\n', startIdx) + 1;
    const nextSection = out.indexOf('=== ', afterStart);
    return nextSection === -1 ? out.slice(afterStart) : out.slice(afterStart, nextSection);
  };

  const loadRaw = section('LOAD').trim();
  if (loadRaw) {
    const parts = loadRaw.split(/\s+/);
    if (parts.length >= 3 && /^\d/.test(parts[0])) {
      status.load = { l1: parts[0], l5: parts[1], l15: parts[2] };
    } else {
      const upMatch = loadRaw.match(/load average[s]?:\s*([\d.]+),?\s*([\d.]+),?\s*([\d.]+)/i);
      if (upMatch) status.load = { l1: upMatch[1], l5: upMatch[2], l15: upMatch[3] };
    }
  }

  const memRaw = section('MEM');
  const memLine = memRaw.split('\n').find((l) => /^Mem:/i.test(l.trim()));
  if (memLine) {
    const mp = memLine.trim().split(/\s+/);
    status.mem = {
      total_mb: parseInt(mp[1]) || 0,
      used_mb: parseInt(mp[2]) || 0,
      free_mb: parseInt(mp[3]) || 0,
    };
  }

  const diskRaw = section('DISK').trim();
  if (diskRaw) {
    const dp = diskRaw.split(/\s+/);
    status.disk = {
      size: dp[1] || '—',
      used: dp[2] || '—',
      avail: dp[3] || '—',
      pct: dp[4] || '0%',
    };
  }

  const svcRaw = section('SERVICES');
  svcRaw
    .trim()
    .split('\n')
    .forEach((line) => {
      const m = line.match(/^(.+?)=(.+)$/);
      if (m) status.services[m[1].trim()] = m[2].trim();
    });

  const ctrIdx = out.indexOf('=== CONTAINERS ===');
  const endIdx = out.indexOf('=== END ===');
  if (ctrIdx !== -1) {
    const ctrRaw = out.slice(ctrIdx + 20, endIdx !== -1 ? endIdx : undefined).trim();
    status.containers = ctrRaw
      .split('\n')
      .filter((l) => l.trim())
      .map((l) => {
        const parts = l.split('|');
        return { name: parts[0] || '', status: parts[1] || '', ports: parts[2] || '' };
      });
  }

  const svcValues = Object.values(status.services);
  const active = svcValues.filter((v) => v === 'active').length;
  const total = svcValues.length;
  status.active_services = active;
  status.total_services = total;

  if (total === 0 && status.containers.length === 0) {
    status.overall = 'not_configured';
  } else if (active === total && total > 0) {
    status.overall = 'healthy';
  } else if (active === 0) {
    status.overall = 'down';
  } else {
    status.overall = 'degraded';
  }

  return status;
}

async function discoverApp(cfg, appId) {
  const paths = [
    `~/tap-devops/setup/setup-${appId}.sh`,
    `~/setup/setup-${appId}.sh`,
    `./setup-${appId}.sh`,
  ];
  for (const scriptPath of paths) {
    try {
      const { stdout } = await runSSH(
        cfg,
        `test -f ${scriptPath} && echo FOUND || echo NOTFOUND`
      );
      if (stdout.includes('FOUND')) {
        const { stdout: varOut } = await runSSH(
          cfg,
          `grep -oE '[A-Z][A-Z0-9_]{3,}' ${scriptPath} | grep -E '^[A-Z_]+_[A-Z_]+' | sort -u | head -60`
        );
        const vars = varOut
          .split('\n')
          .map((v) => v.trim())
          .filter((v) => v && v.length > 3);
        return { found: true, script_path: scriptPath, vars };
      }
    } catch {}
  }
  return { found: false, vars: [] };
}

module.exports = { runSSH, streamSSH, shellSSH, fetchAppStatus, discoverApp, connCfg };