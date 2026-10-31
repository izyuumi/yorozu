// What each tool answers, as pure functions over the bundle. The MCP wiring is in server.ts.
import type { AppSetting, Content, HostSetting, Platform } from "./content.ts";

const stopwords = new Set(
  "a an and are as at be but by can do does doesn't don't for from has have how i if in is it its my not of on or so that the this to was what when where which why will with won't yorozu".split(" "),
);

export function terms(text: string): string[] {
  return [...new Set(text.toLowerCase().split(/[^\p{L}\p{N}_.-]+/u).map((t) => t.replace(/^[.-]+|[.-]+$/g, "")).filter((t) => t.length > 1 && !stopwords.has(t)))];
}

function count(haystack: string, term: string): number {
  let n = 0;
  for (let i = haystack.indexOf(term); i >= 0; i = haystack.indexOf(term, i + term.length)) n++;
  return n;
}

/** Heading hits weigh 5, body hits 1 (capped at 5 per term); matching every term doubles the score. */
function score(query: string[], heading: string, body: string): number {
  const h = heading.toLowerCase();
  const b = body.toLowerCase();
  let total = 0;
  let matched = 0;
  for (const term of query) {
    const hits = 5 * count(h, term) + Math.min(5, count(b, term));
    if (hits) matched++;
    total += hits;
  }
  return matched === query.length ? total * 2 : total;
}

function snippet(text: string, query: string[], width = 280): string {
  const lower = text.toLowerCase();
  const at = Math.min(...query.map((t) => lower.indexOf(t)).filter((i) => i >= 0), text.length);
  const start = Math.max(0, (at === text.length ? 0 : at) - 80);
  const cut = text.slice(start, start + width).replace(/\s+/g, " ").trim();
  return `${start > 0 ? "…" : ""}${cut}${start + width < text.length ? "…" : ""}`;
}

export interface DocHit {
  title: string;
  heading: string;
  uri: string;
  path: string;
  snippet: string;
  score: number;
}

export function searchDocs(content: Content, query: string, limit = 5): DocHit[] {
  const q = terms(query);
  if (!q.length) return [];
  return content.docs
    .flatMap((doc) =>
      doc.sections.map((s) => ({
        title: doc.title,
        heading: s.heading,
        uri: `${doc.uri}#${s.anchor}`,
        path: `${doc.path}#${s.anchor}`,
        snippet: snippet(s.text || s.heading, q),
        score: score(q, s.heading, s.text),
      })),
    )
    .filter((hit) => hit.score > 0)
    .sort((a, b) => b.score - a.score || a.uri.localeCompare(b.uri))
    .slice(0, limit);
}

export function formatDocHits(query: string, hits: DocHit[]): string {
  if (!hits.length) return `No docs match "${query}". Try other words, or read the resources yorozu://docs/setup and yorozu://docs/readme.`;
  return hits.map((h, i) => `${i + 1}. ${h.title} › ${h.heading}\n   ${h.uri} (${h.path})\n   ${h.snippet}`).join("\n\n");
}

export function setupGuide(content: Content, platform: Platform): string {
  const guide = content.guides[platform];
  const steps = guide.steps.map((step, i) => {
    const parts = [`## ${i + 1}. ${step.title}`, step.text];
    if (step.details) parts.push(step.details);
    if (step.doc) parts.push(`Source: ${step.doc}`);
    return parts.join("\n\n");
  });
  return [`# ${guide.title}`, ...steps, "If something fails, call troubleshoot with what the app or the command shows."].join("\n\n");
}

export function listSettings(content: Content, platform?: Platform) {
  const app = content.settings.app.filter((s) => !platform || s.platforms.includes(platform));
  return {
    app: app.map(({ key, title, platforms, location, type, default: value, options }) => ({ key, title, platforms, location, type, default: value, ...(options ? { options } : {}) })),
    host: content.settings.host.map(({ key, type, default: value, description }) => ({ key, type, default: value, description })),
    note: "App settings are changed in the app (location); host settings with `openclaw config set` on the computer that runs the OpenClaw Gateway. Call explain_setting for one key.",
  };
}

export function findSetting(content: Content, key: string): AppSetting | HostSetting | undefined {
  const k = key.trim().toLowerCase();
  const host = content.settings.host.find((s) => s.key.toLowerCase() === k || s.key.toLowerCase() === `channels.yorozu.${k}`);
  return host ?? content.settings.app.find((s) => s.key.toLowerCase() === k || s.title.toLowerCase() === k);
}

export function settingKeys(content: Content): string[] {
  return [...content.settings.app.map((s) => s.key), ...content.settings.host.map((s) => s.key)];
}

export interface TroubleHit {
  symptom: string;
  fix: string;
  source: string;
}

export function troubleshoot(content: Content, symptom: string, limit = 3): { matches: TroubleHit[]; docs: DocHit[] } {
  const q = terms(symptom);
  const matches = content.troubleshooting
    .map((entry) => ({ entry, score: q.length ? score(q, entry.symptom, entry.fix) : 0 }))
    .filter((m) => m.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, limit)
    .map((m) => m.entry);
  return { matches, docs: searchDocs(content, symptom, 3) };
}

export function formatTroubleshoot(symptom: string, result: { matches: TroubleHit[]; docs: DocHit[] }): string {
  const parts = result.matches.length
    ? result.matches.map((m, i) => `## ${i + 1}. ${m.symptom}\n\n${m.fix}\n\nSource: ${m.source}`)
    : [`No known problem matches "${symptom}". Ask for the exact text the app or the command shows.`];
  if (result.docs.length) parts.push(`## Related docs\n\n${formatDocHits(symptom, result.docs)}`);
  return parts.join("\n\n");
}

export function permissionsNeeded(content: Content, platform: Platform) {
  return {
    platform,
    permissions: content.permissions[platform],
    note: "usage: the system asks the first time the feature is used, with the prompt shown. entitlement: built into the signed app, nothing to grant. runtime: the app asks at the moment described.",
  };
}

export function latestVersion(content: Content) {
  const [latest] = content.releases;
  return {
    version: latest.version,
    notes: latest.text,
    source: "CHANGELOG.md",
    note: "The newest version in the repository's CHANGELOG.md when this server was built. The App Store or the Mac update feed can be a little behind.",
  };
}

export function changelog(content: Content, version?: string, limit = 3): string | undefined {
  const releases = version ? content.releases.filter((r) => r.version === version.replace(/^v/, "")) : content.releases.slice(0, limit);
  if (!releases.length) return undefined;
  return releases.map((r) => `## ${r.version}\n\n${r.text}`).join("\n\n");
}
