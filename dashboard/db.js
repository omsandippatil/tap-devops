const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');

const DATA_DIR = path.join(__dirname, 'data');
fs.mkdirSync(DATA_DIR, { recursive: true });

const db = new Database(path.join(DATA_DIR, 'dashboard.db'));
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS apps (
    app_id TEXT PRIMARY KEY,
    app_name TEXT NOT NULL,
    setup_script TEXT,
    server_user TEXT DEFAULT 'azureuser',
    server_host TEXT DEFAULT '',
    ssh_port INTEGER DEFAULT 22,
    ssh_key_path TEXT DEFAULT '',
    env_json TEXT DEFAULT '{}',
    flags_json TEXT DEFAULT '{}',
    parent_app_id TEXT DEFAULT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS ssh_keys (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    file_path TEXT NOT NULL,
    fingerprint TEXT,
    uploaded_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS deployments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id TEXT NOT NULL,
    status TEXT DEFAULT 'running',
    trigger TEXT DEFAULT 'manual',
    target_host TEXT,
    log TEXT DEFAULT '',
    exit_code INTEGER,
    started_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    finished_at DATETIME,
    FOREIGN KEY (app_id) REFERENCES apps(app_id) ON DELETE CASCADE
  );

  CREATE TABLE IF NOT EXISTS app_status (
    app_id TEXT PRIMARY KEY,
    status_json TEXT,
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
`);

const migrations = [`ALTER TABLE apps ADD COLUMN parent_app_id TEXT DEFAULT NULL`];
for (const migration of migrations) {
  try {
    db.exec(migration);
  } catch {}
}

function userCount() {
  return db.prepare('SELECT COUNT(*) as c FROM users').get().c;
}

function getUser(username) {
  return db.prepare('SELECT * FROM users WHERE username = ?').get(username);
}

function createUser(username, passwordHash) {
  return db
    .prepare('INSERT INTO users (username, password_hash) VALUES (?, ?)')
    .run(username, passwordHash);
}

function getApps() {
  return db
    .prepare(
      'SELECT * FROM apps ORDER BY parent_app_id IS NULL DESC, parent_app_id ASC, app_id ASC'
    )
    .all();
}

function getApp(appId) {
  return db.prepare('SELECT * FROM apps WHERE app_id = ?').get(appId);
}

function createApp(a) {
  return db
    .prepare(
      `INSERT INTO apps (app_id, app_name, setup_script, server_user, server_host, ssh_port, ssh_key_path, env_json, flags_json, parent_app_id)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
    )
    .run(
      a.app_id,
      a.app_name,
      a.setup_script,
      a.server_user,
      a.server_host,
      a.ssh_port,
      a.ssh_key_path,
      a.env_json,
      a.flags_json,
      a.parent_app_id || null
    );
}

function upsertApp(a) {
  return db
    .prepare(
      `INSERT INTO apps (app_id, app_name, setup_script, server_user, server_host, ssh_port, ssh_key_path, env_json, flags_json, parent_app_id)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(app_id) DO UPDATE SET
      app_name = excluded.app_name,
      setup_script = excluded.setup_script,
      server_user = excluded.server_user,
      server_host = excluded.server_host,
      ssh_port = excluded.ssh_port,
      ssh_key_path = excluded.ssh_key_path,
      env_json = excluded.env_json,
      flags_json = excluded.flags_json,
      parent_app_id = excluded.parent_app_id`
    )
    .run(
      a.app_id,
      a.app_name,
      a.setup_script,
      a.server_user,
      a.server_host,
      a.ssh_port,
      a.ssh_key_path,
      a.env_json,
      a.flags_json,
      a.parent_app_id || null
    );
}

function deleteApp(appId) {
  return db.prepare('DELETE FROM apps WHERE app_id = ?').run(appId);
}

function getKeys() {
  return db.prepare('SELECT * FROM ssh_keys ORDER BY uploaded_at DESC').all();
}

function getKey(id) {
  return db.prepare('SELECT * FROM ssh_keys WHERE id = ?').get(id);
}

function saveKey(name, filePath, fingerprint) {
  return db
    .prepare(
      `INSERT INTO ssh_keys (name, file_path, fingerprint)
    VALUES (?, ?, ?)
    ON CONFLICT(name) DO UPDATE SET file_path = excluded.file_path, fingerprint = excluded.fingerprint`
    )
    .run(name, filePath, fingerprint);
}

function deleteKey(id) {
  return db.prepare('DELETE FROM ssh_keys WHERE id = ?').run(id);
}

function startDeployment(appId, trigger, targetHost) {
  const result = db
    .prepare(
      `INSERT INTO deployments (app_id, status, trigger, target_host, log)
    VALUES (?, 'running', ?, ?, '')`
    )
    .run(appId, trigger, targetHost);
  return result.lastInsertRowid;
}

function updateDeploymentLog(id, log) {
  db.prepare('UPDATE deployments SET log = ? WHERE id = ?').run(log, id);
}

function finishDeployment(id, status, exitCode) {
  db.prepare(
    `UPDATE deployments SET status = ?, exit_code = ?, finished_at = CURRENT_TIMESTAMP WHERE id = ?`
  ).run(status, exitCode, id);
}

function getDeployment(id) {
  return db
    .prepare(
      `SELECT d.*, a.app_name FROM deployments d
    LEFT JOIN apps a ON d.app_id = a.app_id
    WHERE d.id = ?`
    )
    .get(id);
}

function getDeployments(appId, limit = 30) {
  return db
    .prepare(
      `SELECT d.*, a.app_name FROM deployments d
    LEFT JOIN apps a ON d.app_id = a.app_id
    WHERE d.app_id = ?
    ORDER BY d.started_at DESC LIMIT ?`
    )
    .all(appId, limit);
}

function getRecentDeployments(limit = 30) {
  return db
    .prepare(
      `SELECT d.*, a.app_name FROM deployments d
    LEFT JOIN apps a ON d.app_id = a.app_id
    ORDER BY d.started_at DESC LIMIT ?`
    )
    .all(limit);
}

function setStatus(appId, statusObj) {
  db.prepare(
    `INSERT INTO app_status (app_id, status_json, updated_at)
    VALUES (?, ?, CURRENT_TIMESTAMP)
    ON CONFLICT(app_id) DO UPDATE SET status_json = excluded.status_json, updated_at = CURRENT_TIMESTAMP`
  ).run(appId, JSON.stringify(statusObj));
}

function getStatus(appId) {
  const row = db.prepare('SELECT status_json FROM app_status WHERE app_id = ?').get(appId);
  if (!row) return null;
  try {
    return JSON.parse(row.status_json);
  } catch {
    return null;
  }
}

module.exports = {
  userCount,
  getUser,
  createUser,
  getApps,
  getApp,
  createApp,
  upsertApp,
  deleteApp,
  getKeys,
  getKey,
  saveKey,
  deleteKey,
  startDeployment,
  updateDeploymentLog,
  finishDeployment,
  getDeployment,
  getDeployments,
  getRecentDeployments,
  setStatus,
  getStatus,
};