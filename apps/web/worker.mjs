const repository = 'izyuumi/yorozu';
const downloads = `https://github.com/${repository}/releases/download/`;
const candidateTag = /^candidate-((?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*))-([1-9]\d*)$/;

async function githubJSON(url) {
  const response = await fetch(url, {
    headers: { 'User-Agent': 'Yorozu-Updates', Accept: 'application/vnd.github+json' },
    cf: { cacheEverything: true, cacheTtlByStatus: { '200-299': 300, '400-599': 0 } },
  });
  if (!response.ok) throw new Error('GitHub unavailable');
  return response.json();
}

function compare(left, right) {
  const a = candidateTag.exec(left.tag_name);
  const b = candidateTag.exec(right.tag_name);
  const leftParts = [...a[1].split('.'), a[2]].map(BigInt);
  const rightParts = [...b[1].split('.'), b[2]].map(BigInt);
  for (let i = 0; i < leftParts.length; i++) {
    if (leftParts[i] !== rightParts[i]) return leftParts[i] > rightParts[i] ? -1 : 1;
  }
  return 0;
}

async function latestBeta() {
  const candidates = [];
  // ponytail: scan at most 2,000 releases; replace discovery with an index if exceeded.
  for (let page = 1; page <= 20; page++) {
    const releases = await githubJSON(`https://api.github.com/repos/${repository}/releases?per_page=100&page=${page}`);
    if (!Array.isArray(releases)) throw new Error('Invalid releases response');
    candidates.push(...releases.filter(release => release.draft === false && release.prerelease === true
      && candidateTag.test(release.tag_name) && release.name === `Yorozu Beta ${release.tag_name}`));
    if (releases.length < 100) break;
    if (page === 20) throw new Error('Release discovery limit reached');
  }
  const release = candidates.sort(compare)[0];
  if (!release) throw new Error('No beta candidate');
  const [, version, build] = candidateTag.exec(release.tag_name);
  const base = `${downloads}${release.tag_name}/`;
  for (const name of ['candidate.json', 'appcast.xml', 'yorozu.dmg']) {
    if (!release.assets?.some(asset => asset.name === name && asset.state === 'uploaded'
      && asset.browser_download_url === `${base}${name}`)) throw new Error('Incomplete candidate');
  }
  const manifest = await githubJSON(`${base}candidate.json`);
  if (manifest.schema !== 1 || manifest.source_branch !== 'main'
    || !/^[a-f0-9]{40}$/.test(manifest.source_sha) || manifest.tag !== release.tag_name
    || manifest.version !== version || manifest.build !== build || manifest.mac?.asset !== 'yorozu.dmg') {
    throw new Error('Invalid main candidate');
  }
  return base;
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (!['/beta', '/beta/', '/beta/appcast.xml'].includes(path)) return env.ASSETS.fetch(request);
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    try {
      const base = await latestBeta();
      return new Response(null, { status: 302, headers: {
        Location: `${base}${path.endsWith('appcast.xml') ? 'appcast.xml' : 'yorozu.dmg'}`,
        'Cache-Control': 'public, max-age=60',
      } });
    } catch {
      return new Response(request.method === 'HEAD' ? null : 'Beta updates temporarily unavailable. Please try again later.', {
        status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', 'Retry-After': '300' },
      });
    }
  },
};
