const Database = require('better-sqlite3');
const path = require('path');

const dbPath = process.env.DB_PATH || path.join(__dirname, 'deploy.db');
const db = new Database(dbPath);

db.exec(`CREATE TABLE IF NOT EXISTS apps (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  type TEXT NOT NULL,
  enabled INTEGER DEFAULT 1,
  config TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
)`);

db.exec(`CREATE TABLE IF NOT EXISTS credentials (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  app_id TEXT NOT NULL,
  key_name TEXT NOT NULL,
  value TEXT NOT NULL,
  is_secret INTEGER DEFAULT 0,
  updated_at INTEGER NOT NULL,
  UNIQUE(app_id, key_name)
)`);

db.exec(`CREATE TABLE IF NOT EXISTS deployments (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  app TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  commit_hash TEXT,
  branch TEXT,
  status TEXT NOT NULL,
  duration INTEGER,
  triggered_by TEXT,
  message TEXT,
  log TEXT
)`);

db.exec(`CREATE TABLE IF NOT EXISTS job_runs (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  app TEXT NOT NULL,
  job_type TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  status TEXT NOT NULL,
  log TEXT,
  pid INTEGER,
  duration INTEGER
)`);

db.exec(`CREATE TABLE IF NOT EXISTS log_snapshots (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  app TEXT NOT NULL,
  timestamp INTEGER NOT NULL,
  log_type TEXT,
  content TEXT
)`);

db.exec(`CREATE TABLE IF NOT EXISTS ssh_keys (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  path TEXT NOT NULL,
  fingerprint TEXT,
  created_at INTEGER NOT NULL
)`);

db.exec(`CREATE TABLE IF NOT EXISTS scripts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL UNIQUE,
  content TEXT NOT NULL,
  script_type TEXT DEFAULT 'custom',
  app_id TEXT,
  updated_at INTEGER NOT NULL
)`);

try {
  db.exec(`ALTER TABLE apps ADD COLUMN tags TEXT DEFAULT '[]'`);
} catch {}
try {
  db.exec(`ALTER TABLE job_runs ADD COLUMN triggered_by TEXT DEFAULT 'dashboard'`);
} catch {}

const retentionDays = parseInt(process.env.LOG_RETENTION_DAYS || '7', 10);
db.prepare('DELETE FROM log_snapshots WHERE timestamp < ?').run(Date.now() - retentionDays * 86400 * 1000);

