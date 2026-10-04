import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { describe, expect, it, vi } from "vitest";
import { SiwcNativeProtectedStore, SIWC_HELPER_IDENTIFIER, SIWC_HELPER_TEAM, SIWC_HELPER_LINE_BYTES,
  type SiwcHelperInspector, type SiwcHelperChild } from "./siwc-protected-store.js";
import { SiwcAccountLifecycle, type SiwcProtectedSnapshot } from "./siwc-account-lifecycle.js";

const RESOURCES = "/signed/Yorozu.app/Contents/Resources", EXE = RESOURCES + "/yorozu-accounts";
const TOKEN = "synthetic_private_access_1234567890", ID_TOKEN = "synthetic_private_id_token_1234567890";
function empty(): SiwcProtectedSnapshot { return { version: 1, revision: 0, hostId: "synthetic-stable-host", appName: "Yorozu", callbackPath: "/auth/callback", accounts: [] }; }
interface Frame { version: number; rid: string; command: string; payload?: any; }
class FakeChild extends EventEmitter implements SiwcHelperChild {
  stdin = new PassThrough(); stdout = new PassThrough(); frames: Frame[] = []; kills: string[] = [];
  snapshot = empty(); leases = new Map<string, string>(); counter = 0;
  handler: (frame: Frame) => void = frame => {
    if (frame.command === "available") this.reply(frame, true);
    if (frame.command === "initialize" || frame.command === "read") this.reply(frame, this.snapshot);
    if (frame.command === "replace") { const p = frame.payload;
      if (p.expectedRevision !== this.snapshot.revision) this.reply(frame, "conflict");
      else { this.snapshot = structuredClone(p.next); this.reply(frame, "committed"); } }
    if (frame.command === "lock") { const lease = (++this.counter).toString(16).padStart(64, "0"); this.leases.set(lease, frame.payload.accountBindingId); this.reply(frame, lease); }
    if (frame.command === "unlock") { const known = this.leases.delete(frame.payload.lease); this.reply(frame, known); }
    if (frame.command === "open-browser") this.reply(frame, { opened: true });
  };
  constructor() {
    super(); let buffer = "";
    this.stdin.on("data", chunk => { buffer += chunk.toString("utf8"); let end: number;
      while ((end = buffer.indexOf("\n")) >= 0) { const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        const frame = JSON.parse(line) as Frame; this.frames.push(frame); queueMicrotask(() => this.handler(frame)); } });
  }
  reply(frame: Frame, value: unknown) { this.stdout.write(JSON.stringify({ version: 1, rid: frame.rid, ok: true, value }) + "\n"); }
  error(frame: Frame, error: string) { this.stdout.write(JSON.stringify({ version: 1, rid: frame.rid, ok: false, error }) + "\n"); }
  kill(signal = "SIGTERM") { this.kills.push(signal); return true; }
}
function fixture(timeout = 30_000) {
  const child = new FakeChild(), fence = vi.fn(), launch = vi.fn(() => child);
  const inspector: SiwcHelperInspector = {
    path: vi.fn(async target => ({ realPath: target, kind: target === EXE ? "file" : "directory", mode: target === EXE ? 0o755 : 0o755 })),
    codesign: vi.fn(async args => {
      const exe = args.at(-1) === EXE, identifier = exe ? SIWC_HELPER_IDENTIFIER : "to.yumi.yorozu";
      return args.includes("--display") ? { stdout: `designated => identifier "${identifier}" and anchor apple generic and certificate leaf[subject.OU] = "${SIWC_HELPER_TEAM}"\n`,
        stderr: `Identifier=${identifier}\nTeamIdentifier=${SIWC_HELPER_TEAM}\n` } : { stdout: "", stderr: "" };
    }),
  };
  const store = new SiwcNativeProtectedStore({ signedResourcesPath: RESOURCES, executable: EXE, fenceAccounts: fence, requestTimeoutMs: timeout },
    { platform: "darwin", inspector, spawnHelper: launch });
  return { child, fence, launch, inspector, store };
}
async function browserUrl(store: SiwcNativeProtectedStore) {
  const snapshot = await store.read();
  const lifecycle = new SiwcAccountLifecycle({ hostId: snapshot.hostId, appName: snapshot.appName }, { store,
    transport: { request: async () => { throw new Error("inert transport"); } }, verifier: { verify: async () => ({ status: "unavailable" }) }, stopAccount() {} });
  return (await lifecycle.beginSignIn({ accountBindingId: "a", callbackPort: 1455, returning: false })).authorizationUrl;
}
const commands = (f: ReturnType<typeof fixture>) => f.child.frames.map(v => v.command);

