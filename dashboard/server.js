require('dotenv').config();
const express = require('express');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const db = require('./db');
const ssh = require('./ssh');
const github = require('./github');

const app = express();
const PORT = process.env.PORT || 4000;
const AUTH_TOKEN = process.env.AUTH_TOKEN;
const SCRIPTS_DIR = process.env.SCRIPTS_DIR || path.join(__dirname, 'scripts');

app.use(express.json({ limit: '10mb' }));
app.use(express.static(path.join(__dirname, 'public')));

fs.mkdirSync(SCRIPTS_DIR, { recursive: true });
fs.mkdirSync(path.join(__dirname, 'logs'), { recursive: true });
fs.mkdirSync(path.join(__dirname, 'keys'), { recursive: true });

function auth(req, res, next) {
  if (!AUTH_TOKEN) return next();
  const h = req.headers.authorization;
  if (h && h === `Bearer ${AUTH_TOKEN}`) return next();
  if (req.query.token && req.query.token === AUTH_TOKEN) return next();
  res.status(401).json({ error: 'Unauthorized' });
}

const statusCache = {};
const CACHE_TTL = 30000;
const activeJobs = new Map();
const sseClients = new Set();

function broadcastSSE(data) {
  const msg = `data: ${JSON.stringify(data)}\n\n`;
  sseClients.forEach(res => { try { res.write(msg); } catch {} });
}

async function refreshStatus(appId) {
  const appData = db.getApp(appId);
  if (!appData) return null;
  const [health, metrics, version, commit] = await Promise.allSettled([
    ssh.checkHealth(appId),
    ssh.getMetrics(appId),
    ssh.getVersion(appId),
    github.getLatestCommit(appId),
  ]);
  const lastDeploy = db.getDeploymentsByApp(appId, 1)[0] || null;
  const activeJob = activeJobs.get(appId) || null;
  const result = {
    app: appId,
    id: appId,
    name: appData.name,
    type: appData.type,
    tags: appData.tags || [],
    config: appData.config,
    healthy: health.status === 'fulfilled' ? health.value.healthy : false,
    httpCode: health.status === 'fulfilled' ? health.value.code : 0,
    metrics: metrics.status === 'fulfilled' ? metrics.value : {},
    version: version.status === 'fulfilled' ? version.value : 'unknown',
    commit: commit.status === 'fulfilled' ? commit.value : null,
    lastDeploy,
    activeJob,
    cachedAt: Date.now(),
  };
  statusCache[appId] = result;
  return result;
}

async function getStatus(appId) {
  const cached = statusCache[appId];
  if (cached && Date.now() - cached.cachedAt < CACHE_TTL) return cached;
  return refreshStatus(appId);
}

function buildJobEnv(appId) {
  const appData = db.getApp(appId);
  const creds = db.getCredentialMap(appId);
  const cfg = appData?.config || {};
  return {
    ...process.env,
    ...creds,
    APP_ID: appId,
    APP_HOST: cfg.host || '',
    APP_SSH_USER: cfg.ssh_user || '',
    APP_PEM: cfg.ssh_key_path || process.env.DASHBOARD_PEM || '',
    APP_BRANCH: cfg.branch || 'main',
    APP_REPO: cfg.repo || '',
    APP_DIR: cfg.app_dir || '',
    BENCH_DIR: cfg.bench_dir || '',
    DOCKER_DIR: cfg.docker_compose_dir || '',
  };
}

