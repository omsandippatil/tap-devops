require('dotenv').config({ path: process.env.CONFIG_FILE || './config.env' });
const express = require('express');
const session = require('express-session');
const bcrypt = require('bcryptjs');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const net = require('net');
const http = require('http');
const { WebSocketServer } = require('ws');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const cron = require('node-cron');
const db = require('./db');
const { fetchAppStatus, runSSH, streamSSH, shellSSH, discoverApp, connCfg } = require('./ssh');
const { getBranchInfo, getAllBranches, getRecentCommits } = require('./github');

const CONFIG_ENV_PATH = process.env.CONFIG_FILE || path.join(__dirname, 'config.env');
const APP_ENVS_DIR = path.join(__dirname, 'data', 'envs');
const KEYS_DIR = path.join(__dirname, 'data', 'keys');
const PORT = process.env.DASHBOARD_PORT || 9000;
const SESSION_SECRET = process.env.SESSION_SECRET || 'tap-devops-' + Math.random().toString(36).slice(2);
const STATUS_POLL_INTERVAL = Math.max(30, parseInt(process.env.STATUS_POLL_INTERVAL_SECONDS || '60'));
const MAX_LOG_BYTES = 2000000;

fs.mkdirSync(KEYS_DIR, { recursive: true });
fs.mkdirSync(APP_ENVS_DIR, { recursive: true });

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ noServer: true });
const wsClients = new Set();
const activeConnections = new Map();

app.use(helmet({ contentSecurityPolicy: false }));
app.use(express.json({ limit: '10mb' }));
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, 'public')));
app.use(session({
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { secure: false, httpOnly: true, maxAge: 8 * 60 * 60 * 1000 },
}));

app.use('/api', rateLimit({ windowMs: 15 * 60 * 1000, max: 2000 }));
const authLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 30, message: { error: 'Too many attempts' } });

server.on('upgrade', (req, socket, head) => {
  const url = req.url || '';
  if (url === '/ws' || url.startsWith('/ws/')) {
    wss.handleUpgrade(req, socket, head, (ws) => wss.emit('connection', ws, req));
  } else {
    socket.destroy();
  }
});

wss.on('connection', (ws, req) => {
  const urlPath = req.url || '/ws';
  if (urlPath.startsWith('/ws/terminal/')) {
    handleTerminalConnection(ws, req);
    return;
  }
  ws.isAlive = true;
  wsClients.add(ws);
  ws.on('pong', () => { ws.isAlive = true; });
  ws.on('close', () => wsClients.delete(ws));
  ws.on('error', () => wsClients.delete(ws));
  ws.send(JSON.stringify({ type: 'connected', ts: Date.now() }));
});

setInterval(() => {
  wss.clients.forEach((ws) => {
    if (!ws.isAlive) { wsClients.delete(ws); return ws.terminate(); }
    ws.isAlive = false;
    ws.ping();
  });
}, 25000);

function broadcast(data) {
  const msg = JSON.stringify(data);
  wsClients.forEach((ws) => {
    try { if (ws.readyState === 1) ws.send(msg); } catch {}
  });
}

async function handleTerminalConnection(ws, req) {
  const appId = (req.url || '').split('/')[3] || '';
  if (!appId) { ws.close(1008, 'Missing app id'); return; }

  const effectiveApp = getEffectiveAppConfig(appId);
  if (!effectiveApp || !effectiveApp.server_host || !effectiveApp.ssh_key_path) {
    ws.send(JSON.stringify({ type: 'error', msg: 'Server not configured for this app' }));
    ws.close();
    return;
  }

  const cfg = connCfg(effectiveApp);
  let sshStream = null;
  let sshConn = null;

  ws.on('message', (msg) => {
    try {
      const data = JSON.parse(msg.toString());
      if (data.type === 'input' && sshStream) sshStream.write(data.data);
      else if (data.type === 'resize' && sshStream) sshStream.setWindow(data.rows || 24, data.cols || 80, 0, 0);
    } catch {}
  });

  ws.on('close', () => {
    if (sshStream) { try { sshStream.end(); } catch {} }
    if (sshConn) { try { sshConn.end(); } catch {} }
  });

  try {
    await shellSSH(
      cfg,
      (data) => { if (ws.readyState === 1) ws.send(JSON.stringify({ type: 'output', data })); },
      (conn, stream) => {
        sshConn = conn;
        sshStream = stream;
        ws.send(JSON.stringify({ type: 'connected', msg: `Connected to ${cfg.host}` }));
      }
    );
  } catch (e) {
    if (ws.readyState === 1) ws.send(JSON.stringify({ type: 'error', msg: e.message }));
    ws.close();
  }
}

function requireAuth(req, res, next) {
  if (req.session?.user) return next();
  res.status(401).json({ error: 'Unauthorized' });
}

function readConfigEnv() {
  try { return fs.readFileSync(CONFIG_ENV_PATH, 'utf8'); } catch { return ''; }
}

function writeConfigEnv(content) {
  fs.writeFileSync(CONFIG_ENV_PATH, content, 'utf8');
}

function parseEnvContent(content) {
  const result = {};
  for (const line of content.split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) continue;
    const idx = trimmed.indexOf('=');
    if (idx < 0) continue;
    const key = trimmed.slice(0, idx).trim();
    let val = trimmed.slice(idx + 1).trim();
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    }
    result[key] = val;
  }
  return result;
}

function updateEnvFileKey(filePath, key, value) {
  const lines = readRawFile(filePath).split('\n');
  let found = false;
  const updated = lines.map((line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) return line;
    const idx = trimmed.indexOf('=');
    if (idx < 0) return line;
    if (trimmed.slice(0, idx).trim() === key) { found = true; return `${key}=${value}`; }
    return line;
  });
  if (!found) updated.push(`${key}=${value}`);
  fs.writeFileSync(filePath, updated.join('\n'), 'utf8');
}

