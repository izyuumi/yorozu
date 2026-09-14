/**
 * The browser tool: the agent drives a Chromium-family browser over CDP, in a profile of
 * its own, and closes every tab it opened. No puppeteer, no playwright — CDP is a JSON
 * protocol over one WebSocket, and `ws` is already a dependency.
 *
 * The user picks the binary in the Mac app; `YOROZU_BROWSER` carries the choice:
 * `bundled` (Chrome for Testing, downloaded on first use) or an absolute path.
 * See docs/spec-v1.html section 4.
 */

import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { createWriteStream, existsSync, mkdirSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:net";
import { join } from "node:path";
import { env } from "node:process";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import WebSocket from "ws";
import { summarize, verifyApproved } from "../approval.js";
import type { Tool } from "../index.js";
import { stateDir } from "../memory.js";

export const BROWSER_ENV = "YOROZU_BROWSER";

/** Chromium-family browsers we know how to launch, by bundle path. Order is preference. */
const KNOWN_BROWSERS: { name: string; path: string }[] = [
  { name: "Google Chrome", path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" },
  { name: "Chromium", path: "/Applications/Chromium.app/Contents/MacOS/Chromium" },
  { name: "Brave", path: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser" },
  { name: "Microsoft Edge", path: "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge" },
  { name: "Arc", path: "/Applications/Arc.app/Contents/MacOS/Arc" },
];

export interface InstalledBrowser {
  name: string;
  /** Absolute path to the executable inside the bundle, ready for `YOROZU_BROWSER`. */
  path: string;
}

/** The known browsers actually present on this Mac. The Mac app's picker lists these. */
export function detectBrowsers(): InstalledBrowser[] {
  return KNOWN_BROWSERS.filter((b) => existsSync(b.path));
}

const VERSIONS_URL =
  "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json";

const PLATFORM = "mac-arm64";

interface VersionsJson {
  channels: Record<string, { version: string; downloads: { chrome: { platform: string; url: string }[] } }>;
}

const chromeDir = (dir: string): string => join(dir, "chrome");

/** Where `ditto` leaves the executable once the Chrome for Testing zip is expanded. */
const bundledBinary = (dir: string): string =>
  join(
    chromeDir(dir),
    `chrome-${PLATFORM}`,
    "Google Chrome for Testing.app",
    "Contents",
    "MacOS",
    "Google Chrome for Testing",
  );

/**
 * Chrome for Testing, downloaded once into the state dir. The zip is verified by its
 * declared length and then by the binary actually being there; a partial download is
 * thrown away so the next call retries cleanly.
 */
export async function ensureBundled(
  dir = stateDir(),
  log: (line: string) => void = console.error,
): Promise<string> {
  const binary = bundledBinary(dir);
  if (existsSync(binary)) return binary;

  const versions = (await (await fetch(VERSIONS_URL)).json()) as VersionsJson;
  const stable = versions.channels.Stable;
  const download = stable?.downloads.chrome.find((d) => d.platform === PLATFORM);
  if (!download) throw new Error(`browser: no Chrome for Testing build for ${PLATFORM}`);

  const target = chromeDir(dir);
  mkdirSync(target, { recursive: true });
  const zip = join(target, "chrome.zip");
  log(`browser: downloading Chrome for Testing ${stable.version} (${PLATFORM})`);

  const response = await fetch(download.url);
  if (!response.ok || !response.body) {
    throw new Error(`browser: download failed: HTTP ${response.status}`);
  }
  const expected = Number(response.headers.get("content-length") ?? 0);
  await pipeline(Readable.fromWeb(response.body), createWriteStream(zip));

  const size = statSync(zip).size;
  if (expected && size !== expected) {
    rmSync(zip, { force: true });
    throw new Error(`browser: download truncated: ${size} of ${expected} bytes`);
  }
  log(`browser: downloaded ${size} bytes, expanding`);

  // macOS ships the unzipper that preserves the bundle's signature; Node has none.
  execFileSync("ditto", ["-x", "-k", zip, target]);
  rmSync(zip, { force: true });
  if (!existsSync(binary)) throw new Error("browser: expanded archive has no Chrome binary");
  log(`browser: ready at ${binary}`);
  return binary;
}

/**
 * The binary to launch: an explicit path, the bundled Chrome, or — when nothing is
 * configured — whichever known browser this Mac already has, falling back to bundled.
 */
export async function resolveBinary(
  dir = stateDir(),
  log?: (line: string) => void,
): Promise<string> {
  const choice = env[BROWSER_ENV]?.trim();
  if (choice && choice !== "bundled") {
    if (!existsSync(choice)) throw new Error(`browser: no such browser: ${choice}`);
    return choice;
  }
  if (!choice) {
    const installed = detectBrowsers();
    if (installed.length) return installed[0]!.path;
  }
  return ensureBundled(dir, log);
}

/** A port the OS just told us is free, rather than a guess that may collide. */
function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.on("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address() as { port: number };
      server.close(() => resolve(port));
    });
  });
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** The browser needs a moment to open its port; poll rather than guess a delay. */
async function waitForEndpoint(port: number, timeoutMs = 30_000): Promise<string> {
  const deadline = Date.now() + timeoutMs;
  let last = "";
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/json/version`);
      const { webSocketDebuggerUrl } = (await response.json()) as { webSocketDebuggerUrl: string };
      if (webSocketDebuggerUrl) return webSocketDebuggerUrl;
    } catch (e) {
      last = e instanceof Error ? e.message : String(e);
    }
    await sleep(100);
  }
  throw new Error(`browser: debugging port ${port} never answered${last ? `: ${last}` : ""}`);
}

interface Pending {
  resolve: (result: Record<string, unknown>) => void;
  reject: (error: Error) => void;
}

/** One CDP connection: requests are matched to replies by id, as the protocol defines. */
class Connection {
  private nextId = 1;
  private readonly pending = new Map<number, Pending>();

  private constructor(private readonly ws: WebSocket) {
    ws.on("message", (data) => this.onMessage(data.toString()));
    ws.on("close", () => {
      for (const { reject } of this.pending.values()) reject(new Error("browser: connection closed"));
      this.pending.clear();
    });
  }

  static async connect(url: string): Promise<Connection> {
    const ws = new WebSocket(url);
    await new Promise<void>((resolve, reject) => {
      ws.once("open", resolve);
      ws.once("error", reject);
    });
    return new Connection(ws);
  }

  private onMessage(raw: string): void {
    const message = JSON.parse(raw) as {
      id?: number;
      result?: Record<string, unknown>;
      error?: { message: string };
    };
    if (message.id === undefined) return; // An event, not a reply: nothing awaits it.
    const waiter = this.pending.get(message.id);
    if (!waiter) return;
    this.pending.delete(message.id);
    if (message.error) waiter.reject(new Error(`browser: ${message.error.message}`));
    else waiter.resolve(message.result ?? {});
  }

  send(
    method: string,
    params: Record<string, unknown> = {},
    sessionId?: string,
  ): Promise<Record<string, unknown>> {
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }

  close(): void {
    this.ws.close();
  }
}

/**
 * The agent's browser: at most one process, launched lazily, in its own profile so the
 * user's tabs, cookies and sessions are never touched.
 */
export class Browser {
  private child: ChildProcess | null = null;
  private connection: Connection | null = null;
  private starting: Promise<Connection> | null = null;
  /** Only the tabs we opened: those are the only ones we are allowed to close. */
  private readonly tabs = new Map<string, string>();

  constructor(
    private readonly dir = stateDir(),
    private readonly log: (line: string) => void = console.error,
  ) {}

  /** Test seam: drive a CDP endpoint that is already running instead of launching one. */
  static attached(url: string): Browser {
    const browser = new Browser();
    browser.starting = Connection.connect(url).then((c) => (browser.connection = c));
    return browser;
  }

  private async connect(): Promise<Connection> {
    if (this.connection) return this.connection;
    this.starting ??= this.launch();
    return this.starting;
  }

  private async launch(): Promise<Connection> {
    const binary = await resolveBinary(this.dir, this.log);
    const port = await freePort();
    const profile = join(this.dir, "browser-profile");
    mkdirSync(profile, { recursive: true });
    this.log(`browser: launching ${binary} on port ${port}`);
    this.child = spawn(
      binary,
      [`--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "--no-first-run"],
      { stdio: "ignore" },
    );
    this.child.unref();
    const connection = await Connection.connect(await waitForEndpoint(port));
    this.connection = connection;
    return connection;
  }

  /** Opens a tab already navigated to `url` and returns its CDP target ID. */
  async open(url: string): Promise<string> {
    const connection = await this.connect();
    const { targetId } = (await connection.send("Target.createTarget", { url })) as {
      targetId: string;
    };
    const { sessionId } = (await connection.send("Target.attachToTarget", {
      targetId,
      flatten: true,
    })) as { sessionId: string };
    this.tabs.set(targetId, sessionId);
    await this.settle(targetId, url);
    return targetId;
  }

  private session(tabId: string): string {
    const sessionId = this.tabs.get(tabId);
    if (!sessionId) throw new Error(`browser: unknown tab: ${tabId}`);
    return sessionId;
  }

  /** Evaluates `expression` in the tab and returns its value. */
  async evaluate(tabId: string, expression: string): Promise<unknown> {
    const connection = await this.connect();
    const result = (await connection.send(
      "Runtime.evaluate",
      { expression, returnByValue: true, awaitPromise: true },
      this.session(tabId),
    )) as {
      result?: { value?: unknown };
      exceptionDetails?: { exception?: { description?: string }; text?: string };
    };
    if (result.exceptionDetails) {
      const { exception, text } = result.exceptionDetails;
      throw new Error(`browser: ${exception?.description ?? text ?? "evaluation failed"}`);
    }
    return result.result?.value;
  }

  /**
   * Waits for the document to stop loading, so a snapshot sees the real page. A fresh
   * target starts at about:blank, which is already `complete`, so waiting on readyState
   * alone would snapshot the blank page: wait for the navigation to commit too.
   */
  private async settle(tabId: string, url: string, timeoutMs = 15_000): Promise<void> {
    const committed = url.startsWith("about:") ? "true" : 'location.href !== "about:blank"';
    const expression = `document.readyState === "complete" && ${committed} ? "complete" : "loading"`;
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        if ((await this.evaluate(tabId, expression)) === "complete") return;
      } catch {
        // Mid-navigation the context is swapped out; try again until the deadline.
      }
      await sleep(100);
    }
  }

  async snapshot(tabId: string): Promise<string> {
    return String(await this.evaluate(tabId, SNAPSHOT_JS));
  }

  async click(tabId: string, ref: number): Promise<string> {
    return String(await this.evaluate(tabId, `${REF_JS}(${ref}).click(), "clicked ${ref}"`));
  }

  async type(tabId: string, ref: number, text: string): Promise<string> {
    const expression = `(() => {
      const el = ${REF_JS}(${ref});
      el.focus();
      el.value = ${JSON.stringify(text)};
      for (const type of ["input", "change"]) el.dispatchEvent(new Event(type, { bubbles: true }));
      return "typed into ${ref}";
    })()`;
    return String(await this.evaluate(tabId, expression));
  }

  async close(tabId: string): Promise<void> {
    const connection = await this.connect();
    this.session(tabId); // Refuse tabs we did not open: they may be the user's.
    await connection.send("Target.closeTarget", { targetId: tabId });
    this.tabs.delete(tabId);
  }

  /** Runtime shutdown: every tab the agent opened goes away, and so does the process. */
  async closeAll(): Promise<void> {
    for (const tabId of [...this.tabs.keys()]) {
      await this.close(tabId).catch(() => this.tabs.delete(tabId));
    }
    this.connection?.close();
    this.connection = null;
    this.starting = null;
    this.child?.kill();
    this.child = null;
  }
}

