/**
 * `web_search(query)`. The spec asks for provider-native search when the active provider has
 * it, and a Chromium fallback otherwise, so `Provider.search` is an optional capability:
 * a provider that can search implements it, and the runtime drives DuckDuckGo's HTML
 * endpoint through the agent's own browser when none does.
 *
 * Native search is a capability, not a guarantee — a provider can have one and still fail on
 * it — so a failing native search falls through to the browser rather than ending the turn.
 * See docs/spec-v1.html section 3.
 */

import type { Tool } from "../index.js";
import type { Provider } from "../provider.js";
import { browser, type Browser } from "./browser.js";
import { decodeEntities } from "./fetch.js";
import { truncate } from "./shell.js";

/** The no-JavaScript endpoint: server-rendered results, so one snapshot has everything. */
export const DUCKDUCKGO = "https://duckduckgo.com/html/?q=";

export const TOP_N = 8;

export interface SearchResult {
  title: string;
  url: string;
  snippet?: string;
}

const plain = (html: string): string =>
  decodeEntities(html.replace(/<[^>]+>/g, "")).replace(/\s+/g, " ").trim();

/**
 * DuckDuckGo wraps each result in its own redirector, with the real target in `uddg`.
 * The model is going to be shown these URLs and may fetch one, so they are unwrapped here.
 */
export function resolveResultUrl(href: string): string {
  const decoded = decodeEntities(href);
  const wrapped = /[?&]uddg=([^&]+)/.exec(decoded);
  let url = decoded;
  if (wrapped) {
    try {
      url = decodeURIComponent(wrapped[1]!);
    } catch {
      // A malformed escape is not worth losing the result over: keep the wrapper.
    }
  }
  return url.startsWith("//") ? `https:${url}` : url;
}

export function parseDuckDuckGo(html: string, limit = TOP_N): SearchResult[] {
  const snippets = [...html.matchAll(/class="[^"]*result__snippet[^"]*"[^>]*>([\s\S]*?)<\/a>/gi)]
    .map((match) => plain(match[1]!));

  const results: SearchResult[] = [];
  const anchors = html.matchAll(
    /<a\b([^>]*class="[^"]*result__a[^"]*"[^>]*)>([\s\S]*?)<\/a>/gi,
  );
  for (const [, attributes, inner] of anchors) {
    const href = /href="([^"]*)"/i.exec(attributes!)?.[1];
    const title = plain(inner!);
    if (!href || !title) continue;
    const snippet = snippets[results.length];
    results.push({
      title,
      url: resolveResultUrl(href),
      ...(snippet ? { snippet } : {}),
    });
    if (results.length >= limit) break;
  }
  return results;
}

/**
 * The fallback: the agent's own browser profile, one tab, closed again whichever way this
 * goes — the spec's "never touches the user's tabs, closes what it opens".
 */
export async function searchWeb(
  query: string,
  limit = TOP_N,
  driver: Browser = browser(),
): Promise<SearchResult[]> {
  const tabId = await driver.open(DUCKDUCKGO + encodeURIComponent(query));
  try {
    const html = String(await driver.evaluate(tabId, "document.documentElement.outerHTML"));
    return parseDuckDuckGo(html, limit);
  } finally {
    await driver.close(tabId).catch(() => {});
  }
}

/**
 * The provider chain the sidecar is running, published here so `web_search` can ask it for
 * native search. A tool only receives its thread and agent, and threading a provider through
 * every call to give one tool a capability would cost every other tool a parameter.
 */
let active: Provider | undefined;

export const useProviderSearch = (provider?: Provider): void => {
  active = provider;
};

/** Test seam, like `Browser.attached`: drive a CDP endpoint instead of launching one. */
let override: Browser | undefined;

export const useSearchBrowser = (driver?: Browser): void => {
  override = driver;
};

const format = (result: SearchResult, index: number): string =>
  [`${index + 1}. ${result.title}`, `   ${result.url}`, result.snippet && `   ${result.snippet}`]
    .filter(Boolean)
    .join("\n");

export const webSearchTool: Tool = {
  name: "web_search",
  description:
    "Search the web and return the top results with their URLs. Use fetch to read one of " +
    "them in full.",
  parameters: {
    type: "object",
    properties: { query: { type: "string", description: "What to search for." } },
    required: ["query"],
  },
  run: async ({ query }) => {
    const text = String(query ?? "").trim();
    if (!text) throw new Error("web_search: query is empty");

    const native = active?.search?.bind(active);
    if (native) {
      try {
        const answer = (await native(text)).trim();
        if (answer) return truncate(answer);
      } catch {
        // The provider has search and it failed: the browser can still answer this.
      }
    }

    const results = await searchWeb(text, TOP_N, override ?? browser());
    return results.length
      ? truncate(results.map(format).join("\n"))
      : `no results for ${text}`;
  },
};