module.exports = {
  getApps() {
    return db.prepare('SELECT * FROM apps ORDER BY created_at ASC').all().map(r => ({
      ...r, config: JSON.parse(r.config), tags: JSON.parse(r.tags || '[]')
    }));
  },
  getApp(id) {
    const r = db.prepare('SELECT * FROM apps WHERE id = ?').get(id);
    return r ? { ...r, config: JSON.parse(r.config), tags: JSON.parse(r.tags || '[]') } : null;
  },
  upsertApp(id, name, type, config, tags = []) {
    const now = Date.now();
    const exists = db.prepare('SELECT id FROM apps WHERE id = ?').get(id);
    if (exists) {
      db.prepare('UPDATE apps SET name=?, type=?, config=?, tags=?, updated_at=? WHERE id=?')
        .run(name, type, JSON.stringify(config), JSON.stringify(tags), now, id);
    } else {
      db.prepare('INSERT INTO apps (id,name,type,enabled,config,tags,created_at,updated_at) VALUES (?,?,?,1,?,?,?,?)')
        .run(id, name, type, JSON.stringify(config), JSON.stringify(tags), now, now);
    }
    return db.prepare('SELECT * FROM apps WHERE id=?').get(id);
  },
  deleteApp(id) {
    db.prepare('DELETE FROM apps WHERE id=?').run(id);
    db.prepare('DELETE FROM credentials WHERE app_id=?').run(id);
  },
  toggleApp(id, enabled) {
    db.prepare('UPDATE apps SET enabled=?, updated_at=? WHERE id=?').run(enabled ? 1 : 0, Date.now(), id);
  },
  getCredentials(appId) {
    return db.prepare('SELECT * FROM credentials WHERE app_id=? ORDER BY key_name ASC').all(appId);
  },
  setCredential(appId, keyName, value, isSecret = 0) {
    db.prepare(`INSERT INTO credentials (app_id,key_name,value,is_secret,updated_at) VALUES (?,?,?,?,?)
      ON CONFLICT(app_id,key_name) DO UPDATE SET value=excluded.value,is_secret=excluded.is_secret,updated_at=excluded.updated_at`)
      .run(appId, keyName, value, isSecret ? 1 : 0, Date.now());
  },
  deleteCredential(appId, keyName) {
    db.prepare('DELETE FROM credentials WHERE app_id=? AND key_name=?').run(appId, keyName);
  },
  getCredentialMap(appId) {
    return Object.fromEntries(
      db.prepare('SELECT key_name, value FROM credentials WHERE app_id=?').all(appId).map(r => [r.key_name, r.value])
    );
  },
  upsertSSHKey(name, filePath, fingerprint) {
    const existing = db.prepare('SELECT id FROM ssh_keys WHERE name=?').get(name);
    if (existing) {
      db.prepare('UPDATE ssh_keys SET path=?, fingerprint=? WHERE name=?').run(filePath, fingerprint, name);
    } else {
      db.prepare('INSERT INTO ssh_keys (name,path,fingerprint,created_at) VALUES (?,?,?,?)').run(name, filePath, fingerprint, Date.now());
    }
  },
  getSSHKeys() {
    return db.prepare('SELECT * FROM ssh_keys ORDER BY created_at DESC').all();
  },
  deleteSSHKey(id) {
    db.prepare('DELETE FROM ssh_keys WHERE id=?').run(id);
  },
  recordDeployment(data) {
    return db.prepare(`INSERT INTO deployments (app,timestamp,commit_hash,branch,status,duration,triggered_by,message)
      VALUES (?,?,?,?,?,?,?,?)`)
      .run(data.app, Date.now(), data.commit, data.branch, data.status, data.duration || null, data.triggered_by || 'dashboard', data.message || '');
  },
  updateDeployment(id, status, duration, message, log) {
    db.prepare('UPDATE deployments SET status=?,duration=?,message=?,log=? WHERE id=?').run(status, duration, message, log || null, id);
  },
  getDeployments(limit = 50) {
    return db.prepare('SELECT * FROM deployments ORDER BY timestamp DESC LIMIT ?').all(limit);
  },
  getDeploymentsByApp(app, limit = 20) {
    return db.prepare('SELECT * FROM deployments WHERE app=? ORDER BY timestamp DESC LIMIT ?').all(app, limit);
  },
  startJobRun(app, jobType, pid, triggeredBy = 'dashboard') {
    return db.prepare('INSERT INTO job_runs (app,job_type,timestamp,status,pid,triggered_by) VALUES (?,?,?,?,?,?)')
      .run(app, jobType, Date.now(), 'running', pid || null, triggeredBy);
  },
  finishJobRun(id, status, log, duration) {
    db.prepare('UPDATE job_runs SET status=?,log=?,duration=? WHERE id=?').run(status, log || '', duration, id);
  },
  getJobRuns(app, limit = 20) {
    return db.prepare('SELECT * FROM job_runs WHERE app=? ORDER BY timestamp DESC LIMIT ?').all(app, limit);
  },
  getAllJobRuns(limit = 100) {
    return db.prepare('SELECT * FROM job_runs ORDER BY timestamp DESC LIMIT ?').all(limit);
  },
  saveLogSnapshot(app, logType, content) {
    db.prepare('INSERT INTO log_snapshots (app,timestamp,log_type,content) VALUES (?,?,?,?)').run(app, Date.now(), logType, content);
  },
  getLogSnapshot(app, logType) {
    return db.prepare('SELECT * FROM log_snapshots WHERE app=? AND log_type=? ORDER BY timestamp DESC LIMIT 1').get(app, logType);
  },
  getScripts() {
    return db.prepare('SELECT id, name, script_type, app_id, updated_at FROM scripts ORDER BY name ASC').all();
  },
  getScript(name) {
    return db.prepare('SELECT * FROM scripts WHERE name=?').get(name);
  },
  upsertScript(name, content, scriptType = 'custom', appId = null) {
    const existing = db.prepare('SELECT id FROM scripts WHERE name=?').get(name);
    if (existing) {
      db.prepare('UPDATE scripts SET content=?, script_type=?, app_id=?, updated_at=? WHERE name=?')
        .run(content, scriptType, appId, Date.now(), name);
    } else {
      db.prepare('INSERT INTO scripts (name, content, script_type, app_id, updated_at) VALUES (?,?,?,?,?)')
        .run(name, content, scriptType, appId, Date.now());
    }
  },
  deleteScript(name) {
    db.prepare('DELETE FROM scripts WHERE name=?').run(name);
  },
  getStats() {
    return {
      totalDeployments: db.prepare('SELECT COUNT(*) as c FROM deployments').get().c,
      successRate: db.prepare("SELECT ROUND(100.0*SUM(CASE WHEN status='success' THEN 1 ELSE 0 END)/MAX(COUNT(*),1),1) as r FROM deployments").get().r,
      last24h: db.prepare('SELECT COUNT(*) as c FROM deployments WHERE timestamp > ?').get(Date.now() - 86400000).c,
      totalApps: db.prepare('SELECT COUNT(*) as c FROM apps WHERE enabled=1').get().c,
      activeJobs: 0,
    };
  }
};