/**
 * Interactive elements are numbered and parked on `window.__yorozu` so that a later
 * click or type can name one by number without the caller inventing a selector.
 */
const SNAPSHOT_JS = `(() => {
  const selector = "a,button,input,textarea,select,[role=button],[role=link],[contenteditable=true]";
  const visible = (el) => !!(el.offsetWidth || el.offsetHeight || el.getClientRects().length);
  const refs = [...document.querySelectorAll(selector)].filter(visible);
  window.__yorozu = refs;
  const label = (el) =>
    (el.getAttribute("aria-label") || el.value || el.placeholder || el.innerText || el.title || "")
      .replace(/\\s+/g, " ")
      .trim()
      .slice(0, 80);
  const lines = refs.map((el, i) => \`[\${i}] \${el.tagName.toLowerCase()} "\${label(el)}"\`);
  const text = (document.body?.innerText ?? "").replace(/\\n{3,}/g, "\\n\\n").trim().slice(0, 4000);
  return [
    \`# \${document.title}\`,
    document.location.href,
    "",
    text,
    "",
    \`## interactive (\${refs.length})\`,
    ...lines,
  ].join("\\n");
})()`;

/** Resolves a snapshot's number back to its element, loudly when the snapshot is stale. */
const REF_JS = `((i) => {
  const el = (window.__yorozu ?? [])[i];
  if (!el) throw new Error("no element " + i + ": call browser.snapshot first");
  el.scrollIntoView({ block: "center" });
  return el;
})`;