describe("fixed native protected store bridge (fake child and inspectors only)", () => {
  it("has no construction/status/available/unauthorized-read side effects", async () => {
    const f = fixture(); expect(f.store.status()).toEqual({ productionReady: false, available: false, state: "dormant" });
    expect(f.store.available()).toBe(false); await expect(f.store.read()).rejects.toMatchObject({ code: "unsupported" });
    const lifecycle = new SiwcAccountLifecycle({ hostId: "opaque-placeholder", appName: "Yorozu" }, { store: f.store,
      transport: { request: vi.fn() }, verifier: { verify: vi.fn() }, stopAccount: vi.fn() });
    expect((await lifecycle.status()).state).toBe("unsupported"); expect(f.launch).not.toHaveBeenCalled();
    expect(f.inspector.path).not.toHaveBeenCalled(); expect(f.inspector.codesign).not.toHaveBeenCalled(); expect(f.child.frames).toEqual([]);
  });
  it("verifies exact signed paths/publisher/designated identity then initializes only on explicit activation", async () => {
    const f = fixture(); const snapshot = await f.store.activate(); expect(snapshot).toEqual(empty());
    expect(f.inspector.path).toHaveBeenCalledTimes(4); expect(f.inspector.codesign).toHaveBeenCalledTimes(4);
    expect((f.inspector.codesign as any).mock.calls[0][0]).toEqual(["--verify", "--strict", '-R=identifier "to.yumi.yorozu" and anchor apple generic and certificate leaf[subject.OU] = "AN5KM8QGEF"', "/signed/Yorozu.app"]);
    expect((f.inspector.codesign as any).mock.calls[2][0]).toContain('-R=identifier "to.yumi.yorozu.accounts" and anchor apple generic and certificate leaf[subject.OU] = "AN5KM8QGEF"');
    expect(f.launch).toHaveBeenCalledWith(EXE, [], { stdio: ["pipe", "pipe", "ignore"], env: { PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LANG: "C", LC_ALL: "C" }, cwd: RESOURCES, shell: false });
    expect(commands(f)).toEqual(["available", "initialize"]); expect(f.child.frames[1].payload).toEqual({ appName: "Yorozu" });
    expect(f.store.available()).toBe(true); expect(f.store.status().productionReady).toBe(false); snapshot.hostId = "mutated";
    expect((await f.store.read()).hostId).toBe("synthetic-stable-host"); expect(f.fence).not.toHaveBeenCalled();
    for (const frame of f.child.frames) expect(frame).toMatchObject({ version: 1, rid: expect.stringMatching(/^[a-f0-9]{32}$/) });
  });
  it.each(["wrong-path", "symlink", "writable", "not-executable", "ad-hoc", "wrong-team", "wrong-id", "missing-designated", "verify-error"])
    ("refuses invalid helper trust %s before launch or credential RPC", async failure => {
      const f = fixture();
      if (["wrong-path", "symlink", "writable", "not-executable"].includes(failure)) (f.inspector.path as any).mockImplementation(async (target: string) => ({
        realPath: failure === "wrong-path" ? "/foreign/elsewhere" : target, kind: failure === "symlink" ? "symlink" : target === EXE ? "file" : "directory",
        mode: failure === "writable" ? 0o777 : failure === "not-executable" && target === EXE ? 0o644 : 0o755 }));
      else (f.inspector.codesign as any).mockImplementation(async (args: string[]) => {
        if (failure === "verify-error") throw new Error(TOKEN);
        return { stdout: failure === "missing-designated" ? "" : `designated => anchor apple generic and certificate leaf[subject.OU] = "${SIWC_HELPER_TEAM}"`,
          stderr: `Identifier=${failure === "wrong-id" ? "foreign" : args.at(-1) === EXE ? SIWC_HELPER_IDENTIFIER : "to.yumi.yorozu"}\nTeamIdentifier=${failure === "ad-hoc" ? "not set" : failure === "wrong-team" ? "OTHERTEAM01" : SIWC_HELPER_TEAM}\n` };
      });
      await expect(f.store.activate()).rejects.toThrow("SIWC account unsupported"); expect(f.launch).not.toHaveBeenCalled(); expect(f.child.frames).toEqual([]);
      expect(f.store.available()).toBe(false); expect(f.fence).toHaveBeenCalledTimes(1); expect(JSON.stringify(f.store.status())).not.toContain(TOKEN);
    });
  it("rejects arbitrary executable/client config and unsupported platforms without real inspection", async () => {
    const f = fixture(); for (const config of [{ signedResourcesPath: RESOURCES, executable: "/other/yorozu-accounts", fenceAccounts: f.fence },
      { signedResourcesPath: RESOURCES + "/..", executable: EXE, fenceAccounts: f.fence }, { signedResourcesPath: RESOURCES, executable: EXE, fenceAccounts: f.fence, tokenFile: "/private" }])
      expect(() => new SiwcNativeProtectedStore(config as any)).toThrow("SIWC account invalid");
    const linux = new SiwcNativeProtectedStore({ signedResourcesPath: RESOURCES, executable: EXE, fenceAccounts: f.fence }, { platform: "linux", inspector: f.inspector, spawnHelper: f.launch });
    await expect(linux.activate()).rejects.toMatchObject({ code: "unsupported" }); expect(f.launch).not.toHaveBeenCalled(); expect(f.inspector.path).not.toHaveBeenCalled();
  });
  it("shares concurrent activation, retains native host identity and never accepts external host injection", async () => {
    const f = fixture(); await Promise.all([f.store.activate(), f.store.activate()]); expect(f.launch).toHaveBeenCalledTimes(1);
    expect(commands(f)).toEqual(["available", "initialize"]); expect((await f.store.activate()).hostId).toBe("synthetic-stable-host");
    expect(commands(f).at(-1)).toBe("read");
  });
  it.each(["eof", "bad-frame", "abort"])("does not resurrect initialization after a reply followed by %s", async end => {
    const f = fixture(), controller = new AbortController(), handler = f.child.handler;
    f.child.handler = frame => {
      handler(frame);
      if (frame.command === "initialize") {
        if (end === "eof") f.child.stdout.emit("end");
        if (end === "bad-frame") f.child.stdout.write("invalid-secret-response\n");
        if (end === "abort") controller.abort();
      }
    };
    await expect(f.store.activate(controller.signal)).rejects.toMatchObject({ code: "unknown" });
    expect(f.store.available()).toBe(false); expect(f.store.status().state).toBe("unknown");
    await expect(f.store.activate()).rejects.toMatchObject({ code: "unknown" });
    expect(f.launch).toHaveBeenCalledTimes(1); expect(f.fence).toHaveBeenCalledTimes(1);
  });
  it("bounds a stalled trust inspector and prevents a late result from spawning", async () => {
    vi.useFakeTimers(); try {
      const f = fixture(); let release!: () => void;
      (f.inspector.path as any).mockImplementation(() => new Promise(resolve => { release = () => resolve({ realPath: RESOURCES, kind: "directory", mode: 0o755 }); }));
      const pending = f.store.activate().then(() => "unexpected-success", error => error.code);
      await vi.advanceTimersByTimeAsync(30_001); expect(await pending).toBe("unknown");
      release(); await Promise.resolve(); await Promise.resolve();
      expect(f.launch).not.toHaveBeenCalled(); expect(f.fence).toHaveBeenCalledTimes(1);
    } finally { vi.useRealTimers(); }
  });
  it("uses the exact lease in finally on callback failure and requires it for CAS", async () => {
    const f = fixture(); await f.store.activate(); const next = { ...empty(), revision: 1 };
    await expect(f.store.replace(0, next)).rejects.toMatchObject({ code: "invalid" }); expect(commands(f)).not.toContain("replace");
    await expect(f.store.withAccountLock("a", async () => { await f.store.replace(0, next); throw new Error("inert caller error"); })).rejects.toThrow("inert caller error");
    expect(commands(f).slice(-3)).toEqual(["lock", "replace", "unlock"]);
    expect(f.child.frames.at(-1)!.payload.lease).toBe("1".padStart(64, "0")); expect(f.child.leases.size).toBe(0);
    expect(f.child.snapshot.revision).toBe(1); expect(f.store.available()).toBe(true);
    const conflicted = await f.store.withAccountLock("a", () => f.store.replace(0, next)); expect(conflicted).toBe("conflict"); expect(f.fence).not.toHaveBeenCalled();
  });
  it("does not mix concurrent account lease contexts or admit a duplicate same-account lock", async () => {
    const f = fixture(); await f.store.activate(); let release!: () => void, entered!: () => void;
    const ready = new Promise<void>(r => { entered = r; }), pause = new Promise<void>(r => { release = r; });
    const a = f.store.withAccountLock("a", async () => { entered(); await pause; return "a"; }); await ready;
    await expect(f.store.withAccountLock("a", async () => "duplicate")).rejects.toMatchObject({ code: "conflict" });
    expect(await f.store.withAccountLock("b", async () => "b")).toBe("b"); release(); expect(await a).toBe("a");
    const unlocks = f.child.frames.filter(v => v.command === "unlock").map(v => v.payload.lease);
    expect(unlocks).toEqual(["2".padStart(64, "0"), "1".padStart(64, "0")]);
  });
  it("rejects forged/stale lease responses and permanently fences uncertainty", async () => {
    const f = fixture(); await f.store.activate(); const handler = f.child.handler;
    f.child.handler = frame => frame.command === "lock" ? f.child.reply(frame, "forged") : handler(frame);
    const action = vi.fn(async () => "never"); await expect(f.store.withAccountLock("a", action)).rejects.toMatchObject({ code: "unknown" });
    expect(action).not.toHaveBeenCalled(); expect(f.fence).toHaveBeenCalledTimes(1); expect(f.child.kills).toEqual(["SIGTERM"]);
    await expect(f.store.activate()).rejects.toMatchObject({ code: "unknown" }); expect(f.launch).toHaveBeenCalledTimes(1);
  });
  it("unknown unlock overrides callback success without a false release receipt", async () => {
    const f = fixture(); await f.store.activate(); const handler = f.child.handler;
    f.child.handler = frame => frame.command === "unlock" ? f.child.reply(frame, false) : handler(frame);
    await expect(f.store.withAccountLock("a", async () => "would-have-succeeded")).rejects.toMatchObject({ code: "unknown" });
    expect(f.store.status().state).toBe("unknown"); expect(f.fence).toHaveBeenCalledTimes(1); expect(commands(f).filter(v => v === "unlock")).toHaveLength(1);
  });
  it("EOF while holding a lease rejects immediately and fences a late callback from CAS", async () => {
    const f = fixture(); await f.store.activate(); let begin!: () => void, proceed!: () => void;
    const entered = new Promise<void>(r => { begin = r; }), pause = new Promise<void>(r => { proceed = r; });
    const late = f.store.withAccountLock("a", async () => { begin(); await pause; return f.store.replace(0, { ...empty(), revision: 1 }); });
    await entered; f.child.stdout.end(); await expect(late).rejects.toMatchObject({ code: "unknown" }); proceed(); await Promise.resolve(); await Promise.resolve();
    expect(commands(f)).not.toContain("replace"); expect(f.store.available()).toBe(false); expect(f.fence).toHaveBeenCalledTimes(1);
  });
  it.each(["lock", "replace", "unlock", "read"])("lost %s outcome never replays", async command => {
    vi.useFakeTimers(); try {
      const f = fixture(10); await f.store.activate(); const handler = f.child.handler;
      f.child.handler = frame => { if (frame.command !== command) handler(frame); };
      const op = command === "read" ? f.store.read() : f.store.withAccountLock("a", async () => command === "replace" ? f.store.replace(0, { ...empty(), revision: 1 }) : "result");
      const settled = op.then(() => "unexpected-success", error => error.code); await vi.advanceTimersByTimeAsync(11); expect(await settled).toBe("unknown");
      expect(commands(f).filter(v => v === command)).toHaveLength(1); await expect(f.store.activate()).rejects.toMatchObject({ code: "unknown" });
      expect(f.launch).toHaveBeenCalledTimes(1); expect(f.fence).toHaveBeenCalledTimes(1);
    } finally { vi.useRealTimers(); }
  });
  it.each(["foreign-rid", "duplicate-rid", "raw-error", "unknown-error", "both-fields", "utf8", "oversized", "bad-snapshot", "foreign-host"])
    ("rejects malformed native frame %s without secret diagnostics", async kind => {
      const f = fixture(); await f.store.activate(); f.child.handler = frame => {
        if (kind === "foreign-rid") f.child.stdout.write(JSON.stringify({ version: 1, rid: "foreign", ok: true, value: empty() }) + "\n");
        if (kind === "duplicate-rid") f.child.stdout.write(`{"version":1,"rid":"foreign","r\\u0069d":"${frame.rid}","ok":true,"value":true}\n`);
        if (kind === "raw-error") f.child.stdout.write(JSON.stringify({ version: 1, rid: frame.rid, ok: false, error: "invalid", message: TOKEN }) + "\n");
        if (kind === "unknown-error") f.child.error(frame, TOKEN);
        if (kind === "both-fields") f.child.stdout.write(JSON.stringify({ version: 1, rid: frame.rid, ok: true, value: empty(), error: "invalid" }) + "\n");
        if (kind === "utf8") f.child.stdout.write(Buffer.from([0xc0, 0xaf, 10]));
        if (kind === "oversized") f.child.stdout.write(Buffer.alloc(SIWC_HELPER_LINE_BYTES + 1, 65));
        if (kind === "bad-snapshot") f.child.reply(frame, { ...empty(), accounts: [{ accountBindingId: "../foreign" }] });
        if (kind === "foreign-host") f.child.reply(frame, { ...empty(), hostId: "foreign-host" });
      };
      await expect(f.store.read()).rejects.toThrow("SIWC account unknown"); expect(f.fence).toHaveBeenCalledTimes(1);
      expect(JSON.stringify(f.store.status())).not.toContain(TOKEN); expect(f.child.kills).toHaveLength(1);
    });
  it("supports fragmented valid replies, refuses duplicate late receipts and never logs protected values", async () => {
    const f = fixture(); await f.store.activate(); f.child.snapshot.accounts.push({ accountBindingId: "a", registration: { clientId: "oaiapp_a", subject: "synthetic-a" },
      phase: "ready", scopes: ["openid"], credentials: { accessToken: TOKEN, idToken: ID_TOKEN, expiresAt: Date.now() + 100_000 } });
    f.child.handler = frame => { const line = JSON.stringify({ version: 1, rid: frame.rid, ok: true, value: f.child.snapshot }) + "\n";
      for (let offset = 0; offset < line.length; offset += 17) f.child.stdout.write(line.slice(offset, offset + 17)); };
    expect((await f.store.read()).accounts[0].credentials!.accessToken).toBe(TOKEN);
    expect(JSON.stringify(f.store.status())).not.toContain(TOKEN); expect(f.launch.mock.calls[0]).not.toContain(TOKEN);
    f.child.reply(f.child.frames.at(-1)!, empty()); expect(f.store.status().state).toBe("unknown");
  });
  it("opens only a host-generated exact official authorization URL through private stdin", async () => {
    const f = fixture(); await f.store.activate(); const url = await browserUrl(f.store);
    expect(await f.store.openBrowser(url)).toEqual({ opened: true }); expect(f.child.frames.at(-1)).toMatchObject({ command: "open-browser", payload: { authorizationUrl: url } });
    expect(f.launch.mock.calls[0][1]).toEqual([]); expect(JSON.stringify(f.store.status())).not.toContain(url);
    for (const [key, value] of [["redirect_uri", "http://localhost:1455/auth/callback"], ["ext_agent_host_id", "foreign-host"],
      ["client_id", "foreign-client"], ["scope", "openid"], ["state", "short"], ["resource", "https://foreign.example"]]) {
      const forged = new URL(url); forged.searchParams.set(key, value);
      await expect(f.store.openBrowser(forged.href)).rejects.toMatchObject({ code: "invalid" });
    }
    const extra = new URL(url); extra.searchParams.set("force_reconsent", "true"); await expect(f.store.openBrowser(extra.href)).rejects.toMatchObject({ code: "invalid" });
    expect(commands(f).filter(v => v === "open-browser")).toHaveLength(1);
  });
  it("aborted browser submission closes/fences unknown; repeated close retires once even without activation", async () => {
    const f = fixture(); await f.store.activate(); const url = await browserUrl(f.store); f.child.handler = () => {};
    const controller = new AbortController(), pending = f.store.openBrowser(url, controller.signal); controller.abort();
    await expect(pending).rejects.toMatchObject({ code: "unknown" }); f.store.close(); f.store.close(); expect(f.fence).toHaveBeenCalledTimes(1);
    const inactive = fixture(); inactive.store.close(); inactive.store.close(); expect(inactive.fence).toHaveBeenCalledTimes(1);
    expect(inactive.launch).not.toHaveBeenCalled(); expect(inactive.store.available()).toBe(false);
  });
});
