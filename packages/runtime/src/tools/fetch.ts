/**
 * `fetch(url)`: a page as the text a model can actually read.
 *
 * The readability part is a heuristic, not a dependency. Chrome, boilerplate and markup are
 * the three things between the model and the article: scripts and styles are dropped with
 * their contents, nav / header / footer / aside / form are dropped as boilerplate, and when
 * the page marks its own content with `<article>` or `<main>` that subtree is all we keep.
 * Everything else is tags off, entities decoded, whitespace collapsed.
 *
 * See docs/spec-v1.html section 3.
 */

import type { Tool } from "../index.js";
import { MAX_OUTPUT, truncate } from "./shell.js";

/** A browser's, near enough: sites that block unknown agents would return a wall instead. */
const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) " +
  "Chrome/131.0.0.0 Safari/537.36";

const FETCH_TIMEOUT_MS = 30_000;

/** Elements whose *contents* are never prose. */
const DROP_WITH_CONTENT = ["script", "style", "noscript", "template", "svg", "head", "iframe"];

/** Elements that are the page's furniture rather than its article. */
const BOILERPLATE = ["nav", "header", "footer", "aside", "form"];

/** Tags that end a line when they close: without them the text runs into one paragraph. */
const BLOCK = /<\/?(p|div|br|li|tr|h[1-6]|section|article|main|blockquote|pre|ul|ol|table)\b[^>]*>/gi;

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  hellip: "…",
  mdash: "—",
  ndash: "–",
  rsquo: "’",
  lsquo: "‘",
  ldquo: "“",
  rdquo: "”",
};

export function decodeEntities(html: string): string {
  return html.replace(/&(#x?[0-9a-f]+|[a-z]+);/gi, (whole, body: string) => {
    if (body.startsWith("#")) {
      const code = body[1]?.toLowerCase() === "x"
        ? Number.parseInt(body.slice(2), 16)
        : Number.parseInt(body.slice(1), 10);
      return Number.isFinite(code) && code > 0 ? String.fromCodePoint(code) : whole;
    }
    return NAMED_ENTITIES[body.toLowerCase()] ?? whole;
  });
}

const dropElements = (html: string, tags: string[]): string =>
  tags.reduce(
    (text, tag) => text.replace(new RegExp(`<${tag}\\b[^>]*>[\\s\\S]*?</${tag}\\s*>`, "gi"), " "),
    html,
  );

export function extractTitle(html: string): string {
  const match = /<title[^>]*>([\s\S]*?)<\/title>/i.exec(html);
  return decodeEntities(match?.[1] ?? "").replace(/\s+/g, " ").trim();
}

/**
 * The page's main text. `<article>` or `<main>` is the page telling us where its content is,
 * and it is right often enough to be worth believing — but only when what it marks is
 * substantial, so a stub `<main>` wrapper cannot throw the article away.
 */
export function mainText(html: string): string {
  const stripped = dropElements(html, DROP_WITH_CONTENT);
  const marked = /<(article|main)\b[^>]*>([\s\S]*?)<\/\1\s*>/i.exec(stripped);
  const body = /<body\b[^>]*>([\s\S]*?)<\/body\s*>/i.exec(stripped)?.[1] ?? stripped;
  const chosen = marked && marked[2]!.length > body.length / 10 ? marked[2]! : body;

  return dropElements(chosen, BOILERPLATE)
    .replace(BLOCK, "\n")
    .replace(/<[^>]+>/g, " ")
    .split("\n")
    .map((line) => decodeEntities(line).replace(/[^\S\n]+/g, " ").trim())
    .filter(Boolean)
    .join("\n")
    .replace(/\n{3,}/g, "\n\n");
}

export interface Page {
  url: string;
  title: string;
  text: string;
}

/** GET, following redirects, as title plus main text. Non-HTML comes back as it arrived. */
export async function fetchReadable(url: string, max = MAX_OUTPUT): Promise<Page> {
  const response = await fetch(url, {
    redirect: "follow",
    headers: { "user-agent": USER_AGENT, accept: "text/html,application/xhtml+xml,*/*" },
    signal: AbortSignal.timeout(FETCH_TIMEOUT_MS),
  });
  const body = await response.text();
  if (!response.ok) {
    throw new Error(`fetch: ${url} → HTTP ${response.status} ${response.statusText}`.trim());
  }
  const html = (response.headers.get("content-type") ?? "").includes("html");
  return {
    // `response.url` is where the redirects ended, which is the URL worth citing.
    url: response.url || url,
    title: html ? extractTitle(body) : "",
    text: truncate(html ? mainText(body) : body.trim(), max),
  };
}

export const fetchTool: Tool = {
  name: "fetch",
  description:
    "Fetch a URL and return it as readable text: the page title and its main content, with " +
    "scripts, styles and navigation stripped. Use this to read a page, not browser.open.",
  parameters: {
    type: "object",
    properties: { url: { type: "string", description: "An http or https URL." } },
    required: ["url"],
  },
  run: async ({ url }) => {
    const target = String(url ?? "").trim();
    if (!/^https?:\/\//i.test(target)) throw new Error("fetch: url must be http or https");
    const page = await fetchReadable(target);
    const head = page.title ? `# ${page.title}\n${page.url}` : page.url;
    return `${head}\n\n${page.text || "(no readable text)"}`;
  },
};