function spawnJob(appId, jobType, command, extraEnv = {}, triggeredBy = 'dashboard') {
  const jobId = `${appId}-${jobType}-${Date.now()}`;
  const logPath = path.join(__dirname, 'logs', `${jobId}.log`);
  const logStream = fs.createWriteStream(logPath, { flags: 'a' });
  const env = { ...buildJobEnv(appId), ...extraEnv };
  const proc = spawn('bash', ['-c', command], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  const startedAt = Date.now();
  const rec = db.startJobRun(appId, jobType, proc.pid, triggeredBy);
  const jobInfo = { jobId, jobType, pid: proc.pid, startedAt, logPath, status: 'running', recId: rec.lastInsertRowid };
  activeJobs.set(appId, jobInfo);
  let buffer = '';
  const onData = (chunk) => {
    const text = chunk.toString();
    buffer += text;
    logStream.write(text);
    broadcastSSE({ type: 'job_log', appId, jobId, chunk: text });
  };
  proc.stdout.on('data', onData);
  proc.stderr.on('data', onData);
  proc.on('close', (code) => {
    logStream.end();
    const duration = Date.now() - startedAt;
    const status = code === 0 ? 'success' : 'failed';
    db.finishJobRun(jobInfo.recId, status, buffer.slice(-80000), duration);
    activeJobs.delete(appId);
    if (statusCache[appId]) statusCache[appId].cachedAt = 0;
    broadcastSSE({ type: 'job_done', appId, jobId, jobType, status, duration, exitCode: code });
  });
  return jobInfo;
}

function buildSSHSetupCommand(appId, scriptPath) {
  const appData = db.getApp(appId);
  const cfg = appData.config;
  const creds = db.getCredentialMap(appId);
  const pem = cfg.ssh_key_path || process.env.DASHBOARD_PEM;
  const sshUser = cfg.ssh_user;
  const host = cfg.host;
  const envContent = Object.entries(creds).map(([k, v]) => `${k}=${v.replace(/'/g, "'\\''")}`).join('\n');
  const ts = Date.now();
  const remoteScript = `/tmp/setup-${appId}-${ts}.sh`;
  const envFile = `/tmp/secrets-${appId}-${ts}.env`;
  const launcherPath = `/tmp/launcher-${appId}-${ts}.sh`;
  const logPath = `/tmp/job-${appId}-${ts}.log`;
  const rcPath = `/tmp/job-${appId}-${ts}.rc`;

  return `
set -euo pipefail
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o BatchMode=yes"
scp -q $SSH_OPTS -i '${pem}' '${scriptPath}' '${sshUser}@${host}:${remoteScript}'
printf '%s\n' '${envContent}' | ssh $SSH_OPTS -i '${pem}' '${sshUser}@${host}' "cat > ${envFile} && chmod 600 ${envFile}"
ssh $SSH_OPTS -i '${pem}' '${sshUser}@${host}' "chmod +x ${remoteScript}"
cat <<'LAUNCHER' | ssh $SSH_OPTS -i '${pem}' '${sshUser}@${host}' "cat > ${launcherPath} && chmod +x ${launcherPath}"
#!/bin/bash
LOG=${logPath}
RC=${rcPath}
rm -f "$LOG" "$RC"
exec >"$LOG" 2>&1
echo "=== setup ${appId}: $(date) | $(whoami) ==="
set -a; source ${envFile}; set +a
bash ${remoteScript}
echo $? > "$RC"
LAUNCHER
ssh $SSH_OPTS -i '${pem}' '${sshUser}@${host}' "nohup bash ${launcherPath} >/dev/null 2>&1 &"
echo "=== launched on ${host} — polling... ==="
waited=0; max=2400
while [ "$waited" -lt "$max" ]; do
  sleep 15; waited=$((waited+15))
  ssh $SSH_OPTS -i '${pem}' '${sshUser}@${host}' "cat ${logPath} 2>/dev/null" || true
  rc=$(ssh $SSH_OPTS -i '${pem}' '${sshUser}@${host}' "cat ${rcPath} 2>/dev/null | tr -d '[:space:]'" || echo "")
  if [ -n "$rc" ]; then
    if [ "$rc" = "0" ]; then echo "=== complete ==="; exit 0
    else echo "=== FAILED (exit $rc) ==="; exit 1; fi
  fi
  echo "[${waited}s] running..."
done
echo "=== TIMED OUT ==="; exit 1
  `;
}

function buildSSHRefreshCommand(appId, scriptPath) {
  const appData = db.getApp(appId);
  const cfg = appData.config;
  const creds = db.getCredentialMap(appId);
  const pem = cfg.ssh_key_path || process.env.DASHBOARD_PEM;
  const sshUser = cfg.ssh_user;
  const host = cfg.host;
  const envContent = Object.entries(creds).map(([k, v]) => `${k}=${v.replace(/'/g, "'\\''")}`).join('\n');
  const ts = Date.now();
  const remoteScript = `/tmp/refresh-${appId}-${ts}.sh`;
  const envFile = `/tmp/secrets-${appId}-${ts}.env`;

  return `
set -euo pipefail
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=30 -o BatchMode=yes"
scp -q $SSH_OPTS -i '${pem}' '${scriptPath}' '${sshUser}@${host}:${remoteScript}'
printf '%s\n' '${envContent}' | ssh $SSH_OPTS -i '${pem}' '${sshUser}@${host}' "cat > ${envFile} && chmod 600 ${envFile}"
ssh $SSH_OPTS -i '${pem}' '${sshUser}@${host}' "chmod +x ${remoteScript} && set -a && source ${envFile} && set +a && bash ${remoteScript}"
ssh $SSH_OPTS -i '${pem}' '${sshUser}@${host}' "rm -f ${remoteScript} ${envFile}" || true
  `;
}

app.get('/api/status', auth, async (req, res) => {
  try {
    const apps = db.getApps().filter(a => a.enabled);
    const results = await Promise.all(apps.map(a => getStatus(a.id)));
    const stats = db.getStats();
    stats.activeJobs = activeJobs.size;
    res.json({ apps: results.filter(Boolean), stats, timestamp: Date.now() });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/status/:appId', auth, async (req, res) => {
  if (!db.getApp(req.params.appId)) return res.status(404).json({ error: 'Unknown app' });
  try { res.json(await refreshStatus(req.params.appId)); }
  catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/apps', auth, (req, res) => res.json(db.getApps()));

app.post('/api/apps', auth, (req, res) => {
  const { id, name, type, config, tags } = req.body;
  if (!id || !name || !type) return res.status(400).json({ error: 'id, name, type required' });
  if (!/^[a-z0-9_-]+$/.test(id)) return res.status(400).json({ error: 'id: lowercase alphanumeric/dash/underscore only' });
  db.upsertApp(id, name, type || 'generic', config || {}, tags || []);
  delete statusCache[id];
  res.json({ ok: true, app: db.getApp(id) });
});

app.put('/api/apps/:appId', auth, (req, res) => {
  const { appId } = req.params;
  const existing = db.getApp(appId);
  if (!existing) return res.status(404).json({ error: 'Not found' });
  const { name, type, config, tags } = req.body;
  db.upsertApp(appId, name || existing.name, type || existing.type, config || existing.config, tags || existing.tags);
  delete statusCache[appId];
  res.json({ ok: true, app: db.getApp(appId) });
});

app.delete('/api/apps/:appId', auth, (req, res) => {
  if (!db.getApp(req.params.appId)) return res.status(404).json({ error: 'Not found' });
  db.deleteApp(req.params.appId);
  delete statusCache[req.params.appId];
  res.json({ ok: true });
});

app.patch('/api/apps/:appId/toggle', auth, (req, res) => {
  const appData = db.getApp(req.params.appId);
  if (!appData) return res.status(404).json({ error: 'Not found' });
  db.toggleApp(req.params.appId, !appData.enabled);
  res.json({ ok: true });
});

app.post('/api/apps/:appId/test-connection', auth, async (req, res) => {
  const appData = db.getApp(req.params.appId);
  if (!appData) return res.status(404).json({ error: 'Not found' });
  const cfg = appData.config;
  const result = await ssh.testConnection(cfg.host, cfg.ssh_user, cfg.ssh_key_path || process.env.DASHBOARD_PEM);
  res.json(result);
});

app.get('/api/apps/:appId/credentials', auth, (req, res) => {
  if (!db.getApp(req.params.appId)) return res.status(404).json({ error: 'Not found' });
  const creds = db.getCredentials(req.params.appId);
  res.json(creds.map(c => ({ ...c, value: c.is_secret ? '***' : c.value })));
});

app.post('/api/apps/:appId/credentials', auth, (req, res) => {
  const { appId } = req.params;
  if (!db.getApp(appId)) return res.status(404).json({ error: 'Not found' });
  const { key_name, value, is_secret } = req.body;
  if (!key_name || value === undefined) return res.status(400).json({ error: 'key_name and value required' });
  db.setCredential(appId, key_name, value, is_secret ? 1 : 0);
  res.json({ ok: true });
});

app.delete('/api/apps/:appId/credentials/:key', auth, (req, res) => {
  db.deleteCredential(req.params.appId, req.params.key);
  res.json({ ok: true });
});

app.post('/api/apps/:appId/setup', auth, (req, res) => {
  const { appId } = req.params;
  const appData = db.getApp(appId);
  if (!appData) return res.status(404).json({ error: 'Not found' });
  if (activeJobs.has(appId)) return res.status(409).json({ error: 'Job already running', job: activeJobs.get(appId) });
  const cfg = appData.config;
  if (!cfg.host || !cfg.ssh_user) return res.status(400).json({ error: 'host and ssh_user required in config' });
  const scriptName = cfg.setup_script || `setup-${appId}.sh`;
  const scriptPath = resolveScript(scriptName);
  if (!scriptPath) return res.status(404).json({ error: `Setup script not found: ${scriptName}` });
  const command = buildSSHSetupCommand(appId, scriptPath);
  const job = spawnJob(appId, 'setup', command, {}, req.body.triggeredBy || 'dashboard');
  db.recordDeployment({ app: appId, commit: 'setup', branch: cfg.branch || 'n/a', status: 'running', triggered_by: 'dashboard', message: 'Full setup triggered' });
  res.json({ ok: true, jobId: job.jobId, pid: job.pid });
});

app.post('/api/apps/:appId/refresh', auth, (req, res) => {
  const { appId } = req.params;
  const appData = db.getApp(appId);
  if (!appData) return res.status(404).json({ error: 'Not found' });
  if (activeJobs.has(appId)) return res.status(409).json({ error: 'Job already running', job: activeJobs.get(appId) });
  const cfg = appData.config;
  if (!cfg.host || !cfg.ssh_user) return res.status(400).json({ error: 'host and ssh_user required in config' });
  const scriptName = cfg.refresh_script || `refresh-${appId}.sh`;
  const scriptPath = resolveScript(scriptName);
  if (!scriptPath) return res.status(404).json({ error: `Refresh script not found: ${scriptName}` });
  const command = buildSSHRefreshCommand(appId, scriptPath);
  const job = spawnJob(appId, 'refresh', command, {}, req.body.triggeredBy || 'dashboard');
  res.json({ ok: true, jobId: job.jobId, pid: job.pid });
});

app.post('/api/apps/:appId/run-script', auth, (req, res) => {
  const { appId } = req.params;
  const appData = db.getApp(appId);
  if (!appData) return res.status(404).json({ error: 'Not found' });
  if (activeJobs.has(appId)) return res.status(409).json({ error: 'Job already running' });
  const { script_name, job_type } = req.body;
  const scriptPath = resolveScript(script_name);
  if (!scriptPath) return res.status(404).json({ error: `Script not found: ${script_name}` });
  const cfg = appData.config;
  const command = buildSSHRefreshCommand(appId, scriptPath);
  const job = spawnJob(appId, job_type || 'custom', command);
  res.json({ ok: true, jobId: job.jobId, pid: job.pid });
});

function resolveScript(name) {
  const fsPath = path.join(SCRIPTS_DIR, path.basename(name));
  if (fs.existsSync(fsPath)) return fsPath;
  const dbScript = db.getScript(name);
  if (dbScript) {
    const tmpPath = path.join(SCRIPTS_DIR, `.tmp-${path.basename(name)}`);
    fs.writeFileSync(tmpPath, dbScript.content, 'utf8');
    fs.chmodSync(tmpPath, '755');
    return tmpPath;
  }
  return null;
}

app.post('/api/apps/:appId/deploy', auth, async (req, res) => {
  const { appId } = req.params;
  const appData = db.getApp(appId);
  if (!appData) return res.status(404).json({ error: 'Not found' });
  const cfg = appData.config;
  if (!cfg.repo) return res.status(400).json({ error: 'No GitHub repo configured' });
  const startedAt = Date.now();
  const rec = db.recordDeployment({ app: appId, commit: 'manual', branch: cfg.branch || 'main', status: 'pending', triggered_by: 'dashboard' });
  try {
    const result = await github.triggerDeploy(appId);
    db.updateDeployment(rec.lastInsertRowid, 'triggered', Date.now() - startedAt, 'Workflow dispatched');
    if (statusCache[appId]) statusCache[appId].cachedAt = 0;
    res.json({ ok: true, ...result });
  } catch (e) {
    db.updateDeployment(rec.lastInsertRowid, 'failed', Date.now() - startedAt, e.message);
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/apps/:appId/logs', auth, async (req, res) => {
  const { appId } = req.params;
  if (!db.getApp(appId)) return res.status(404).json({ error: 'Not found' });
  const lines = Math.min(parseInt(req.query.lines || '200', 10), 2000);
  try {
    const content = await ssh.getLogs(appId, lines);
    db.saveLogSnapshot(appId, 'web', content);
    res.json({ app: appId, content, timestamp: Date.now() });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/apps/:appId/github/runs', auth, async (req, res) => {
  if (!db.getApp(req.params.appId)) return res.status(404).json({ error: 'Not found' });
  try { res.json(await github.getWorkflowRuns(req.params.appId)); }
  catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/apps/:appId/github/branches', auth, async (req, res) => {
  if (!db.getApp(req.params.appId)) return res.status(404).json({ error: 'Not found' });
  try { res.json(await github.listBranches(req.params.appId)); }
  catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/deployments', auth, (req, res) => {
  const limit = Math.min(parseInt(req.query.limit || '50', 10), 200);
  const appId = req.query.app;
  res.json(appId ? db.getDeploymentsByApp(appId, limit) : db.getDeployments(limit));
});

app.get('/api/jobs', auth, (req, res) => {
  const active = Object.fromEntries(activeJobs);
  res.json({ active, recent: db.getAllJobRuns(100) });
});

app.post('/api/apps/:appId/kill', auth, (req, res) => {
  const job = activeJobs.get(req.params.appId);
  if (!job) return res.status(404).json({ error: 'No active job' });
  try { process.kill(job.pid, 'SIGTERM'); } catch {}
  res.json({ ok: true });
});

app.get('/api/metrics', auth, async (req, res) => {
  try {
    const apps = db.getApps().filter(a => a.enabled);
    const results = await Promise.all(apps.map(async (a) => ({
      app: a.id, name: a.name, type: a.type, ...(await ssh.getMetrics(a.id))
    })));
    res.json(results);
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/metrics/:appId', auth, async (req, res) => {
  if (!db.getApp(req.params.appId)) return res.status(404).json({ error: 'Not found' });
  try { res.json(await ssh.getMetrics(req.params.appId)); }
  catch (e) { res.status(500).json({ error: e.message }); }
});

app.get('/api/ssh-keys', auth, (req, res) => res.json(db.getSSHKeys()));

app.post('/api/ssh-keys', auth, (req, res) => {
  const { name, path: keyPath } = req.body;
  if (!name || !keyPath) return res.status(400).json({ error: 'name and path required' });
  if (!fs.existsSync(keyPath)) return res.status(400).json({ error: `File not found: ${keyPath}` });
  db.upsertSSHKey(name, keyPath, '');
  res.json({ ok: true, keys: db.getSSHKeys() });
});

app.delete('/api/ssh-keys/:id', auth, (req, res) => {
  db.deleteSSHKey(req.params.id);
  res.json({ ok: true });
});

app.get('/api/scripts', auth, (req, res) => {
  const fsScripts = [];
  try {
    fs.readdirSync(SCRIPTS_DIR).filter(f => f.endsWith('.sh') && !f.startsWith('.tmp-')).forEach(f => fsScripts.push(f));
  } catch {}
  const dbScripts = db.getScripts().map(s => s.name);
  const all = [...new Set([...fsScripts, ...dbScripts])].sort();
  res.json(all);
});

app.get('/api/scripts/:name', auth, (req, res) => {
  const name = path.basename(req.params.name);
  const fsPath = path.join(SCRIPTS_DIR, name);
  if (fs.existsSync(fsPath)) {
    return res.json({ name, content: fs.readFileSync(fsPath, 'utf8'), source: 'filesystem' });
  }
  const dbScript = db.getScript(name);
  if (dbScript) return res.json({ name, content: dbScript.content, source: 'database' });
  res.status(404).json({ error: 'Not found' });
});

app.put('/api/scripts/:name', auth, (req, res) => {
  const { content, save_to } = req.body;
  if (!content) return res.status(400).json({ error: 'content required' });
  const name = path.basename(req.params.name);
  const target = save_to || 'filesystem';
  if (target === 'database') {
    db.upsertScript(name, content, req.body.script_type || 'custom', req.body.app_id || null);
  } else {
    const scriptPath = path.join(SCRIPTS_DIR, name);
    fs.writeFileSync(scriptPath, content, 'utf8');
    fs.chmodSync(scriptPath, '755');
  }
  res.json({ ok: true });
});

app.post('/api/scripts', auth, (req, res) => {
  const { name, content, script_type, app_id } = req.body;
  if (!name || !content) return res.status(400).json({ error: 'name and content required' });
  const safeName = path.basename(name).replace(/[^a-zA-Z0-9._-]/g, '-');
  const scriptPath = path.join(SCRIPTS_DIR, safeName);
  fs.writeFileSync(scriptPath, content, 'utf8');
  fs.chmodSync(scriptPath, '755');
  if (script_type || app_id) db.upsertScript(safeName, content, script_type || 'custom', app_id || null);
  res.json({ ok: true, name: safeName });
});

app.delete('/api/scripts/:name', auth, (req, res) => {
  const name = path.basename(req.params.name);
  const fsPath = path.join(SCRIPTS_DIR, name);
  if (fs.existsSync(fsPath)) fs.unlinkSync(fsPath);
  db.deleteScript(name);
  res.json({ ok: true });
});

app.post('/api/webhook/deploy', (req, res) => {
  const { app: appId, status, message, commit } = req.body;
  if (!appId || !status) return res.status(400).json({ error: 'Missing app or status' });
  db.recordDeployment({ app: appId, commit, branch: 'auto', status, message, triggered_by: 'github' });
  if (statusCache[appId]) statusCache[appId].cachedAt = 0;
  broadcastSSE({ type: 'deploy_update', appId, status, message });
  res.json({ ok: true });
});

app.get('/api/events/stream', auth, (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.flushHeaders();
  sseClients.add(res);
  const heartbeat = setInterval(() => { try { res.write(': ping\n\n'); } catch {} }, 20000);
  req.on('close', () => { sseClients.delete(res); clearInterval(heartbeat); });
});

app.get('/api/health', (req, res) => res.json({ ok: true, uptime: process.uptime(), activeJobs: activeJobs.size }));

setInterval(async () => {
  try {
    const apps = db.getApps().filter(a => a.enabled);
    const results = await Promise.all(apps.map(a => getStatus(a.id)));
    const stats = db.getStats();
    stats.activeJobs = activeJobs.size;
    broadcastSSE({ type: 'status', apps: results.filter(Boolean), stats, timestamp: Date.now() });
  } catch {}
}, 30000);

app.listen(PORT, () => console.log(`TAP Dashboard on :${PORT}`));