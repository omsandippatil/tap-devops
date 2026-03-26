require('dotenv').config({ path: process.env.CONFIG_FILE || '.env' });
const express = require('express');
const session = require('express-session');
const bcrypt = require('bcryptjs');
const multer = require('multer');
const path = require('path');
const fs = require('fs');
const http = require('http');
const { WebSocketServer } = require('ws');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const cron = require('node-cron');

const db = require('./db');
const { fetchAppStatus, runSSH, streamSSH } = require('./ssh');
const { getBranchInfo, getAllBranches, getRecentCommits } = require('./github');

const PORT = process.env.DASHBOARD_PORT || 9000;
const SESSION_SECRET = process.env.SESSION_SECRET || 'tap-devops-' + Math.random().toString(36).slice(2);
const KEYS_DIR = path.join(__dirname, 'data', 'keys');
fs.mkdirSync(KEYS_DIR, { recursive: true });

const app = express();
const server = http.createServer(app);

app.use(helmet({ contentSecurityPolicy: false }));
app.use(express.json());
app.use(express.urlencoded({ extended: true }));
app.use(express.static(path.join(__dirname, 'public')));

app.use(session({
  secret: SESSION_SECRET,
  resave: false,
  saveUninitialized: false,
  cookie: { secure: false, httpOnly: true, maxAge: 8 * 60 * 60 * 1000 },
}));

const limiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 300 });
const authLimiter = rateLimit({ windowMs: 15 * 60 * 1000, max: 20, message: { error: 'Too many attempts' } });
app.use('/api', limiter);

const wss = new WebSocketServer({ server });
const wsClients = new Map();

wss.on('connection', (ws) => {
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
  ws.on('message', (msg) => {
    try {
      const { type, sessionId } = JSON.parse(msg);
      if (type === 'auth' && sessionId) wsClients.set(sessionId, ws);
    } catch {}
  });
  ws.on('close', () => {
    for (const [sid, client] of wsClients) {
      if (client === ws) wsClients.delete(sid);
    }
  });
});

setInterval(() => {
  wss.clients.forEach(ws => {
    if (!ws.isAlive) return ws.terminate();
    ws.isAlive = false;
    ws.ping();
  });
}, 30000);

function broadcast(data) {
  const msg = JSON.stringify(data);
  wss.clients.forEach(ws => {
    if (ws.readyState === 1) ws.send(msg);
  });
}

function requireAuth(req, res, next) {
  if (req.session?.user) return next();
  res.status(401).json({ error: 'Unauthorized' });
}

app.post('/api/auth/setup', authLimiter, async (req, res) => {
  if (db.userCount() > 0) return res.status(403).json({ error: 'Already set up' });
  const { username, password } = req.body;
  if (!username || !password || password.length < 8)
    return res.status(400).json({ error: 'Username required, password min 8 chars' });
  const hash = await bcrypt.hash(password, 12);
  db.createUser(username, hash);
  req.session.user = { username };
  res.json({ ok: true });
});

app.post('/api/auth/login', authLimiter, async (req, res) => {
  const { username, password } = req.body;
  const user = db.getUser(username);
  if (!user) return res.status(401).json({ error: 'Invalid credentials' });
  const match = await bcrypt.compare(password, user.password_hash);
  if (!match) return res.status(401).json({ error: 'Invalid credentials' });
  req.session.user = { username };
  res.json({ ok: true, username });
});

app.post('/api/auth/logout', (req, res) => {
  req.session.destroy(() => res.json({ ok: true }));
});

app.get('/api/auth/status', (req, res) => {
  res.json({
    authenticated: !!req.session?.user,
    user: req.session?.user?.username || null,
    needsSetup: db.userCount() === 0,
  });
});

const keyUpload = multer({
  dest: KEYS_DIR,
  limits: { fileSize: 50 * 1024 },
});

app.get('/api/keys', requireAuth, (req, res) => {
  res.json(db.getKeys());
});