/** One browser per runtime; the tools below all share it. */
let shared: Browser | null = null;

export const browser = (): Browser => (shared ??= new Browser());

/** Test seam, like `useSearchBrowser`: hand the tools a browser instead of launching one. */
export const useBrowser = (driver?: Browser): void => {
  shared = driver ?? null;
};

/** Called on runtime shutdown: the agent leaves nothing open behind it. */
export async function closeBrowser(): Promise<void> {
  await shared?.closeAll();
  shared = null;
}

const tabArg = { tabId: { type: "string", description: "Tab ID from browser.open." } };

export const browserOpenTool: Tool = {
  name: "browser.open",
  description:
    "Open a URL in the agent's own browser profile and return the tab ID. Never touches " +
    "the user's own tabs.",
  parameters: {
    type: "object",
    properties: { url: { type: "string" } },
    required: ["url"],
  },
  run: async ({ url }) => browser().open(String(url ?? "")),
};

export const browserSnapshotTool: Tool = {
  name: "browser.snapshot",
  description:
    "Read a tab as text: title, URL, visible text, and every interactive element numbered. " +
    "Use the numbers with browser.click and browser.type.",
  parameters: { type: "object", properties: tabArg, required: ["tabId"] },
  run: async ({ tabId }) => browser().snapshot(String(tabId ?? "")),
};