function updateEnvFileKeys(filePath, kvMap) {
  let content = readRawFile(filePath);
  const lines = content.split('\n');
  const remaining = new Set(Object.keys(kvMap));
  const updated = lines.map((line) => {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#')) return line;
    const idx = trimmed.indexOf('=');
    if (idx < 0) return line;
    const key = trimmed.slice(0, idx).trim();
    if (key in kvMap) { remaining.delete(key); return `${key}=${kvMap[key]}`; }
    return line;
  });
  for (const key of remaining) updated.push(`${key}=${kvMap[key]}`);
  fs.writeFileSync(filePath, updated.join('\n'), 'utf8');
}

function readRawFile(filePath) {
  try { return fs.readFileSync(filePath, 'utf8'); } catch { return ''; }
}

function getBaseId(appId) {
  return appId.replace(/\d+$/, '');
}

function getAppEnvPath(appId) {
  return path.join(APP_ENVS_DIR, `${appId}.env`);
}

function readAppEnv(appId) {
  return readRawFile(getAppEnvPath(appId));
}

function writeAppEnv(appId, content) {
  fs.writeFileSync(getAppEnvPath(appId), content, 'utf8');
}

function getAppEnvVars(appId) {
  const content = readAppEnv(appId);
  if (!content.trim()) return {};
  return parseEnvContent(content);
}

function initAppEnvFromConfig(appId) {
  const baseId = getBaseId(appId);
  const prefix = baseId.toUpperCase();
  const configVars = parseEnvContent(readConfigEnv());
  const appVars = {};

  for (const [k, v] of Object.entries(configVars)) {
    if (k.startsWith(prefix + '_')) appVars[k] = v;
  }

  const existingApp = db.getApp(appId);
  if (existingApp) {
    if (existingApp.server_host) appVars[`${prefix}_SERVER_HOST`] = existingApp.server_host;
    if (existingApp.ssh_key_path) appVars[`${prefix}_SSH_KEY_PATH`] = existingApp.ssh_key_path;
    if (existingApp.server_user) appVars[`${prefix}_SERVER_USER`] = existingApp.server_user;
    if (existingApp.ssh_port) appVars[`${prefix}_SSH_PORT`] = String(existingApp.ssh_port);
  }

  const lines = [`# ${appId.toUpperCase()} Environment`, `# Edit via Dashboard`, ``];
  for (const [k, v] of Object.entries(appVars)) lines.push(`${k}=${v}`);
  fs.writeFileSync(getAppEnvPath(appId), lines.join('\n'), 'utf8');
  return appVars;
}

function ensureAppEnvExists(appId) {
  const envPath = getAppEnvPath(appId);
  if (fs.existsSync(envPath) && readRawFile(envPath).trim()) return false;
  initAppEnvFromConfig(appId);
  return true;
}

function getEffectiveAppConfig(appId) {
  const a = db.getApp(appId);
  if (!a) return null;
  const baseId = getBaseId(appId);
  const prefix = baseId.toUpperCase();
  const appEnvVars = getAppEnvVars(appId);
  const configVars = parseEnvContent(readConfigEnv());
  return {
    ...a,
    server_host: a.server_host || appEnvVars[`${prefix}_SERVER_HOST`] || configVars[`${prefix}_SERVER_HOST`] || '',
    ssh_key_path: a.ssh_key_path || appEnvVars[`${prefix}_SSH_KEY_PATH`] || configVars[`${prefix}_SSH_KEY_PATH`] || configVars['DASHBOARD_PEM_FILE'] || '',
    server_user: a.server_user || appEnvVars[`${prefix}_SERVER_USER`] || configVars[`${prefix}_SERVER_USER`] || 'azureuser',
    ssh_port: a.ssh_port || parseInt(appEnvVars[`${prefix}_SSH_PORT`]) || parseInt(configVars[`${prefix}_SSH_PORT`]) || 22,
  };
}

function readDeployModeForApp(appId) {
  const baseId = getBaseId(appId);
  const prefix = baseId.toUpperCase();
  const envPath = getAppEnvPath(appId);
  const appVars = (fs.existsSync(envPath) && readRawFile(envPath).trim())
    ? parseEnvContent(readRawFile(envPath))
    : {};
  const configVars = parseEnvContent(readConfigEnv());
  const merged = { ...configVars, ...appVars };

  const deployDomain = (merged[`${prefix}_DEPLOY_DOMAIN`] || 'false').toLowerCase() === 'true';
  const domainName = merged[`${prefix}_DOMAIN_NAME`] || '';
  const apiPort = merged[`${prefix}_API_PORT`] || '8009';
  const nginxPort = merged[`${prefix}_NGINX_PORT`] || '80';
  const serverHost = merged[`${prefix}_SERVER_HOST`] || '';

  const effectiveUrl = deployDomain
    ? `http://${domainName || serverHost}/`
    : `http://${serverHost}:${apiPort}/`;

  return { deploy_domain: deployDomain, domain_name: domainName, api_port: apiPort, nginx_port: nginxPort, server_host: serverHost, effective_url: effectiveUrl };
}

function buildDeployFlags(appId, extraFlags) {
  const baseId = getBaseId(appId);
  const prefix = baseId.toUpperCase();
  const envPath = getAppEnvPath(appId);
  const appVars = (fs.existsSync(envPath) && readRawFile(envPath).trim())
    ? parseEnvContent(readRawFile(envPath))
    : {};
  const configVars = parseEnvContent(readConfigEnv());
  const merged = { ...configVars, ...appVars };

  const builtInFlags = [];
  if ((merged[`${prefix}_DEPLOY_DOMAIN`] || 'false').toLowerCase() === 'true') {
    builtInFlags.push('--deploy-to-domain');
  }

  const combined = [...builtInFlags];
  for (const f of extraFlags) {
    if (!combined.includes(f)) combined.push(f);
  }
  return combined;
}

function getMergedEnvVars(appId) {
  return { ...parseEnvContent(readConfigEnv()), ...getAppEnvVars(appId) };
}

