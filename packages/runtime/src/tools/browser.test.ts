import { createServer, type Server } from "node:http";
import { existsSync } from "node:fs";
import { env } from "node:process";
import { WebSocketServer } from "ws";
import { afterEach, expect, test } from "vitest";
import {
  Browser,
  browserEvalTool,
  browserTools,
  detectBrowsers,
  resolveBinary,
} from "./browser.js";

/**
 * A CDP endpoint that answers the Target and Runtime methods the tool uses. Runtime.evaluate
 * echoes the expression back as the result, so a test can assert what we asked the page to do.
 */
interface FakeCdp {
  url: string;
  /** Every method the tool called, in order. */
  calls: string[];
  /** Targets created and not yet closed. */
  open: Set<string>;
  close(): Promise<void>;
}

function fakeCdp(): Promise<FakeCdp> {
  const server: Server = createServer((_req, res) => res.end("{}"));
  const wss = new WebSocketServer({ server });
  const calls: string[] = [];
  const open = new Set<string>();
  let nextTarget = 1;

  wss.on("connection", (ws) => {
    ws.on("message", (raw) => {
      const { id, method, params = {} } = JSON.parse(raw.toString()) as {
        id: number;
        method: string;
        params: Record<string, string>;
      };
      calls.push(method);
      let result: Record<string, unknown> = {};
      switch (method) {
        case "Target.createTarget": {
          const targetId = `tab-${nextTarget++}`;
          open.add(targetId);
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
        case "Runtime.evaluate": {
          const expression = params.expression!;
          if (expression.includes("document.readyState")) result = { result: { value: "complete" } };
          else if (expression.includes("boom"))
            result = { exceptionDetails: { exception: { description: "ReferenceError: boom" } } };
          else result = { result: { value: expression } };
          break;
        }
      }
      ws.send(JSON.stringify({ id, result }));
    });
  });

  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as { port: number };
      resolve({
        url: `ws://127.0.0.1:${port}/devtools/browser/fake`,
        calls,
        open,
        close: () => new Promise<void>((done) => wss.close(() => server.close(() => done()))),
      });
    });
  });
}

let cdp: FakeCdp | undefined;
let browser: Browser | undefined;

afterEach(async () => {
  await browser?.closeAll();
  browser = undefined;
  await cdp?.close();
  cdp = undefined;
});

test("open attaches to a new target and waits for the document", async () => {
  cdp = await fakeCdp();
  browser = Browser.attached(cdp.url);

  const tabId = await browser.open("https://example.com");

  expect(tabId).toBe("tab-1");
  expect(cdp.open.has("tab-1")).toBe(true);
  expect(cdp.calls.slice(0, 3)).toEqual([
    "Target.createTarget",
    "Target.attachToTarget",
    "Runtime.evaluate",
  ]);
});

test("snapshot numbers the interactive elements it parks on the page", async () => {
  cdp = await fakeCdp();
  browser = Browser.attached(cdp.url);
  const tabId = await browser.open("https://example.com");

  const snapshot = await browser.snapshot(tabId);

  // The fake echoes the expression, so this asserts the script we send, not a rendering.
  expect(snapshot).toContain("window.__yorozu = refs");
  expect(snapshot).toContain("document.title");
});

test("click and type address an element by its snapshot number", async () => {
  cdp = await fakeCdp();
  browser = Browser.attached(cdp.url);
  const tabId = await browser.open("https://example.com");

  expect(await browser.click(tabId, 2)).toContain("clicked 2");
  const typed = await browser.type(tabId, 3, 'hello "world"');
  expect(typed).toContain('el.value = "hello \\"world\\""');
  expect(typed).toContain("no element");
});

test("a page exception surfaces as a tool error rather than a value", async () => {
  cdp = await fakeCdp();
  browser = Browser.attached(cdp.url);
  const tabId = await browser.open("https://example.com");

  await expect(browser.evaluate(tabId, "boom()")).rejects.toThrow("ReferenceError: boom");
});

test("the eval tool returns JSON and rejects a tab it never opened", async () => {
  cdp = await fakeCdp();
  browser = Browser.attached(cdp.url);
  const tabId = await browser.open("https://example.com");

  expect(await browser.evaluate(tabId, "1 + 1")).toBe("1 + 1");
  await expect(browser.evaluate("someone-elses-tab", "1")).rejects.toThrow("unknown tab");
});

test("closeAll closes every tab the agent opened", async () => {
  cdp = await fakeCdp();
  browser = Browser.attached(cdp.url);
  await browser.open("https://example.com");
  await browser.open("https://example.org");
  expect(cdp.open.size).toBe(2);

  await browser.closeAll();

  expect(cdp.open.size).toBe(0);
  browser = undefined;
});

test("close drops a single tab and leaves it unusable", async () => {
  cdp = await fakeCdp();
  browser = Browser.attached(cdp.url);
  const tabId = await browser.open("https://example.com");

  await browser.close(tabId);

  expect(cdp.open.size).toBe(0);
  await expect(browser.snapshot(tabId)).rejects.toThrow("unknown tab");
});

test("every browser tool is exposed with a tabId-shaped schema", () => {
  expect(browserTools.map((t) => t.name)).toEqual([
    "browser.open",
    "browser.snapshot",
    "browser.click",
    "browser.type",
    "browser.eval",
    "browser.close",
  ]);
  expect(browserEvalTool.parameters.required).toContain("tabId");
});

test("detection only reports browsers that are actually installed", () => {
  for (const { name, path } of detectBrowsers()) {
    expect(existsSync(path), `${name} at ${path}`).toBe(true);
  }
});

test("an explicit browser path that does not exist is refused", async () => {
  const previous = env.YOROZU_BROWSER;
  env.YOROZU_BROWSER = "/Applications/Nope.app/Contents/MacOS/Nope";
  try {
    await expect(resolveBinary()).rejects.toThrow("no such browser");
  } finally {
    if (previous === undefined) delete env.YOROZU_BROWSER;
    else env.YOROZU_BROWSER = previous;
  }
});

/** Launches a real browser, so it only runs when one has been chosen explicitly. */
test.skipIf(!env.YOROZU_BROWSER)("a real browser opens, snapshots and closes", async () => {
  browser = new Browser();
  const tabId = await browser.open("https://example.com");

  const snapshot = await browser.snapshot(tabId);

  expect(snapshot).toContain("Example Domain");
  await browser.close(tabId);
}, 120_000);