export const browserClickTool: Tool = {
  name: "browser.click",
  description: "Click the element with the given number from the latest snapshot of the tab.",
  actionClass: "interact-web",
  action: ({ tabId, ref }) => ({
    target: `${String(tabId ?? "")} element ${String(ref ?? "")}`,
    operation: "run",
    consequence: "Clicks a web-page control, which may change external state.",
  }),
  parameters: {
    type: "object",
    properties: { ...tabArg, ref: { type: "number", description: "Number from the snapshot." } },
    required: ["tabId", "ref"],
  },
  run: async (args, context) => {
    if (context?.actionId) {
      const stale = verifyApproved(context.actionId, browserClickTool.action!(args));
      if (stale) return stale;
    }
    return browser().click(String(args.tabId ?? ""), Number(args.ref));
  },
};

export const browserTypeTool: Tool = {
  name: "browser.type",
  description: "Type text into the element with the given number from the latest snapshot.",
  actionClass: "interact-web",
  action: ({ tabId, ref, text }) => ({
    target: `${String(tabId ?? "")} element ${String(ref ?? "")}`,
    operation: "run",
    contentSummary: summarize(String(text ?? "")),
    consequence: "Enters this text into a web page.",
  }),
  parameters: {
    type: "object",
    properties: { ...tabArg, ref: { type: "number" }, text: { type: "string" } },
    required: ["tabId", "ref", "text"],
  },
  run: async (args, context) => {
    if (context?.actionId) {
      const stale = verifyApproved(context.actionId, browserTypeTool.action!(args));
      if (stale) return stale;
    }
    return browser().type(String(args.tabId ?? ""), Number(args.ref), String(args.text ?? ""));
  },
};

export const browserEvalTool: Tool = {
  name: "browser.eval",
  description: "Evaluate JavaScript in the tab and return the result as JSON.",
  actionClass: "interact-web",
  action: ({ tabId, js }) => ({
    target: String(tabId ?? ""),
    operation: "run",
    contentSummary: summarize(String(js ?? "")),
    consequence: "Runs JavaScript in a web page, which may change external state.",
  }),
  parameters: {
    type: "object",
    properties: { ...tabArg, js: { type: "string" } },
    required: ["tabId", "js"],
  },
  run: async (args, context) => {
    if (context?.actionId) {
      const stale = verifyApproved(context.actionId, browserEvalTool.action!(args));
      if (stale) return stale;
    }
    const value = await browser().evaluate(String(args.tabId ?? ""), String(args.js ?? ""));
    return value === undefined ? "undefined" : JSON.stringify(value);
  },
};

export const browserCloseTool: Tool = {
  name: "browser.close",
  description: "Close a tab the agent opened.",
  parameters: { type: "object", properties: tabArg, required: ["tabId"] },
  run: async ({ tabId }) => {
    await browser().close(String(tabId ?? ""));
    return `closed ${String(tabId)}`;
  },
};

export const browserTools: Tool[] = [
  browserOpenTool,
  browserSnapshotTool,
  browserClickTool,
  browserTypeTool,
  browserEvalTool,
  browserCloseTool,
];