app.post('/api/keys/upload', requireAuth, keyUpload.single('keyfile'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file uploaded' });
  const name = (req.body.name || req.file.originalname).replace(/[^a-zA-Z0-9._-]/g, '_').replace(/\.(pem|key)$/i, '');
  const finalPath = path.join(KEYS_DIR, name + '.pem');
  fs.renameSync(req.file.path, finalPath);
  fs.chmodSync(finalPath, 0o600);
  const firstLine = fs.readFileSync(finalPath, 'utf8').split('\n')[0];
  if (!firstLine.includes('PRIVATE KEY') && !firstLine.includes('BEGIN RSA') && !firstLine.includes('BEGIN OPENSSH')) {
    fs.unlinkSync(finalPath);
    return res.status(400).json({ error: 'File does not appear to be a valid private key' });
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

app.get('/api/apps', requireAuth, (req, res) => {
  const apps = db.getApps();
  res.json(apps.map(a => ({
    ...a,
    env_json: JSON.parse(a.env_json || '{}'),
    flags_json: JSON.parse(a.flags_json || '{}'),
    status: db.getStatus(a.app_id),
  })));
});

app.get('/api/apps/:id', requireAuth, (req, res) => {
  const a = db.getApp(req.params.id);
  if (!a) return res.status(404).json({ error: 'Not found' });
  res.json({
    ...a,
    env_json: JSON.parse(a.env_json || '{}'),
    flags_json: JSON.parse(a.flags_json || '{}'),
  });
});

app.post('/api/apps/:id/config', requireAuth, (req, res) => {
  const { app_name, setup_script, server_user, server_host, ssh_port, ssh_key_path, env, flags } = req.body;
  const existing = db.getApp(req.params.id);
  if (!existing) return res.status(404).json({ error: 'Not found' });
  db.upsertApp({
    app_id: req.params.id,
    app_name: app_name || existing.app_name,
    setup_script: setup_script !== undefined ? setup_script : existing.setup_script,
    server_user: server_user || existing.server_user || 'azureuser',
    server_host: server_host !== undefined ? server_host : existing.server_host,
    ssh_port: parseInt(ssh_port) || existing.ssh_port || 22,
    ssh_key_path: ssh_key_path !== undefined ? ssh_key_path : existing.ssh_key_path,
    env_json: env ? JSON.stringify(env) : existing.env_json,
    flags_json: flags ? JSON.stringify(flags) : existing.flags_json || '{}',
  });
  res.json({ ok: true });
});

app.get('/api/apps/:id/status', requireAuth, async (req, res) => {
  const a = db.getApp(req.params.id);
  if (!a) return res.status(404).json({ error: 'Not found' });
  if (!a.server_host || !a.ssh_key_path)
    return res.json({ ok: false, overall: 'not_configured', error: 'Server not configured' });
  try {
    const status = await fetchAppStatus(a);
    db.setStatus(req.params.id, status);
    broadcast({ type: 'status_update', app_id: req.params.id, status });
    res.json(status);
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

app.get('/api/apps/:id/logs', requireAuth, async (req, res) => {
  const a = db.getApp(req.params.id);
  if (!a) return res.status(404).json({ error: 'Not found' });
  if (!a.server_host || !a.ssh_key_path) return res.json({ logs: [] });
  const service = req.query.service || `${a.app_id}_app`;
  const lines = parseInt(req.query.lines) || 100;
  try {
    const { stdout } = await runSSH(
      { host: a.server_host, port: a.ssh_port || 22, username: a.server_user || 'azureuser', privateKeyPath: a.ssh_key_path },
      `journalctl --user -u ${service}.service -n ${lines} --no-pager --output=short-iso 2>/dev/null || echo "(no logs)"`
    );
    res.json({ service, logs: stdout.split('\n').filter(Boolean) });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/api/apps/:id/github', requireAuth, async (req, res) => {
  const a = db.getApp(req.params.id);
  if (!a) return res.status(404).json({ error: 'Not found' });
  const env = JSON.parse(a.env_json || '{}');
  const prefix = a.app_id.toUpperCase();
  const repoUrl = env[`${prefix}_GIT_REPO`] || '';
  const branch = env[`${prefix}_GIT_BRANCH`] || 'main';
  const token = process.env.GITHUB_TOKEN || null;
  if (!repoUrl) return res.json({ error: 'No repo configured', branch_info: null, branches: [], commits: [] });
  const [branch_info, branches, commits] = await Promise.all([
    getBranchInfo(repoUrl, branch, token),
    getAllBranches(repoUrl, token),
    getRecentCommits(repoUrl, branch, token, 5),
  ]);
  res.json({ branch_info, branches, commits, repo_url: repoUrl, branch });
});

function buildFlagString(flagsObj) {
  if (!flagsObj || typeof flagsObj !== 'object') return '';
  return Object.entries(flagsObj)
    .filter(([, val]) => val === true || (typeof val === 'string' && val.trim() !== '' && val !== 'false'))
    .map(([flag, val]) => val === true ? flag : `${flag} ${val}`)
    .join(' ');
}

app.post('/api/apps/:id/deploy', requireAuth, async (req, res) => {
  const a = db.getApp(req.params.id);
  if (!a) return res.status(404).json({ error: 'Not found' });
  if (!a.server_host || !a.ssh_key_path)
    return res.status(400).json({ error: 'Server not configured' });

  const trigger = req.body.trigger || 'manual';
  const deployId = db.startDeployment(a.app_id, trigger);
  res.json({ ok: true, deploy_id: deployId });

  let log = '';
  broadcast({ type: 'deploy_start', app_id: a.app_id, deploy_id: deployId });

  try {
    const env = JSON.parse(a.env_json || '{}');
    const savedFlags = JSON.parse(a.flags_json || '{}');
    const requestFlags = req.body.flags || {};
    const mergedFlags = { ...savedFlags, ...requestFlags };
    const builtFlagStr = buildFlagString(mergedFlags);
    const extraFlagStr = Array.isArray(req.body.extra_flags) ? req.body.extra_flags.join(' ') : (req.body.extra_flags || '');
    const fullFlagStr = [builtFlagStr, extraFlagStr].filter(Boolean).join(' ');

    const envLines = Object.entries(env)
      .map(([k, v]) => `export ${k}="${String(v).replace(/"/g, '\\"')}"`)
      .join('\n');

    const setupScript = a.setup_script || `~/tap-devops/setup/setup-${a.app_id}.sh`;

    const remoteCmd = `
${envLines}
SCRIPT="${setupScript}"
if [[ ! -f "$SCRIPT" ]]; then
  SCRIPT="\${HOME}/tap-devops/setup/setup-${a.app_id}.sh"
fi
if [[ ! -f "$SCRIPT" ]]; then
  echo "ERROR: Setup script not found: $SCRIPT"
  exit 1
fi
bash "$SCRIPT" ${fullFlagStr}
`;

    const { code } = await streamSSH(
      { host: a.server_host, port: a.ssh_port || 22, username: a.server_user || 'azureuser', privateKeyPath: a.ssh_key_path },
      `bash -s`,
      (chunk) => {
        log += chunk;
        if (log.length > 100000) log = log.slice(-100000);
        db.updateDeploymentLog(deployId, log);
        broadcast({ type: 'deploy_log', app_id: a.app_id, deploy_id: deployId, chunk });
      }
    );

    const status = code === 0 ? 'success' : 'failed';
    db.finishDeployment(deployId, status, code);
    broadcast({ type: 'deploy_finish', app_id: a.app_id, deploy_id: deployId, status, code });
  } catch (err) {
    log += `\nERROR: ${err.message}`;
    db.updateDeploymentLog(deployId, log);
    db.finishDeployment(deployId, 'failed', -1);
    broadcast({ type: 'deploy_finish', app_id: a.app_id, deploy_id: deployId, status: 'failed', error: err.message });
  }
});

app.get('/api/apps/:id/deployments', requireAuth, (req, res) => {
  res.json(db.getDeployments(req.params.id, parseInt(req.query.limit) || 20));
});

app.get('/api/deployments/:id', requireAuth, (req, res) => {
  const d = db.getDeployment(req.params.id);
  if (!d) return res.status(404).json({ error: 'Not found' });
  res.json(d);
});

app.get('/api/deployments', requireAuth, (req, res) => {
  res.json(db.getRecentDeployments(20));
});

app.post('/api/apps/:id/ssh-test', requireAuth, async (req, res) => {
  const a = db.getApp(req.params.id);
  if (!a) return res.status(404).json({ error: 'Not found' });
  if (!a.server_host || !a.ssh_key_path) return res.status(400).json({ error: 'Not configured' });
  try {
    const { stdout } = await runSSH(
      { host: a.server_host, port: a.ssh_port || 22, username: a.server_user || 'azureuser', privateKeyPath: a.ssh_key_path },
      'echo "SSH_OK" && uname -a && uptime'
    );
    res.json({ ok: true, output: stdout.trim() });
  } catch (err) {
    res.status(500).json({ ok: false, error: err.message });
  }
});

async function pollAllStatus() {
  const apps = db.getApps();
  for (const a of apps) {
    if (!a.server_host || !a.ssh_key_path) continue;
    try {
      const status = await fetchAppStatus(a);
      db.setStatus(a.app_id, status);
      broadcast({ type: 'status_update', app_id: a.app_id, status });
    } catch {}
    await new Promise(r => setTimeout(r, 2000));
  }
}

const pollInterval = parseInt(process.env.STATUS_POLL_INTERVAL_SECONDS || '60');
cron.schedule(`*/${pollInterval} * * * * *`, () => { pollAllStatus().catch(() => {}); });

server.listen(PORT, () => {
  console.log(`\n  TAP DevOps Dashboard`);
  console.log(`  Running on http://localhost:${PORT}`);
  console.log(`  ${db.userCount() === 0 ? '⚠  No users — visit /setup to create admin' : '✓ Auth configured'}\n`);
});