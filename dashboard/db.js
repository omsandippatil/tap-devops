const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'data', 'dashboard.db');
fs.mkdirSync(path.dirname(DB_PATH), { recursive: true });

const db = new Database(DB_PATH);
db.pragma('journal_mode = WAL');
db.pragma('foreign_keys = ON');

db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS app_configs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id TEXT UNIQUE NOT NULL,
    app_name TEXT NOT NULL,
    setup_script TEXT NOT NULL DEFAULT '',
    server_user TEXT NOT NULL DEFAULT 'azureuser',
    server_host TEXT NOT NULL DEFAULT '',
    ssh_port INTEGER NOT NULL DEFAULT 22,
    ssh_key_path TEXT NOT NULL DEFAULT '',
    env_json TEXT NOT NULL DEFAULT '{}',
    flags_json TEXT NOT NULL DEFAULT '{}',
    last_updated DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS deployments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    app_id TEXT NOT NULL,
    trigger TEXT NOT NULL DEFAULT 'manual',
    status TEXT NOT NULL DEFAULT 'pending',
    started_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    finished_at DATETIME,
    log TEXT NOT NULL DEFAULT '',
    exit_code INTEGER
  );

  CREATE TABLE IF NOT EXISTS ssh_keys (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT UNIQUE NOT NULL,
    file_path TEXT NOT NULL,
    fingerprint TEXT,
    uploaded_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );

  CREATE TABLE IF NOT EXISTS app_status_cache (
    app_id TEXT PRIMARY KEY,
    status_json TEXT NOT NULL DEFAULT '{}',
    updated_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
`);

const seedApps = JSON.parse(process.env.SEED_APPS || 'null') || [
  {
    app_id: 'plg',
    app_name: 'PLG — Plagiarism Detection',
    setup_script: '~/tap-devops/setup/setup-plg.sh',
    server_host: '',
    ssh_key_path: '',
    env_json: JSON.stringify({
      PLG_GIT_BRANCH: 'plg_integration',
      PLG_API_PORT: '8006',
      PLG_FRAPPE_WEB_PORT: '8080',
      PLG_POSTGRES_USER: 'postgres',
      PLG_POSTGRES_PASSWORD: 'postgres',
      PLG_POSTGRES_DB: 'plagiarism_db',
      PLG_POSTGRES_PORT: '5432',
      PLG_RABBITMQ_USER: 'guest',
      PLG_RABBITMQ_PASS: 'guest',
      PLG_FRAPPE_ADMIN_PASSWORD: 'Admin@1234',
      PLG_FRAPPE_SITE_NAME: 'plagiarism.localhost',
      PLG_CLIP_DEVICE: 'cpu',
      PLG_LOG_LEVEL: 'INFO',
      PLG_MOCK_GLIFIC: 'true',
      PLG_SETUP_SYSTEMD: 'true',
      PLG_ENABLE_LINGER: 'true',
      PLG_OPEN_FIREWALL_PORT: 'true',
      PLG_DOWNLOAD_CLIP_MODEL: 'true',
    }),
    flags_json: JSON.stringify({
      '--skip-model': false,
      '--force': true,
      '--no-wait': false,
      '--parallel-pull': false,
      '--verbose': false,
    }),
  },
  {
    app_id: 'lms',
    app_name: 'LMS — Learning Management',
    setup_script: '~/tap-devops/setup/setup-lms.sh',
    server_host: '',
    ssh_key_path: '',
    env_json: JSON.stringify({
      LMS_GIT_BRANCH: 'main',
      LMS_API_PORT: '8007',
      LMS_WEB_PORT: '8081',
      LMS_POSTGRES_USER: 'postgres',
      LMS_POSTGRES_PASSWORD: 'postgres',
      LMS_POSTGRES_DB: 'lms_db',
      LMS_POSTGRES_PORT: '5433',
      LMS_ADMIN_PASSWORD: 'Admin@1234',
      LMS_SETUP_SYSTEMD: 'true',
      LMS_ENABLE_LINGER: 'true',
    }),
    flags_json: JSON.stringify({
      '--force': true,
      '--no-wait': false,
      '--verbose': false,
    }),
  },
  {
    app_id: 'rag',
    app_name: 'RAG — Retrieval Augmented Gen',
    setup_script: '~/tap-devops/setup/setup-rag.sh',
    server_host: '',
    ssh_key_path: '',
    env_json: JSON.stringify({
      RAG_GIT_BRANCH: 'main',
      RAG_API_PORT: '8008',
      RAG_WEB_PORT: '8082',
      RAG_POSTGRES_USER: 'postgres',
      RAG_POSTGRES_PASSWORD: 'postgres',
      RAG_POSTGRES_DB: 'rag_db',
      RAG_POSTGRES_PORT: '5434',
      RAG_ADMIN_PASSWORD: 'Admin@1234',
      RAG_SETUP_SYSTEMD: 'true',
      RAG_ENABLE_LINGER: 'true',
    }),
    flags_json: JSON.stringify({
      '--force': true,
      '--no-wait': false,
      '--verbose': false,
    }),
  },
];

const insertApp = db.prepare(`
  INSERT OR IGNORE INTO app_configs
    (app_id, app_name, setup_script, server_host, ssh_key_path, env_json, flags_json)
  VALUES
    (@app_id, @app_name, @setup_script, @server_host, @ssh_key_path, @env_json, @flags_json)
`);
for (const app of seedApps) {
  insertApp.run({
    ...app,
    flags_json: app.flags_json || '{}',
  });
}

module.exports = {
  db,

  getUser: (username) => db.prepare('SELECT * FROM users WHERE username = ?').get(username),
  createUser: (username, hash) =>
    db.prepare('INSERT INTO users (username, password_hash) VALUES (?, ?)').run(username, hash),
  userCount: () => db.prepare('SELECT COUNT(*) as c FROM users').get().c,

  getApps: () => db.prepare('SELECT * FROM app_configs ORDER BY app_id').all(),
  getApp: (app_id) => db.prepare('SELECT * FROM app_configs WHERE app_id = ?').get(app_id),
  upsertApp: (data) => db.prepare(`
    INSERT INTO app_configs
      (app_id, app_name, setup_script, server_user, server_host, ssh_port, ssh_key_path, env_json, flags_json, last_updated)
    VALUES
      (@app_id, @app_name, @setup_script, @server_user, @server_host, @ssh_port, @ssh_key_path, @env_json, @flags_json, CURRENT_TIMESTAMP)
    ON CONFLICT(app_id) DO UPDATE SET
      app_name=excluded.app_name,
      setup_script=excluded.setup_script,
      server_user=excluded.server_user,
      server_host=excluded.server_host,
      ssh_port=excluded.ssh_port,
      ssh_key_path=excluded.ssh_key_path,
      env_json=excluded.env_json,
      flags_json=excluded.flags_json,
      last_updated=CURRENT_TIMESTAMP
  `).run(data),

  startDeployment: (app_id, trigger = 'manual') =>
    db.prepare('INSERT INTO deployments (app_id, trigger, status) VALUES (?, ?, ?)').run(app_id, trigger, 'running').lastInsertRowid,
  updateDeploymentLog: (id, log) =>
    db.prepare('UPDATE deployments SET log = ? WHERE id = ?').run(log, id),
  finishDeployment: (id, status, exit_code) =>
    db.prepare('UPDATE deployments SET status=?, exit_code=?, finished_at=CURRENT_TIMESTAMP WHERE id=?').run(status, exit_code, id),
  getDeployments: (app_id, limit = 20) =>
    db.prepare('SELECT * FROM deployments WHERE app_id = ? ORDER BY started_at DESC LIMIT ?').all(app_id, limit),
  getDeployment: (id) => db.prepare('SELECT * FROM deployments WHERE id = ?').get(id),
  getRecentDeployments: (limit = 10) =>
    db.prepare('SELECT d.*, a.app_name FROM deployments d JOIN app_configs a ON d.app_id=a.app_id ORDER BY d.started_at DESC LIMIT ?').all(limit),

  getKeys: () => db.prepare('SELECT * FROM ssh_keys ORDER BY uploaded_at DESC').all(),
  saveKey: (name, file_path, fingerprint) =>
    db.prepare('INSERT OR REPLACE INTO ssh_keys (name, file_path, fingerprint) VALUES (?, ?, ?)').run(name, file_path, fingerprint),
  deleteKey: (id) => db.prepare('DELETE FROM ssh_keys WHERE id = ?').run(id),
  getKey: (id) => db.prepare('SELECT * FROM ssh_keys WHERE id = ?').get(id),

  setStatus: (app_id, status_json) =>
    db.prepare('INSERT OR REPLACE INTO app_status_cache (app_id, status_json, updated_at) VALUES (?, ?, CURRENT_TIMESTAMP)').run(app_id, JSON.stringify(status_json)),
  getStatus: (app_id) => {
    const row = db.prepare('SELECT * FROM app_status_cache WHERE app_id = ?').get(app_id);
    return row ? JSON.parse(row.status_json) : null;
  },
};