function buildRemoteScript(appId, setupScript, allFlags) {
  const baseId = getBaseId(appId);
  const mergedVars = getMergedEnvVars(appId);
  const envExports = Object.entries(mergedVars)
    .map(([k, v]) => `export ${k}="${String(v).replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`)
    .join('\n');
  const flagStr = allFlags.join(' ');

  return [
    'set +e',
    'export NVM_DIR="${HOME}/.nvm"',
    '[[ -s "${NVM_DIR}/nvm.sh" ]] && source "${NVM_DIR}/nvm.sh"',
    'export PATH="${HOME}/.local/bin:${PATH}"',
    'hash -r 2>/dev/null || true',
    '',
    envExports,
    '',
    `SCRIPT="${setupScript}"`,
    `if [[ ! -f "$SCRIPT" ]]; then SCRIPT="\${HOME}/tap-devops/setup/setup-${baseId}.sh"; fi`,
    `if [[ ! -f "$SCRIPT" ]]; then echo "[ERROR] Setup script not found: $SCRIPT"; exit 1; fi`,
    '',
    `echo "[INFO] App:    ${appId}"`,
    `echo "[INFO] Script: $SCRIPT"`,
    `echo "[INFO] Flags:  ${flagStr || '(none)'}"`,
    `echo "[INFO] User:   $(whoami)"`,
    'echo ""',
    `bash "$SCRIPT" ${flagStr}`,
    'EXIT_CODE=$?',
    'echo ""',
    `echo "[INFO] Script exited with code $EXIT_CODE"`,
    'exit $EXIT_CODE',
  ].join('\n');
}

function buildAndRunDeploy(a, extraFlags, trigger) {
  const effectiveApp = getEffectiveAppConfig(a.app_id);
  if (!effectiveApp) return null;

  const { server_host: serverHost, ssh_key_path: sshKeyPath, server_user: serverUser, ssh_port: sshPort } = effectiveApp;
  if (!serverHost || !sshKeyPath) return null;

  const allFlags = buildDeployFlags(a.app_id, extraFlags);
  const setupScript = a.setup_script || `~/tap-devops/setup/setup-${getBaseId(a.app_id)}.sh`;
  const remoteScript = buildRemoteScript(a.app_id, setupScript, allFlags);
  const deployId = db.startDeployment(a.app_id, trigger, serverHost);
  const cfg = { host: serverHost, port: sshPort, username: serverUser, privateKeyPath: sshKeyPath };

  let log = '';

  const sendChunk = (chunk) => {
    if (!chunk) return;
    log += chunk;
    if (log.length > MAX_LOG_BYTES) log = log.slice(-MAX_LOG_BYTES);
    db.updateDeploymentLog(deployId, log);
    broadcast({ type: 'deploy_log', app_id: a.app_id, deploy_id: deployId, chunk });
  };

  broadcast({ type: 'deploy_start', app_id: a.app_id, deploy_id: deployId, server_host: serverHost, trigger });

  (async () => {
    try {
      const { code } = await streamSSH(cfg, 'bash --login -s', sendChunk, remoteScript, (conn) => activeConnections.set(deployId, conn));
      activeConnections.delete(deployId);
      const status = code === 0 ? 'success' : 'failed';
      db.finishDeployment(deployId, status, code);
      broadcast({ type: 'deploy_finish', app_id: a.app_id, deploy_id: deployId, status, code });
      fetchAppStatus(effectiveApp)
        .then((s) => { db.setStatus(a.app_id, s); broadcast({ type: 'status_update', app_id: a.app_id, status: s }); })
        .catch(() => {});
    } catch (err) {
      activeConnections.delete(deployId);
      sendChunk(`\n[ERROR] ${err.message}\n`);
      db.finishDeployment(deployId, 'failed', -1);
      broadcast({ type: 'deploy_finish', app_id: a.app_id, deploy_id: deployId, status: 'failed', error: err.message });
    }
  })();

  return deployId;
}

function getNextDeploymentId(baseId) {
  const siblings = db.getApps().filter((a) => getBaseId(a.app_id) === baseId && a.app_id !== baseId);
  if (!siblings.length) return `${baseId}1`;
  const nums = siblings.map((a) => {
    const n = parseInt(a.app_id.replace(baseId, ''));
    return isNaN(n) ? 0 : n;
  });
  return `${baseId}${Math.max(...nums) + 1}`;
}

function syncConfigEnvToAppEnvs(previousContent, newContent) {
  const prevVars = parseEnvContent(previousContent);
  const newVars = parseEnvContent(newContent);
  const changed = {};
  for (const [k, v] of Object.entries(newVars)) {
    if (prevVars[k] !== v) changed[k] = v;
  }
  if (!Object.keys(changed).length) return {};

  const syncResults = {};
  for (const a of db.getApps()) {
    const prefix = getBaseId(a.app_id).toUpperCase() + '_';
    const relevant = Object.fromEntries(Object.entries(changed).filter(([k]) => k.startsWith(prefix)));
    if (!Object.keys(relevant).length) continue;
    const envPath = getAppEnvPath(a.app_id);
    const existing = getAppEnvVars(a.app_id);
    const toWrite = Object.fromEntries(Object.entries(relevant).filter(([k]) => !(k in existing)));
    if (!Object.keys(toWrite).length) continue;
    updateEnvFileKeys(envPath, toWrite);
    syncResults[a.app_id] = Object.keys(toWrite);
    broadcast({ type: 'env_synced', app_id: a.app_id, keys: Object.keys(toWrite) });
  }
  return syncResults;
}

function probePort(host, port, timeoutMs = 3000) {
  return new Promise((resolve) => {
    const sock = new net.Socket();
    let done = false;
    const finish = (up) => {
      if (done) return;
      done = true;
      try { sock.destroy(); } catch {}
      resolve(up);
    };
    sock.setTimeout(timeoutMs);
    sock.on('connect', () => finish(true));
    sock.on('timeout', () => finish(false));
    sock.on('error', () => finish(false));
    sock.connect(port, host);
  });
}

app.get('/api/auth/status', (req, res) => {
  res.json({ authenticated: !!req.session?.user, user: req.session?.user?.username || null, needsSetup: db.userCount() === 0 });
});

