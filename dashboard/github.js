const https = require('https');

function githubGet(url, token) {
  return new Promise((resolve, reject) => {
    const opts = {
      headers: {
        'User-Agent': 'tap-devops-dashboard/1.0',
        'Accept': 'application/vnd.github.v3+json',
        ...(token ? { Authorization: `token ${token}` } : {}),
      },
    };
    https
      .get(url, opts, (res) => {
        let data = '';
        res.on('data', (d) => (data += d));
        res.on('end', () => {
          try {
            resolve(JSON.parse(data));
          } catch (e) {
            reject(e);
          }
        });
      })
      .on('error', reject);
  });
}

function extractRepoPath(repoUrl) {
  const m = repoUrl.match(/github\.com[:/]([^/]+\/[^/]+?)(?:\.git)?$/);
  return m ? m[1] : null;
}

async function getBranchInfo(repoUrl, branch, token) {
  const repoPath = extractRepoPath(repoUrl);
  if (!repoPath) return null;
  try {
    const data = await githubGet(
      `https://api.github.com/repos/${repoPath}/branches/${encodeURIComponent(branch)}`,
      token
    );
    if (!data || !data.commit) return null;
    return {
      branch,
      sha: data.commit.sha,
      sha_short: data.commit.sha.substring(0, 7),
      message: data.commit.commit?.message?.split('\n')[0] || '',
      author: data.commit.commit?.author?.name || '',
      date: data.commit.commit?.author?.date || '',
      url: `https://github.com/${repoPath}/tree/${branch}`,
    };
  } catch {
    return null;
  }
}

async function getAllBranches(repoUrl, token) {
  const repoPath = extractRepoPath(repoUrl);
  if (!repoPath) return [];
  try {
    const data = await githubGet(
      `https://api.github.com/repos/${repoPath}/branches?per_page=100`,
      token
    );
    if (!Array.isArray(data)) return [];
    return data.map((b) => ({
      name: b.name,
      sha_short: b.commit?.sha?.substring(0, 7) || '',
    }));
  } catch {
    return [];
  }
}

async function getRecentCommits(repoUrl, branch, token, limit = 5) {
  const repoPath = extractRepoPath(repoUrl);
  if (!repoPath) return [];
  try {
    const data = await githubGet(
      `https://api.github.com/repos/${repoPath}/commits?sha=${encodeURIComponent(branch)}&per_page=${limit}`,
      token
    );
    if (!Array.isArray(data)) return [];
    return data.map((c) => ({
      sha: c.sha?.substring(0, 7),
      message: c.commit?.message?.split('\n')[0] || '',
      author: c.commit?.author?.name || '',
      date: c.commit?.author?.date || '',
    }));
  } catch {
    return [];
  }
}

module.exports = { getBranchInfo, getAllBranches, getRecentCommits, extractRepoPath };