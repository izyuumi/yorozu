import { createServer, type Server } from "node:http";
import { WebSocketServer } from "ws";
import { afterEach, expect, test } from "vitest";
import { defaultTools } from "../index.js";
import type { Provider } from "../provider.js";
import { Browser } from "./browser.js";
import {
  DUCKDUCKGO,
  parseDuckDuckGo,
  resolveResultUrl,
  searchWeb,
  useProviderSearch,
  useSearchBrowser,
  webSearchTool,
} from "./search.js";

/** One result block in the shape the no-JavaScript endpoint actually serves. */
const result = (i: number): string => `
<div class="result results_links results_links_deep web-result">
  <h2 class="result__title">
    <a rel="nofollow" class="result__a"
       href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage${i}&amp;rut=deadbeef">Result &amp; <b>${i}</b></a>
  </h2>
  <a class="result__snippet" href="//duckduckgo.com/l/?uddg=x">Snippet number ${i}.</a>
</div>`;

/** Ten results, so the top-8 cut is exercised rather than assumed. */
const DDG_PAGE = `<!DOCTYPE html><html><head><title>q at DuckDuckGo</title></head><body>
${Array.from({ length: 10 }, (_, i) => result(i + 1)).join("")}
</body></html>`;

const DDG_EMPTY = `<!DOCTYPE html><html><body><div class="no-results">No results.</div></body></html>`;

interface FakeCdp {
  url: string;
  /** Targets created and not yet closed, so a leaked tab is visible. */
  open: Set<string>;
  /** Every URL a target was created with. */
  opened: string[];
  close(): Promise<void>;
}

/** The CDP subset the browser tool uses, answering `outerHTML` with a canned DDG page. */
function fakeCdp(html: string): Promise<FakeCdp> {
  const server: Server = createServer((_req, res) => res.end("{}"));
  const wss = new WebSocketServer({ server });
  const open = new Set<string>();
  const opened: string[] = [];
  let nextTarget = 1;

  wss.on("connection", (ws) => {
    ws.on("message", (raw) => {
      const { id, method, params = {} } = JSON.parse(raw.toString()) as {
        id: number;
        method: string;
        params: Record<string, string>;
      };
      let result: Record<string, unknown> = {};
      switch (method) {
        case "Target.createTarget": {
          const targetId = `tab-${nextTarget++}`;
          open.add(targetId);
          opened.push(params.url!);
          result = { targetId };
          break;
        }
        case "Target.attachToTarget":
          result = { sessionId: `session-${params.targetId}` };
          break;
        case "Target.closeTarget":
          open.delete(params.targetId!);
          result = { success: true };
          break;
        case "Runtime.evaluate":
          result = {
            result: {
              value: params.expression!.includes("outerHTML")
                ? html
                : params.expression!.includes("document.readyState")
                  ? "complete"
                  : params.expression,
            },
          };
          break;
      }
      ws.send(JSON.stringify({ id, result }));
    });
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as { port: number };
      resolve({
        url: `ws://127.0.0.1:${port}/devtools/browser/fake`,
        open,
        opened,
        close: () => new Promise<void>((done) => wss.close(() => server.close(() => done()))),
      });
    });
  });
}

let cdp: FakeCdp | undefined;
let browser: Browser | undefined;

/** Attaches a fake browser and points the tool at it, as the sidecar points it at the real one. */
async function attach(html = DDG_PAGE): Promise<void> {
  cdp = await fakeCdp(html);
  browser = Browser.attached(cdp.url);
  useSearchBrowser(browser);
  // `attached` starts connecting eagerly, so a test that never touches the browser would
  // still have a socket in flight when afterEach shuts the server down — and nobody would
  // be awaiting it to catch the reset. One doomed call settles the connection first; it
  // opens no tab, so the assertions on what was opened still mean what they say.
  await browser.evaluate("not-a-tab", "1").catch(() => {});
}

afterEach(async () => {
  useSearchBrowser(undefined);
  useProviderSearch(undefined);
  await browser?.closeAll();
  browser = undefined;
  await cdp?.close();
  cdp = undefined;
});

test("the fallback drives DuckDuckGo and reads the results off the page", async () => {
  await attach();

  const results = await searchWeb("yorozu assistant", 8, browser!);

  expect(cdp!.opened[0]).toBe("https://duckduckgo.com/html/?q=yorozu%20assistant");
  expect(results).toHaveLength(8);
  expect(results[0]).toEqual({
    title: "Result & 1",
    url: "https://example.com/page1",
    snippet: "Snippet number 1.",
  });
});