app.post('/api/auth/setup', authLimiter, async (req, res) => {
  if (db.userCount() > 0) return res.status(403).json({ error: 'Already set up' });
  const { username, password } = req.body;
  if (!username || !password || password.length < 8) return res.status(400).json({ error: 'Username required, password min 8 chars' });
  db.createUser(username, await bcrypt.hash(password, 12));
  req.session.user = { username };
  res.json({ ok: true });
});

app.post('/api/auth/login', authLimiter, async (req, res) => {
  const { username, password } = req.body;
  const user = db.getUser(username);
  if (!user) return res.status(401).json({ error: 'Invalid credentials' });
  if (!await bcrypt.compare(password, user.password_hash)) return res.status(401).json({ error: 'Invalid credentials' });
  req.session.user = { username };
  res.json({ ok: true, username });
});

app.post('/api/auth/logout', (req, res) => {
  req.session.destroy(() => res.json({ ok: true }));
});

app.get('/api/config-env', requireAuth, (req, res) => {
  const content = readConfigEnv();
  res.json({ content, path: CONFIG_ENV_PATH, lines: content.split('\n').length, ok: true });
});

app.post('/api/config-env', requireAuth, (req, res) => {
  const { content } = req.body;
  if (typeof content !== 'string') return res.status(400).json({ error: 'content required' });
  try {
    const previous = readConfigEnv();
    writeConfigEnv(content);
    configEnvLastContent = content;
    const synced = syncConfigEnvToAppEnvs(previous, content);
    res.json({ ok: true, synced });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.post('/api/config-env/update-key', requireAuth, (req, res) => {
  const { key_path } = req.body;
  if (!key_path) return res.status(400).json({ error: 'key_path required' });
  try {
    updateEnvFileKey(CONFIG_ENV_PATH, 'DASHBOARD_PEM_FILE', key_path);
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/apps', requireAuth, (req, res) => {
  res.json(db.getApps().map((a) => ({
    ...a,
    env_json: JSON.parse(a.env_json || '{}'),
    flags_json: JSON.parse(a.flags_json || '{}'),
    status: db.getStatus(a.app_id),
    base_id: getBaseId(a.app_id),
    is_deployment: a.app_id !== getBaseId(a.app_id),
    env_file: getAppEnvPath(a.app_id),
  })));
});

app.get('/api/apps/:id', requireAuth, (req, res) => {
  const a = db.getApp(req.params.id);
  if (!a) return res.status(404).json({ error: 'Not found' });
  res.json({ ...a, env_json: JSON.parse(a.env_json || '{}'), flags_json: JSON.parse(a.flags_json || '{}'), base_id: getBaseId(a.app_id), is_deployment: a.app_id !== getBaseId(a.app_id), env_file: getAppEnvPath(a.app_id) });
});

app.post('/api/apps', requireAuth, (req, res) => {
  const { app_id, app_name, server_user, server_host, ssh_port, ssh_key_path, setup_script } = req.body;
  if (!app_id || !/^[a-z0-9_-]+$/.test(app_id)) return res.status(400).json({ error: 'app_id must be lowercase alphanumeric' });
  if (db.getApp(app_id)) return res.status(409).json({ error: `App "${app_id}" already exists` });

  const baseId = getBaseId(app_id);
  db.createApp({
    app_id,
    app_name: app_name || app_id.toUpperCase(),
    setup_script: setup_script || `~/tap-devops/setup/setup-${baseId}.sh`,
    server_user: server_user || 'azureuser',
    server_host: server_host || '',
    ssh_port: parseInt(ssh_port) || 22,
    ssh_key_path: ssh_key_path || '',
    env_json: '{}',
    flags_json: '{}',
  });

  const extractedVars = initAppEnvFromConfig(app_id);
  const prefix = baseId.toUpperCase();
  const envUpdates = {};
  if (server_host) envUpdates[`${prefix}_SERVER_HOST`] = server_host;
  if (ssh_key_path) envUpdates[`${prefix}_SSH_KEY_PATH`] = ssh_key_path;
  if (server_user) envUpdates[`${prefix}_SERVER_USER`] = server_user;
  if (ssh_port) envUpdates[`${prefix}_SSH_PORT`] = String(ssh_port);
  if (Object.keys(envUpdates).length) updateEnvFileKeys(getAppEnvPath(app_id), envUpdates);

  res.json({ ok: true, app_id, env_file: getAppEnvPath(app_id), extracted_vars: Object.keys(extractedVars).length });
});

app.post('/api/apps/:id/clone', requireAuth, (req, res) => {
  const baseApp = db.getApp(req.params.id);
  if (!baseApp) return res.status(404).json({ error: 'Base app not found' });
  const baseId = getBaseId(req.params.id);
  if (req.params.id !== baseId) return res.status(400).json({ error: 'Can only clone from base app' });

  const newId = getNextDeploymentId(baseId);
  const label = req.body.label || `Deployment ${newId.replace(baseId, '')}`;

  db.createApp({
    app_id: newId,
    app_name: `${baseApp.app_name} — ${label}`,
    setup_script: baseApp.setup_script,
    server_user: baseApp.server_user,
    server_host: baseApp.server_host,
    ssh_port: baseApp.ssh_port,
    ssh_key_path: baseApp.ssh_key_path,
    env_json: baseApp.env_json,
    flags_json: baseApp.flags_json,
  });

  const baseEnvContent = readAppEnv(baseId);
  if (baseEnvContent.trim()) {
    const filtered = baseEnvContent.split('\n').filter((l) => !l.startsWith('#')).join('\n');
    fs.writeFileSync(getAppEnvPath(newId), `# ${newId.toUpperCase()} Environment — cloned from ${baseId}\n${filtered}`, 'utf8');
  } else {
    initAppEnvFromConfig(newId);
  }

  const prefix = baseId.toUpperCase();
  const envUpdates = {};
  if (baseApp.server_host) envUpdates[`${prefix}_SERVER_HOST`] = baseApp.server_host;
  if (baseApp.ssh_key_path) envUpdates[`${prefix}_SSH_KEY_PATH`] = baseApp.ssh_key_path;
  if (baseApp.server_user) envUpdates[`${prefix}_SERVER_USER`] = baseApp.server_user;
  if (baseApp.ssh_port) envUpdates[`${prefix}_SSH_PORT`] = String(baseApp.ssh_port);
  if (Object.keys(envUpdates).length) updateEnvFileKeys(getAppEnvPath(newId), envUpdates);

  res.json({ ok: true, app_id: newId, env_file: getAppEnvPath(newId) });
});

app.delete('/api/apps/:id', requireAuth, (req, res) => {
  if (!db.getApp(req.params.id)) return res.status(404).json({ error: 'Not found' });
  const envPath = getAppEnvPath(req.params.id);
  try { if (fs.existsSync(envPath)) fs.unlinkSync(envPath); } catch {}
  db.deleteApp(req.params.id);
  res.json({ ok: true });
});

app.post('/api/apps/:id/config', requireAuth, async (req, res) => {
  const existing = db.getApp(req.params.id);
  if (!existing) return res.status(404).json({ error: 'Not found' });
  const { app_name, setup_script, server_user, server_host, ssh_port, ssh_key_path, app_env_keys, flags } = req.body;

  db.upsertApp({
    app_id: req.params.id,
    app_name: app_name || existing.app_name,
    setup_script: setup_script !== undefined ? setup_script : existing.setup_script,
    server_user: server_user || existing.server_user || 'azureuser',
    server_host: server_host !== undefined ? server_host : existing.server_host,
    ssh_port: parseInt(ssh_port) || existing.ssh_port || 22,
    ssh_key_path: ssh_key_path !== undefined ? ssh_key_path : existing.ssh_key_path,
    env_json: existing.env_json || '{}',
    flags_json: flags ? JSON.stringify(flags) : existing.flags_json || '{}',
  });

  ensureAppEnvExists(req.params.id);

  if (app_env_keys && typeof app_env_keys === 'object') {
    try { updateEnvFileKeys(getAppEnvPath(req.params.id), app_env_keys); } catch (err) {
      return res.json({ ok: true, env_error: err.message });
    }
  }

  const prefix = getBaseId(req.params.id).toUpperCase();
  const envUpdates = {};
  if (server_host) envUpdates[`${prefix}_SERVER_HOST`] = server_host;
  if (ssh_key_path) envUpdates[`${prefix}_SSH_KEY_PATH`] = ssh_key_path;
  if (server_user) envUpdates[`${prefix}_SERVER_USER`] = server_user;
  if (ssh_port) envUpdates[`${prefix}_SSH_PORT`] = String(ssh_port);
  if (Object.keys(envUpdates).length) updateEnvFileKeys(getAppEnvPath(req.params.id), envUpdates);

  res.json({ ok: true });
});

app.get('/api/apps/:id/env', requireAuth, (req, res) => {
  if (!db.getApp(req.params.id)) return res.status(404).json({ error: 'Not found' });
  ensureAppEnvExists(req.params.id);
  res.json({ content: readAppEnv(req.params.id), path: getAppEnvPath(req.params.id), ok: true });
});

app.post('/api/apps/:id/env', requireAuth, (req, res) => {
  if (!db.getApp(req.params.id)) return res.status(404).json({ error: 'Not found' });
  const { content } = req.body;
  if (typeof content !== 'string') return res.status(400).json({ error: 'content required' });
  try { writeAppEnv(req.params.id, content); res.json({ ok: true }); } catch (err) { res.status(500).json({ error: err.message }); }
});

app.post('/api/apps/:id/env/paste', requireAuth, (req, res) => {
  if (!db.getApp(req.params.id)) return res.status(404).json({ error: 'Not found' });
  const { content } = req.body;
  if (typeof content !== 'string') return res.status(400).json({ error: 'content required' });
  try {
    ensureAppEnvExists(req.params.id);
    const pasted = parseEnvContent(content);
    updateEnvFileKeys(getAppEnvPath(req.params.id), pasted);
    res.json({ ok: true, added: Object.keys(pasted).length });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.get('/api/apps/:id/env-keys', requireAuth, (req, res) => {
  if (!db.getApp(req.params.id)) return res.status(404).json({ error: 'Not found' });
  ensureAppEnvExists(req.params.id);
  res.json({ keys: getAppEnvVars(req.params.id), path: getAppEnvPath(req.params.id) });
});

app.post('/api/apps/:id/env-keys', requireAuth, (req, res) => {
  if (!db.getApp(req.params.id)) return res.status(404).json({ error: 'Not found' });
  const { keys } = req.body;
  if (!keys || typeof keys !== 'object') return res.status(400).json({ error: 'keys object required' });
  try {
    ensureAppEnvExists(req.params.id);
    updateEnvFileKeys(getAppEnvPath(req.params.id), keys);
    res.json({ ok: true });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.get('/api/apps/:id/deploy-mode', requireAuth, (req, res) => {
  if (!db.getApp(req.params.id)) return res.status(404).json({ error: 'Not found' });
  try { res.json(readDeployModeForApp(req.params.id)); } catch (err) { res.status(500).json({ error: err.message }); }
});

app.post('/api/apps/:id/deploy-mode', requireAuth, (req, res) => {
  if (!db.getApp(req.params.id)) return res.status(404).json({ error: 'Not found' });
  const { mode, domain_name, api_port, nginx_port } = req.body;
  if (!mode || !['domain', 'port'].includes(mode)) return res.status(400).json({ error: 'mode must be "domain" or "port"' });

  const prefix = getBaseId(req.params.id).toUpperCase();
  const envPath = getAppEnvPath(req.params.id);

  if (!readRawFile(envPath).trim()) initAppEnvFromConfig(req.params.id);

  const updates = {
    [`${prefix}_DEPLOY_DOMAIN`]: mode === 'domain' ? 'true' : 'false',
    [`${prefix}_SETUP_NGINX`]: mode === 'domain' ? 'true' : 'false',
  };

  if (domain_name !== undefined && domain_name !== null) updates[`${prefix}_DOMAIN_NAME`] = String(domain_name);
  if (api_port !== undefined && String(api_port).trim()) updates[`${prefix}_API_PORT`] = String(api_port).trim();
  if (nginx_port !== undefined && String(nginx_port).trim()) updates[`${prefix}_NGINX_PORT`] = String(nginx_port).trim();

  try {
    updateEnvFileKeys(envPath, updates);
    res.json({ ok: true, mode, ...readDeployModeForApp(req.params.id) });
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.get('/api/apps/:id/status', requireAuth, async (req, res) => {
  const effectiveApp = getEffectiveAppConfig(req.params.id);
  if (!effectiveApp) return res.status(404).json({ error: 'Not found' });
  if (!effectiveApp.server_host || !effectiveApp.ssh_key_path) return res.json({ ok: false, overall: 'not_configured', error: 'Server not configured' });
  try {
    const status = await fetchAppStatus(effectiveApp);
    db.setStatus(req.params.id, status);
    broadcast({ type: 'status_update', app_id: req.params.id, status });
    res.json(status);
  } catch (err) { res.status(500).json({ ok: false, error: err.message }); }
});

app.post('/api/apps/:id/service-action', requireAuth, async (req, res) => {
  const { service, action } = req.body;
  if (!service || !['stop', 'start', 'restart'].includes(action)) return res.status(400).json({ error: 'Invalid service or action' });
  const effectiveApp = getEffectiveAppConfig(req.params.id);
  if (!effectiveApp) return res.status(404).json({ error: 'Not found' });
  if (!effectiveApp.server_host || !effectiveApp.ssh_key_path) return res.status(400).json({ error: 'Server not configured' });
  try {
    const cfg = connCfg(effectiveApp);
    const cmd = `systemctl --user ${action} "${service}.service" 2>/dev/null || sudo systemctl ${action} "${service}.service" 2>&1 || echo "[WARN] Service control failed for ${service}"`;
    const { stdout, stderr } = await runSSH(cfg, cmd);
    res.json({ ok: true, output: (stdout + stderr).trim() });
  } catch (err) { res.status(500).json({ ok: false, error: err.message }); }
});

app.get('/api/apps/:id/health', requireAuth, async (req, res) => {
  const effectiveApp = getEffectiveAppConfig(req.params.id);
  if (!effectiveApp) return res.status(404).json({ error: 'Not found' });
  const prefix = getBaseId(req.params.id).toUpperCase();
  ensureAppEnvExists(req.params.id);
  const allVars = getMergedEnvVars(req.params.id);
  const host = effectiveApp.server_host;
  if (!host) return res.json({ ports: [], service_urls: [] });

  const portDefs = [
    { name: 'API', key: `${prefix}_API_PORT` },
    { name: 'Nginx', key: `${prefix}_NGINX_PORT` },
    { name: 'Observer', key: `${prefix}_OBSERVER_PORT` },
    { name: 'Deployer', key: `${prefix}_DEPLOYER_PORT` },
    { name: 'Stats', key: `${prefix}_STATS_PORT` },
    { name: 'Web', key: `${prefix}_WEB_PORT` },
    { name: 'Postgres', key: `${prefix}_POSTGRES_PORT` },
    { name: 'RabbitMQ', key: `${prefix}_RABBITMQ_PORT` },
    { name: 'RabbitMQ Mgmt', key: `${prefix}_RABBITMQ_MANAGEMENT_PORT` },
    { name: 'Redis Cache', key: `${prefix}_REDIS_CACHE_PORT` },
    { name: 'Redis Queue', key: `${prefix}_REDIS_QUEUE_PORT` },
    { name: 'Dashboard', key: 'DASHBOARD_PORT' },
  ];

  const portsToCheck = portDefs.filter((p) => allVars[p.key]).map((p) => ({ name: p.name, port: parseInt(allVars[p.key]) }));
  const results = await Promise.all(portsToCheck.map(async (p) => ({ ...p, up: await probePort(host, p.port) })));

  const serviceUrls = [
    { name: 'API Docs', key: `${prefix}_API_PORT`, path: '/docs' },
    { name: 'Nginx / Domain', key: `${prefix}_NGINX_PORT`, path: '/' },
    { name: 'Observer', key: `${prefix}_OBSERVER_PORT`, path: '/health' },
    { name: 'Deployer', key: `${prefix}_DEPLOYER_PORT`, path: '/health' },
    { name: 'Stats', key: `${prefix}_STATS_PORT`, path: '/health' },
  ].filter((s) => allVars[s.key]).map((s) => {
    const port = allVars[s.key];
    const up = results.find((r) => r.port === parseInt(port))?.up || false;
    return { name: s.name, url: `http://${host}:${port}${s.path}`, up };
  });

  res.json({ ports: results, service_urls: serviceUrls });
});

app.get('/api/apps/:id/logs', requireAuth, async (req, res) => {
  const effectiveApp = getEffectiveAppConfig(req.params.id);
  if (!effectiveApp) return res.status(404).json({ error: 'Not found' });
  if (!effectiveApp.server_host || !effectiveApp.ssh_key_path) return res.json({ logs: [] });

  const appId = req.params.id;
  const baseId = getBaseId(appId);
  const lines = parseInt(req.query.lines) || 100;
  const source = req.query.source || 'deploy';
  const allVars = getMergedEnvVars(appId);
  const prefix = baseId.toUpperCase();
  const logDir = allVars[`${prefix}_LOG_DIR`] || allVars['LOG_DIR'] || './tap-devops/logs';
  const cfg = connCfg(effectiveApp);

  if (source === 'service') {
    const service = req.query.service || `${baseId}-app`;
    try {
      const { stdout } = await runSSH(cfg, `journalctl --user -u ${service}.service -n ${lines} --no-pager --output=short-iso 2>/dev/null || docker logs ${service} --tail ${lines} 2>/dev/null || echo "(no logs found for ${service})"`);
      return res.json({ service, source: 'service', logs: stdout.split('\n').filter(Boolean) });
    } catch (err) { return res.status(500).json({ error: err.message }); }
  }

  const baseLogFile = `${logDir}/${baseId}-deploy.log`;
  const appLogFile = `${logDir}/${appId}-deploy.log`;
  const preferredLog = appId !== baseId ? appLogFile : baseLogFile;

  try {
    const { stdout } = await runSSH(cfg, `if [ -f "${preferredLog}" ]; then tail -n ${lines} "${preferredLog}"; elif [ -f "${baseLogFile}" ]; then tail -n ${lines} "${baseLogFile}"; else echo "(no deploy log found)"; fi`);
    return res.json({ source: 'file', log_file: preferredLog, logs: stdout.split('\n').filter(Boolean) });
  } catch (err) { return res.status(500).json({ error: err.message }); }
});

app.get('/api/apps/:id/github', requireAuth, async (req, res) => {
  const a = db.getApp(req.params.id);
  if (!a) return res.status(404).json({ error: 'Not found' });
  ensureAppEnvExists(req.params.id);
  const allVars = getMergedEnvVars(req.params.id);
  const prefix = getBaseId(req.params.id).toUpperCase();
  const repoUrl = allVars[`${prefix}_GIT_REPO`] || '';
  const branch = allVars[`${prefix}_GIT_BRANCH`] || 'main';
  const token = process.env.GITHUB_TOKEN || allVars['GITHUB_TOKEN'] || null;

  if (!repoUrl) return res.json({ error: 'No repo configured', branch_info: null, branches: [], commits: [] });

  try {
    const [branch_info, branches, commits] = await Promise.all([
      getBranchInfo(repoUrl, branch, token),
      getAllBranches(repoUrl, token),
      getRecentCommits(repoUrl, branch, token, 5),
    ]);
    res.json({ branch_info, branches, commits, repo_url: repoUrl, branch });
  } catch (err) { res.json({ error: err.message, branch_info: null, branches: [], commits: [] }); }
});

app.get('/api/apps/:id/deploy-history', requireAuth, (req, res) => {
  res.json(db.getDeployments(req.params.id, parseInt(req.query.limit) || 30));
});

app.post('/api/apps/:id/deploy', requireAuth, (req, res) => {
  const a = db.getApp(req.params.id);
  if (!a) return res.status(404).json({ error: 'Not found' });
  const extraFlags = Array.isArray(req.body.extra_flags)
    ? req.body.extra_flags.filter((f) => typeof f === 'string' && f.startsWith('-'))
    : [];
  const deployId = buildAndRunDeploy(a, extraFlags, req.body.trigger || 'manual');
  if (!deployId) return res.status(400).json({ error: 'Server not configured — set host and SSH key in Config first' });
  res.json({ ok: true, deploy_id: deployId });
});

app.post('/api/webhook/:id/deploy', async (req, res) => {
  const a = db.getApp(req.params.id);
  if (!a) return res.status(404).json({ error: 'App not found' });
  const prefix = getBaseId(req.params.id).toUpperCase();
  const allVars = getMergedEnvVars(req.params.id);
  const secretKey = allVars[`${prefix}_DEPLOY_SECRET_KEY`] || '';
  const providedKey = req.headers['x-deploy-key'] || req.headers['x-hub-signature-256'] || '';
  if (!secretKey || providedKey !== secretKey) return res.status(401).json({ error: 'Invalid deploy key' });
  const deployId = buildAndRunDeploy(a, ['--update', '--force', '--no-wait'], 'webhook');
  if (!deployId) return res.status(400).json({ error: 'Server not configured' });
  res.json({ ok: true, deploy_id: deployId, triggered: 'webhook' });
});

app.post('/api/apps/:id/ssh-test', requireAuth, async (req, res) => {
  const effectiveApp = getEffectiveAppConfig(req.params.id);
  if (!effectiveApp) return res.status(404).json({ error: 'Not found' });
  const override = req.body || {};
  const cfg = {
    host: override.server_host || effectiveApp.server_host,
    port: parseInt(override.ssh_port) || effectiveApp.ssh_port,
    username: override.server_user || effectiveApp.server_user,
    privateKeyPath: override.ssh_key_path || effectiveApp.ssh_key_path,
  };
  if (!cfg.host || !cfg.privateKeyPath) return res.status(400).json({ error: 'Not configured' });
  try {
    const { stdout } = await runSSH(cfg, 'echo "SSH_OK" && uname -a && uptime');
    res.json({ ok: true, output: stdout.trim() });
  } catch (err) { res.status(500).json({ ok: false, error: err.message }); }
});

app.post('/api/apps/:id/discover', requireAuth, async (req, res) => {
  const effectiveApp = getEffectiveAppConfig(req.params.id);
  if (!effectiveApp) return res.status(404).json({ error: 'Not found' });
  if (!effectiveApp.server_host || !effectiveApp.ssh_key_path) return res.status(400).json({ error: 'Server not configured' });
  try {
    const result = await discoverApp(connCfg(effectiveApp), getBaseId(req.params.id));
    res.json(result);
  } catch (err) { res.status(500).json({ error: err.message }); }
});

app.get('/api/deployments', requireAuth, (req, res) => {
  res.json(db.getRecentDeployments(30));
});

app.get('/api/deployments/:id', requireAuth, (req, res) => {
  const d = db.getDeployment(req.params.id);
  if (!d) return res.status(404).json({ error: 'Not found' });
  res.json(d);
});

app.get('/api/apps/:id/deployments', requireAuth, (req, res) => {
  res.json(db.getDeployments(req.params.id, parseInt(req.query.limit) || 30));
});

app.post('/api/deployments/:id/stop', requireAuth, (req, res) => {
  const deployId = parseInt(req.params.id);
  const deployment = db.getDeployment(deployId);
  if (!deployment) return res.status(404).json({ error: 'Deployment not found' });
  if (deployment.status !== 'running') return res.status(400).json({ error: 'Not running' });
  const conn = activeConnections.get(deployId);
  if (conn) { try { conn.end(); } catch {} activeConnections.delete(deployId); }
  db.finishDeployment(deployId, 'cancelled', -1);
  broadcast({ type: 'deploy_finish', app_id: deployment.app_id, deploy_id: deployId, status: 'cancelled' });
  res.json({ ok: true });
});

const keyUpload = multer({ dest: KEYS_DIR, limits: { fileSize: 100 * 1024 } });

app.get('/api/keys', requireAuth, (req, res) => res.json(db.getKeys()));

app.post('/api/keys/upload', requireAuth, keyUpload.single('keyfile'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file uploaded' });
  const name = (req.body.name || req.file.originalname).replace(/[^a-zA-Z0-9._-]/g, '_').replace(/\.(pem|key)$/i, '');
  const finalPath = path.join(KEYS_DIR, name + '.pem');
  fs.renameSync(req.file.path, finalPath);
  fs.chmodSync(finalPath, 0o600);
  const firstLine = readRawFile(finalPath).split('\n')[0];
  if (!firstLine.includes('PRIVATE KEY') && !firstLine.includes('BEGIN RSA') && !firstLine.includes('BEGIN OPENSSH')) {
    fs.unlinkSync(finalPath);
    return res.status(400).json({ error: 'Not a valid private key file' });
  }
  db.saveKey(name, finalPath, null);
  res.json({ ok: true, name, path: finalPath });
});

app.delete('/api/keys/:id', requireAuth, (req, res) => {
  const key = db.getKey(req.params.id);
  if (!key) return res.status(404).json({ error: 'Not found' });
  try { fs.unlinkSync(key.file_path); } catch {}
  db.deleteKey(req.params.id);
  res.json({ ok: true });
});

app.post('/api/apps/:id/ssh-test', requireAuth, async (req, res) => {
  const effectiveApp = getEffectiveAppConfig(req.params.id);
  if (!effectiveApp) return res.status(404).json({ error: 'Not found' });
  const override = req.body || {};
  const cfg = {
    host: override.server_host || effectiveApp.server_host,
    port: parseInt(override.ssh_port) || effectiveApp.ssh_port,
    username: override.server_user || effectiveApp.server_user,
    privateKeyPath: override.ssh_key_path || effectiveApp.ssh_key_path,
  };
  if (!cfg.host || !cfg.privateKeyPath) return res.status(400).json({ error: 'Not configured' });
  try {
    const { stdout } = await runSSH(cfg, 'echo "SSH_OK" && uname -a && uptime');
    res.json({ ok: true, output: stdout.trim() });
  } catch (err) { res.status(500).json({ ok: false, error: err.message }); }
});

app.post('/api/keys/upload', requireAuth, keyUpload.single('keyfile'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file uploaded' });
  const name = (req.body.name || req.file.originalname).replace(/[^a-zA-Z0-9._-]/g, '_').replace(/\.(pem|key)$/i, '');
  const finalPath = path.join(KEYS_DIR, name + '.pem');
  fs.renameSync(req.file.path, finalPath);
  fs.chmodSync(finalPath, 0o600);
  const firstLine = readRawFile(finalPath).split('\n')[0];
  if (!firstLine.includes('PRIVATE KEY') && !firstLine.includes('BEGIN RSA') && !firstLine.includes('BEGIN OPENSSH')) {
    fs.unlinkSync(finalPath);
    return res.status(400).json({ error: 'Not a valid private key file' });
  }
  db.saveKey(name, finalPath, null);
  res.json({ ok: true, name, path: finalPath });
});

app.post('/api/apps/:id/pem-upload', requireAuth, keyUpload.single('keyfile'), async (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file uploaded' });
  const appId = req.params.id;
  const name = `${appId}-${(req.body.name || req.file.originalname).replace(/[^a-zA-Z0-9._-]/g, '_').replace(/\.(pem|key)$/i, '')}`;
  const finalPath = path.join(KEYS_DIR, name + '.pem');
  fs.renameSync(req.file.path, finalPath);
  fs.chmodSync(finalPath, 0o600);
  const firstLine = readRawFile(finalPath).split('\n')[0];
  if (!firstLine.includes('PRIVATE KEY') && !firstLine.includes('BEGIN RSA') && !firstLine.includes('BEGIN OPENSSH')) {
    fs.unlinkSync(finalPath);
    return res.status(400).json({ error: 'Not a valid private key file' });
  }
  db.saveKey(name, finalPath, null);
  updateEnvFileKey(CONFIG_ENV_PATH, 'DASHBOARD_PEM_FILE', finalPath);
  res.json({ ok: true, name, path: finalPath });
});

let polling = false;
async function pollAllStatus() {
  if (polling) return;
  polling = true;
  try {
    for (const a of db.getApps()) {
      const effectiveApp = getEffectiveAppConfig(a.app_id);
      if (!effectiveApp?.server_host || !effectiveApp?.ssh_key_path) continue;
      try {
        const status = await fetchAppStatus(effectiveApp);
        db.setStatus(a.app_id, status);
        broadcast({ type: 'status_update', app_id: a.app_id, status });
      } catch {}
      await new Promise((r) => setTimeout(r, 3000));
    }
  } finally { polling = false; }
}

cron.schedule(`*/${STATUS_POLL_INTERVAL} * * * * *`, () => { pollAllStatus().catch(() => {}); });

let configEnvWatchDebounce = null;
let configEnvLastContent = readConfigEnv();

try {
  fs.watch(CONFIG_ENV_PATH, (eventType) => {
    if (eventType !== 'change') return;
    clearTimeout(configEnvWatchDebounce);
    configEnvWatchDebounce = setTimeout(() => {
      const newContent = readConfigEnv();
      if (newContent === configEnvLastContent) return;
      const synced = syncConfigEnvToAppEnvs(configEnvLastContent, newContent);
      configEnvLastContent = newContent;
      const totalKeys = Object.values(synced).reduce((n, keys) => n + keys.length, 0);
      if (totalKeys > 0) {
        console.log(`[config-env] External change — synced ${totalKeys} key(s)`, synced);
        broadcast({ type: 'config_env_changed', synced });
      }
    }, 300);
  });
} catch {}

server.listen(PORT, () => {
  console.log(`\n  TAP DevOps Dashboard`);
  console.log(`  Running on http://localhost:${PORT}`);
  console.log(`  Config: ${CONFIG_ENV_PATH}`);
  console.log(`  App envs: ${APP_ENVS_DIR}`);
  console.log(`  ${db.userCount() === 0 ? 'No users — visit dashboard to create admin' : 'Auth configured'}\n`);
});