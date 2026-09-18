import { createServer, type Server } from "node:http";
import { existsSync } from "node:fs";
import { env } from "node:process";
import { WebSocketServer } from "ws";
import { afterEach, expect, test } from "vitest";
import { defaultTools } from "../index.js";
import { forgetApprovals, recordApproval } from "../approval.js";
import {
  Browser,
  browserClickTool,
  browserCloseTool,
  browserEvalTool,
  browserOpenTool,
  browserSnapshotTool,
  browserTools,
  browserTypeTool,
  detectBrowsers,
  resolveBinary,
  useBrowser,
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

/**
 * Attaches a fake browser, points the shared tools at it as the sidecar points them at the
 * real one, and opens the tab the tool-level tests all work on.
 */
async function attach(): Promise<string> {
  cdp = await fakeCdp();
  browser = Browser.attached(cdp.url);
  useBrowser(browser);
  return browser.open("https://example.com");
}

afterEach(async () => {
  useBrowser(undefined);
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

test("every browser tool is exposed with a tabId-shaped schema", async () => {
  expect(browserTools.map((t) => t.name)).toEqual([
    "browser.open",
    "browser.snapshot",
    "browser.click",
    "browser.type",
    "browser.eval",
    "browser.close",
  ]);
  expect(browserTools.map((t) => (t.parameters as { required: string[] }).required)).toEqual([
    ["url"],
    ["tabId"],
    ["tabId", "ref"],
    ["tabId", "ref", "text"],
    ["tabId", "js"],
    ["tabId"],
  ]);
  // Opening a URL is a visit, allowed by default but fenceable and asked about when the URL
  // itself acts on arrival. Snapshot and tab lifecycle stay local. Page interaction can submit
  // external state, so it gates every time.
  expect(browserTools.map((t) => t.actionClass)).toEqual([
    "visit-url",
    undefined,
    "interact-web",
    "interact-web",
    "interact-web",
    undefined,
  ]);

  // A call naming no tab cannot be dispatched to one the agent opened.
  await attach();
  await expect(Promise.resolve(browserSnapshotTool.run({}))).rejects.toThrow(
    "browser: unknown tab",
  );
});

test("the open tool hands back a tab ID the other tools take", async () => {
  const tabId = await attach();

  expect(tabId).toBe("tab-1");
  expect(await browserOpenTool.run({ url: "https://example.org" })).toBe("tab-2");
  expect(cdp!.open).toEqual(new Set(["tab-1", "tab-2"]));
});

test("the snapshot tool reads the tab it was given, and refuses one it never opened", async () => {
  const tabId = await attach();

  // The fake echoes the expression, so this asserts the script we send, not a rendering.
  expect(await browserSnapshotTool.run({ tabId })).toContain("window.__yorozu = refs");
  await expect(Promise.resolve(browserSnapshotTool.run({ tabId: "tab-99" }))).rejects.toThrow(
    "browser: unknown tab: tab-99",
  );
});

test("the click and type tools address an element by its snapshot number", async () => {
  const tabId = await attach();

  expect(await browserClickTool.run({ tabId, ref: 2 })).toContain("clicked 2");
  expect(await browserTypeTool.run({ tabId, ref: 3, text: "日本語 🎌" })).toContain(
    'el.value = "日本語 🎌"',
  );
});

test("the eval tool returns JSON, and a page exception as an error", async () => {
  const tabId = await attach();

  expect(await browserEvalTool.run({ tabId, js: "1 + 1" })).toBe('"1 + 1"');
  await expect(Promise.resolve(browserEvalTool.run({ tabId, js: "boom()" }))).rejects.toThrow(
    "ReferenceError: boom",
  );
});

test("browser mutation refuses changed details at commit", async () => {
  forgetApprovals();
  const approvedArgs = { tabId: "tab-1", js: "submit()" };
  recordApproval("browser-1", {
    actionClass: "interact-web",
    ...browserEvalTool.action!(approvedArgs),
  });

  const result = await browserEvalTool.run(
    { ...approvedArgs, js: "buy()" },
    { threadId: "home", agentId: "main", actionId: "browser-1" },
  );
  expect(result).toMatch(/^not allowed: what was approved has changed/);
  forgetApprovals();
});

test("the close tool closes the tab and names it", async () => {
  const tabId = await attach();

  expect(await browserCloseTool.run({ tabId })).toBe(`closed ${tabId}`);
  expect(cdp!.open.size).toBe(0);
});

test("the registry dispatches every browser tool to this implementation", async () => {
  for (const tool of browserTools) {
    expect(defaultTools.find((t) => t.name === tool.name)).toBe(tool);
  }

  const tabId = await attach();
  const registered = defaultTools.find((t) => t.name === "browser.close")!;

  expect(await registered.run({ tabId })).toBe(`closed ${tabId}`);
  expect(cdp!.open.size).toBe(0);
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
