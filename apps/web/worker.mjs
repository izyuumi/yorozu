// The Mac downloads and update feeds, all from the latest GitHub release (v<version>): /mac and /beta give its
// installer, /beta/appcast.xml its appcast. /beta stays because 0.5 Macs with beta updates on read that feed;
// /appcast.xml redirects to the same release in _redirects.
const repository = 'izyuumi/yorozu';
const downloads = `https://github.com/${repository}/releases/download/`;

async function latestRelease() {
  const response = await fetch(`https://api.github.com/repos/${repository}/releases/latest`, {
    headers: { 'User-Agent': 'Yorozu-Updates', Accept: 'application/vnd.github+json' },
    cf: { cacheEverything: true, cacheTtlByStatus: { '200-299': 300, '400-599': 0 } },
  });
  if (!response.ok) throw new Error('GitHub unavailable');
  return response.json();
}

/** The URL of one of the latest release's assets, only ever inside this repository's downloads. */
async function latestAsset(names) {
  const release = await latestRelease();
  const base = `${downloads}${release.tag_name}/`;
  for (const name of names) {
    if (release.assets?.some(asset => asset.name === name && asset.state === 'uploaded'
      && asset.browser_download_url === `${base}${name}`)) return `${base}${name}`;
  }
  throw new Error('Release asset unavailable');
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (!['/mac', '/beta', '/beta/', '/beta/appcast.xml'].includes(path)) return env.ASSETS.fetch(request);
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    try {
      const location = await latestAsset(path.endsWith('appcast.xml') ? ['appcast.xml'] : ['Yorozu.dmg', 'yorozu.dmg']);
      return new Response(null, { status: 302, headers: { Location: location, 'Cache-Control': 'public, max-age=60' } });
    } catch {
      return new Response(request.method === 'HEAD' ? null : 'Downloads temporarily unavailable. Please try again later.', {
        status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', 'Retry-After': '300' },
      });
    }
  },
};
