const axios = require('axios');
const db = require('./db');

function ghClient() {
  const token = process.env.GITHUB_TOKEN;
  return axios.create({
    baseURL: 'https://api.github.com',
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      Accept: 'application/vnd.github+json',
      'X-GitHub-Api-Version': '2022-11-28',
    },
    timeout: 15000,
  });
}

function parseRepo(url) {
  if (!url) return null;
  const m = url.match(/github\.com[/:]([^/]+)\/([^/.]+)/);
  return m ? { owner: m[1], repo: m[2] } : null;
}

async function triggerDeploy(appId) {
  const app = db.getApp(appId);
  if (!app) throw new Error(`Unknown app: ${appId}`);
  const cfg = app.config;
  const r = parseRepo(cfg.repo);
  if (!r) throw new Error(`No GitHub repo configured for ${appId}`);
  const gh = ghClient();
  const branch = cfg.branch || 'main';
  await gh.post(`/repos/${r.owner}/${r.repo}/dispatches`, {
    event_type: cfg.dispatch_event || 'manual-deploy',
    client_payload: { branch, triggered_by: 'dashboard', app: appId },
  });
  return { dispatched: true, repo: `${r.owner}/${r.repo}`, branch };
}

async function getLatestCommit(appId) {
  const app = db.getApp(appId);
  if (!app) return null;
  const cfg = app.config;
  const r = parseRepo(cfg.repo);
  if (!r) return null;
  try {
    const gh = ghClient();
    const branch = cfg.branch || 'main';
    const { data } = await gh.get(`/repos/${r.owner}/${r.repo}/commits/${branch}`);
    return {
      sha: data.sha.slice(0, 7),
      message: data.commit.message.split('\n')[0].slice(0, 80),
      author: data.commit.author.name,
      date: data.commit.author.date,
    };
  } catch {
    return null;
  }
}

async function getWorkflowRuns(appId) {
  const app = db.getApp(appId);
  if (!app) return [];
  const cfg = app.config;
  const r = parseRepo(cfg.repo);
  if (!r) return [];
  try {
    const gh = ghClient();
    const { data } = await gh.get(`/repos/${r.owner}/${r.repo}/actions/runs?per_page=10`);
    return data.workflow_runs.map(run => ({
      id: run.id,
      name: run.name,
      status: run.status,
      conclusion: run.conclusion,
      sha: run.head_sha.slice(0, 7),
      branch: run.head_branch,
      created_at: run.created_at,
      html_url: run.html_url,
    }));
  } catch {
    return [];
  }
}

async function listBranches(appId) {
  const app = db.getApp(appId);
  if (!app) return [];
  const cfg = app.config;
  const r = parseRepo(cfg.repo);
  if (!r) return [];
  try {
    const gh = ghClient();
    const { data } = await gh.get(`/repos/${r.owner}/${r.repo}/branches?per_page=30`);
    return data.map(b => b.name);
  } catch {
    return [];
  }
}

module.exports = { triggerDeploy, getLatestCommit, getWorkflowRuns, parseRepo, listBranches };