test("the tab the search opened is closed again", async () => {
  await attach();

  await searchWeb("anything", 8, browser!);

  expect(cdp!.open.size).toBe(0);
});

test("a page with no results says so rather than inventing one", async () => {
  await attach(DDG_EMPTY);

  expect(await webSearchTool.run({ query: "nothing at all" })).toBe(
    "no results for nothing at all",
  );
});

test("the tool numbers the top results with their URLs", async () => {
  await attach();

  const out = await webSearchTool.run({ query: "yorozu" });

  expect(out.split("\n").slice(0, 3)).toEqual([
    "1. Result & 1",
    "   https://example.com/page1",
    "   Snippet number 1.",
  ]);
  expect(out).toContain("8. Result & 8");
  expect(out).not.toContain("9. Result & 9");
});

test("provider-native search is preferred over driving a browser", async () => {
  await attach();
  useProviderSearch({ search: async (q) => `native answer for ${q}` } as Provider);

  expect(await webSearchTool.run({ query: "kyoto" })).toBe("native answer for kyoto");
  // The browser was never opened: that is the point of the capability.
  expect(cdp!.opened).toHaveLength(0);
});

test("a provider whose search fails falls through to the browser", async () => {
  await attach();
  useProviderSearch({
    search: async () => {
      throw new Error("rate limited");
    },
  } as Provider);

  expect(await webSearchTool.run({ query: "yorozu" })).toContain("https://example.com/page1");
  expect(cdp!.opened).toHaveLength(1);
});

test("an empty query is refused before anything is opened", async () => {
  await attach();

  await expect(Promise.resolve(webSearchTool.run({ query: "  " }))).rejects.toThrow("empty");
  expect(cdp!.opened).toHaveLength(0);
});

test("a query is percent-encoded into the endpoint URL, unicode and all", async () => {
  await attach();

  await searchWeb("日本 ラーメン", 8, browser!);

  expect(cdp!.opened[0]).toBe(`${DUCKDUCKGO}${encodeURIComponent("日本 ラーメン")}`);
});

test("a browser that cannot open the tab is an error, not an empty result list", async () => {
  useSearchBrowser({
    open: async () => {
      throw new Error("browser: connection closed");
    },
  } as unknown as Browser);

  await expect(Promise.resolve(webSearchTool.run({ query: "yorozu" }))).rejects.toThrow(
    "browser: connection closed",
  );
});

test("the schema is the one argument the model must supply, and a call without it fails", async () => {
  expect(webSearchTool.name).toBe("web_search");
  const { properties, required } = webSearchTool.parameters as {
    properties: Record<string, unknown>;
    required: string[];
  };
  expect(required).toEqual(["query"]);
  expect(Object.keys(properties)).toEqual(["query"]);
  // Searching has no effect outside the runtime, so there is no approval card.
  expect(webSearchTool.actionClass).toBeUndefined();

  await expect(Promise.resolve(webSearchTool.run({}))).rejects.toThrow(
    "web_search: query is empty",
  );
});

test("the registry dispatches `web_search` to this implementation", async () => {
  await attach();
  const registered = defaultTools.find((tool) => tool.name === "web_search");

  expect(registered).toBe(webSearchTool);
  expect(await registered!.run({ query: "yorozu" })).toContain("https://example.com/page1");
});

test("DuckDuckGo's redirector is unwrapped to the real target", () => {
  expect(resolveResultUrl("//duckduckgo.com/l/?uddg=https%3A%2F%2Fa.example%2Fx&amp;rut=1")).toBe(
    "https://a.example/x",
  );
  // A direct href is left alone beyond the protocol-relative prefix.
  expect(resolveResultUrl("//example.com/plain")).toBe("https://example.com/plain");
  expect(resolveResultUrl("https://example.com/plain")).toBe("https://example.com/plain");
});

test("parsing keeps the limit and skips anchors with nothing to show", () => {
  expect(parseDuckDuckGo(DDG_PAGE, 3)).toHaveLength(3);
  expect(parseDuckDuckGo('<a class="result__a" href="//x">  </a>')).toEqual([]);
  expect(parseDuckDuckGo("<html><body>nothing here</body></html>")).toEqual([]);
});
