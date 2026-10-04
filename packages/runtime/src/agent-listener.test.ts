import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { ChildProcess, spawn } from "node:child_process";
import { EventEmitter } from "node:events";
import fs, { mkdtempSync, mkdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import net from "node:net";
import http from "node:http";
import { join } from "node:path";
import { tmpdir, networkInterfaces } from "node:os";
import { acquireHostListener, prepareHostListenerTransfer, releaseHostListener, validateHostListeners } from "./agent-listener.js";
import { isolatedAgentLaunch } from "./agent-isolation.js";
import { PersonAgentStore } from "./agent-store.js";

describe("host listener capabilities and one-shot lifecycle", () => {
  const handles = new Map<number, { address: string; family: "IPv4"; port: number; closed: boolean }>();
  const servers: FakeServer[] = [];
  let nextFd = 700, nextPort = 45000, failListen = false;
  class FakeBound {
    readonly descriptor: number;
    constructor(options: { host: string; port: number }) {
      this.descriptor = nextFd++;
      handles.set(this.descriptor, { address: options.host, family: "IPv4", port: options.port || nextPort++, closed: false });
    }
    fd(): number { return this.descriptor; }
    address() { const { closed: _closed, ...address } = handles.get(this.descriptor)!; return address; }
    close(): void { handles.get(this.descriptor)!.closed = true; }
  }
  class FakeServer extends EventEmitter {
    listening = false; closes = 0; bound?: FakeBound;
    listen(bound: FakeBound, callback: () => void): this {
      this.bound = bound;
      queueMicrotask(() => {
        if (failListen) { this.emit("error", new Error("listen fixture failure")); return; }
        this.listening = true; callback();
      });
      return this;
    }
    address() { return this.listening ? this.bound!.address() : null; }
    close(callback: (error?: Error) => void): this {
      this.closes++; this.listening = false;
      if (this.bound) this.bound.close();
      queueMicrotask(() => callback()); return this;
    }
  }
  beforeEach(() => {
    handles.clear(); servers.length = 0; nextFd = 700; nextPort = 45000; failListen = false;
    vi.spyOn(net, "BoundSocket").mockImplementation(function (options: { host: string; port: number }) { return new FakeBound(options); } as any);
    vi.spyOn(net, "createServer").mockImplementation(() => { const server = new FakeServer(); servers.push(server); return server as any; });
    const originalStat = fs.fstatSync;
    vi.spyOn(fs, "fstatSync").mockImplementation(((fd: number, options: any) => {
      const handle = handles.get(fd);
      if (!handle) return originalStat(fd, options);
      if (handle.closed) throw Object.assign(new Error("closed fixture descriptor"), { code: "EBADF" });
      return { isSocket: () => true };
    }) as any);
  });
  afterEach(() => { vi.restoreAllMocks(); });
  test("minting is numeric loopback only; forged metadata, wrong agent and duplicates cannot confer authority", async () => {
    const lease = await acquireHostListener("alice", 45123);
    expect(lease).toMatchObject({ version: 1, agentId: "alice", host: "127.0.0.1", port: 45123 });
    expect(Object.isFrozen(lease)).toBe(true); expect("fd" in lease).toBe(false);
    expect(validateHostListeners([lease], "alice")).toEqual([lease]);
    expect(() => validateHostListeners([{ ...lease }], "alice")).toThrow("not minted");
    expect(() => validateHostListeners([JSON.parse(JSON.stringify(lease))], "alice")).toThrow("not minted");
    expect(() => validateHostListeners([lease], "bob")).toThrow("another agent");
    expect(() => validateHostListeners([lease, lease], "alice")).toThrow("Duplicate");
    expect(() => validateHostListeners([lease, lease, lease, lease, lease], "alice")).toThrow("selection");
    expect(() => validateHostListeners({} as any, "alice")).toThrow("selection");
    expect(validateHostListeners([lease], "alice")).toEqual([lease]);
    await releaseHostListener(lease);
  });
  test("unsupported API, invalid IDs and invalid ports fail before acquisition; acquisition error closes its parent", async () => {
    for (const id of ["../alice", "", "Alice", "a/b"]) await expect(acquireHostListener(id)).rejects.toThrow("identity");
    for (const port of [0, 80, -1, 65536, 1234.5, NaN, "45123"]) await expect(acquireHostListener("alice", port as any)).rejects.toThrow("port");
    const saved = net.BoundSocket;
    try { (net as any).BoundSocket = undefined; await expect(acquireHostListener("alice")).rejects.toThrow("cannot acquire"); }
    finally { (net as any).BoundSocket = saved; }
    failListen = true; await expect(acquireHostListener("alice")).rejects.toThrow("listen fixture failure");
    expect(servers.at(-1)?.closes).toBe(1); expect([...handles.values()].every(handle => handle.closed)).toBe(true);
  });
  test("release is idempotent and stale validation does not dereference the closed or reused FD", async () => {
    const lease = await acquireHostListener("alice"); await releaseHostListener(lease); await releaseHostListener(lease);
    const stat = vi.mocked(fs.fstatSync); stat.mockClear();
    expect(() => validateHostListeners([lease], "alice")).toThrow("stale"); expect(stat).not.toHaveBeenCalled();
    expect(servers[0].closes).toBe(1);
  });
  test("one-shot descriptor slots are frozen and consumption waits for the real spawn receipt", async () => {
    const first = await acquireHostListener("alice"), second = await acquireHostListener("alice");
    const transfer = prepareHostListenerTransfer([first, second], "alice");
    expect(Object.isFrozen(transfer)).toBe(true); expect(Object.isFrozen(transfer.descriptors)).toBe(true);
    expect(transfer.descriptors.map(value => [value.fd, value.stdioFd, value.agentId])).toEqual([[3, 700, "alice"], [4, 701, "alice"]]);
    expect(transfer.descriptors.every(Object.isFrozen)).toBe(true);
    expect(() => prepareHostListenerTransfer([first], "alice")).toThrow("stale");
    const child = new ChildProcess(), pending = transfer.afterSpawn(child);
    expect(servers.every(server => server.listening)).toBe(true);
    (child as any).pid = 9876; child.emit("spawn"); await pending;
    expect(servers.every(server => !server.listening && server.closes === 1)).toBe(true);
    const stat = vi.mocked(fs.fstatSync); stat.mockClear();
    expect(() => validateHostListeners([first], "alice")).toThrow("stale"); expect(stat).not.toHaveBeenCalled();
    await expect(transfer.afterSpawn(child)).rejects.toThrow("already been settled");
    await transfer.release(); await releaseHostListener(first); expect(servers.every(server => server.closes === 1)).toBe(true);
  });
  test("asynchronous and synchronous spawn failure close every parent descriptor and forbid replay", async () => {
    const lease = await acquireHostListener("alice"), transfer = prepareHostListenerTransfer([lease], "alice");
    const child = new ChildProcess(), pending = transfer.afterSpawn(child);
    child.emit("error", new Error("spawn fixture failure")); await expect(pending).rejects.toThrow("spawn fixture failure");
    expect(servers[0].closes).toBe(1); await expect(transfer.afterSpawn(child)).rejects.toThrow("already been settled");
    const second = await acquireHostListener("alice"), canceled = prepareHostListenerTransfer([second], "alice");
    await canceled.release(); expect(servers[1].closes).toBe(1); expect(() => validateHostListeners([second], "alice")).toThrow("stale");
    const third = await acquireHostListener("alice"), invalid = prepareHostListenerTransfer([third], "alice");
    await expect(invalid.afterSpawn({ pid: 9876 } as any)).rejects.toThrow("spawn receipt"); expect(servers[2].closes).toBe(1);
  });
  test("canceling one prepared lease cancels the whole transfer; wrong agent leaves valid ownership unchanged", async () => {
    const first = await acquireHostListener("alice"), second = await acquireHostListener("alice");
    expect(() => prepareHostListenerTransfer([first], "bob")).toThrow("another agent");
    const transfer = prepareHostListenerTransfer([first, second], "alice"); await releaseHostListener(first);
    expect(servers.every(server => server.closes === 1)).toBe(true);
    await expect(transfer.afterSpawn(new ChildProcess())).rejects.toThrow("already been settled");
  });
  test("canceling during a pending spawn receipt settles its wait and removes listeners", async () => {
    const lease = await acquireHostListener("alice"), transfer = prepareHostListenerTransfer([lease], "alice");
    const child = new ChildProcess(), pending = transfer.afterSpawn(child);
    const rejected = expect(pending).rejects.toThrow("canceled before spawn receipt");
    await transfer.release(); await rejected;
    expect(child.listenerCount("spawn")).toBe(0); expect(child.listenerCount("error")).toBe(0);
    expect(servers[0].closes).toBe(1); expect(() => validateHostListeners([lease], "alice")).toThrow("stale");
  });
  test("late failed or invalid spawn receipts close the parent without an indefinite wait", async () => {
    const lease = await acquireHostListener("alice"), transfer = prepareHostListenerTransfer([lease], "alice");
    const failed = new ChildProcess(); (failed as any).exitCode = -2;
    await expect(transfer.afterSpawn(failed)).rejects.toThrow("stopped before listener inheritance");
    const second = await acquireHostListener("alice"), invalid = prepareHostListenerTransfer([second], "alice");
    const child = new ChildProcess(); (child as any).pid = -1;
    await expect(invalid.afterSpawn(child)).rejects.toThrow("spawn receipt");
    expect(servers.every(server => server.closes === 1)).toBe(true);
  });
  test("compiler accepts held host leases only and adds exact inbound with no bind permission", async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-listener-policy-")));
    const lease = await acquireHostListener("alice", 45123);
    try {
      const scope = { version: 1 as const, agentId: "alice", revision: 0, chain: ["alice"], allowedTools: [], directories: [], deniedRoots: [] };
      const runtime = { command: process.execPath, args: [], readPaths: [], runtimeDir: root, brokerPorts: [], inheritedListeners: [lease] };
      const launch = isolatedAgentLaunch(scope, runtime);
      expect(launch.policy).toContain('(allow network-inbound (local tcp "localhost:45123"))');
      expect(launch.policy).not.toContain("(allow network-bind"); expect(launch.policy).not.toContain("(allow network-outbound");
      expect(() => isolatedAgentLaunch(scope, { ...runtime, inheritedListeners: [{ ...lease }] })).toThrow("not minted");
      expect(() => isolatedAgentLaunch(scope, { ...runtime, inheritedListeners: [lease, lease] })).toThrow("Duplicate");
      expect(() => isolatedAgentLaunch({ ...scope, agentId: "bob", chain: ["bob"] }, runtime)).toThrow("another agent");
      const transfer = prepareHostListenerTransfer([lease], "alice");
      expect(() => isolatedAgentLaunch(scope, runtime)).toThrow("stale"); await transfer.release();
      expect(() => isolatedAgentLaunch(scope, runtime)).toThrow("stale");
    } finally { await releaseHostListener(lease); rmSync(root, { recursive: true, force: true }); }
  });
});

function request(host: string, port: number): Promise<{ status?: number; body?: string; error?: string }> {
  return new Promise(resolve => {
    const req = http.get({ host, port, path: "/", agent: false, headers: { connection: "close" } }, res => {
      let body = ""; res.on("data", chunk => { body += chunk; }); res.once("end", () => resolve({ status: res.statusCode, body }));
    });
    req.setTimeout(1500, () => { req.destroy(); resolve({ error: "TIMEOUT" }); });
    req.once("error", error => resolve({ error: (error as NodeJS.ErrnoException).code }));
  });
}
const close = (server: net.Server): Promise<void> => new Promise(resolve => server.close(() => resolve()));
// Actual production lease + compiler + numeric spawn stdio. Synthetic same-Mac TCP only.
test.skipIf(process.platform !== "darwin" || process.env.YOROZU_TEST_AGENT_SANDBOX !== "1")(
  "kernel serves inherited HTTP only on numeric loopback while denying new binds and private-state escape", async () => {
    const root = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-production-inherited-listener-")));
    const store = new PersonAgentStore(join(root, "state"));
    store.create({ id: "alice", name: "Alice", role: "Fixture", pluginId: "openclaw", allowedTools: ["file", "terminal"] }, 0);
    store.create({ id: "bob", name: "Bob", role: "Private fixture", pluginId: "hermes", allowedTools: ["file", "memory"] }, 1);
    const alice = store.paths("alice"), bob = store.paths("bob");
    const runtimeDir = join(root, "vendor-runtime"); mkdirSync(runtimeDir);
    const own = join(alice.workspace, "own.txt"); writeFileSync(own, "own-fixture");
    const peerFile = join(bob.workspace, "private.txt"), peerMemory = join(bob.memoryDir, "private.txt");
    writeFileSync(peerFile, "private-file-fixture"); writeFileSync(peerMemory, "private-memory-fixture");
    const link = join(alice.workspace, "peer-link"); symlinkSync(peerFile, link);
    const privatePaths = [peerFile, peerMemory, alice.workspace + "/../../bob/workspace/private.txt", link];
    const baseline = http.createServer((_req, res) => res.end("baseline-ok")), reservation = net.createServer();
    const lease = await acquireHostListener("alice");
    let child: ReturnType<typeof spawn> | undefined;
    try {
      const expectedAddress = { address: lease.host, family: "IPv4", port: lease.port };
      await new Promise<void>((resolve, reject) => { reservation.once("error", reject); reservation.listen({ host: "127.0.0.1", port: 0 }, resolve); });
      const reservedAddress = reservation.address(); if (!reservedAddress || typeof reservedAddress === "string") throw new Error("Missing wrong-port fixture");
      const wrongPort = reservedAddress.port; await close(reservation);
      const nonLoopback = Object.values(networkInterfaces()).flat().find(address => address?.family === "IPv4" && !address.internal)?.address;
      if (!nonLoopback) throw new Error("No same-Mac non-loopback interface; cannot verify listener confinement");
      await new Promise<void>((resolve, reject) => { baseline.once("error", reject); baseline.listen({ host: "0.0.0.0", port: 0 }, resolve); });
      const baselineAddress = baseline.address(); if (!baselineAddress || typeof baselineAddress === "string") throw new Error("Missing positive route baseline");
      expect(await request(nonLoopback, baselineAddress.port)).toEqual({ status: 200, body: "baseline-ok" });
      const probe = join(alice.workspace, "inherited-listener-probe.mjs");
      writeFileSync(probe, `import net from 'node:net';import http from 'node:http';import fs from 'node:fs';import cp from 'node:child_process';
        const expected=${JSON.stringify(expectedAddress)},wrongPort=${wrongPort},privatePaths=${JSON.stringify(privatePaths)};
        const report={own:fs.readFileSync(${JSON.stringify(own)},'utf8'),private:[],newBinds:{}};
        for(const path of privatePaths){try{fs.readFileSync(path);report.private.push('ALLOWED')}catch(error){report.private.push(error.code)}}
        const cat=cp.spawnSync('/bin/cat',[privatePaths[0]],{encoding:'utf8'});report.subprocessPrivateDenied=cat.status!==0&&!cat.stdout;
        async function bind(host,port){return await new Promise(resolve=>{const server=net.createServer();
          server.once('error',error=>resolve({error:error.code}));server.listen({host,port},()=>server.close(()=>resolve({bound:true})));})}
        for(const [name,host,port] of [['new127','127.0.0.1',0],['wrongPort','127.0.0.1',wrongPort],['wildcard','0.0.0.0',wrongPort],['ipv6','::1',wrongPort]])report.newBinds[name]=await bind(host,port);
        const grandchild=cp.spawnSync(process.execPath,['-e',\`const net=require('node:net');const server=net.createServer();
          server.once('error',error=>console.log(JSON.stringify({error:error.code})));server.listen({host:'0.0.0.0',port:\${wrongPort}},()=>server.close(()=>console.log(JSON.stringify({bound:true}))));\`],{encoding:'utf8',timeout:5000});
        report.grandchildBind=grandchild.status===0?JSON.parse(grandchild.stdout):{error:grandchild.stderr,status:grandchild.status};
        const server=http.createServer((_req,res)=>{report.requests=(report.requests||0)+1;res.end('child-http-ok')});
        server.once('error',error=>{console.error(JSON.stringify({stage:'fd-adoption',error:error.code,report}));process.exit(1)});
        process.stdin.once('data',()=>{report.addressBeforeClose=server.address();server.close(()=>{console.log(JSON.stringify({type:'complete',report}));process.stdin.destroy()})});
        server.listen({fd:3},()=>{report.inheritedAddress=server.address();
          if(report.inheritedAddress?.address!==expected.address||report.inheritedAddress?.port!==expected.port){console.error('Inherited descriptor address changed');process.exit(1)}
          console.log(JSON.stringify({type:'ready'}));});
      `);
      const launch = isolatedAgentLaunch(store.resolveScope("alice"), { command: process.execPath, args: [probe],
        readPaths: [], runtimeDir, brokerPorts: [], inheritedListeners: [lease] });
      expect(launch.policy).not.toContain("(allow network-bind");
      const transfer = prepareHostListenerTransfer([lease], "alice");
      expect(transfer.descriptors[0]).toMatchObject({ fd: 3, host: "127.0.0.1", port: lease.port, agentId: "alice" });
      let stderr = "", stdout = "", completed: any, loopback: any, nonLoopbackResult: any, parentClosed!: Promise<void>;
      const result = await new Promise<any>((resolve, reject) => {
        try {
          child = spawn(launch.command, launch.args, { cwd: alice.workspace, env: { PATH: "/usr/bin:/bin", HOME: runtimeDir },
            stdio: ["pipe", "pipe", "pipe", transfer.descriptors[0].stdioFd] });
        } catch (error) { void transfer.release(); reject(error); return; }
        parentClosed = transfer.afterSpawn(child);
        const timeout = setTimeout(() => { child?.kill(); reject(new Error(`Inherited lease probe timed out: ${stderr} ${stdout}`)); }, 12_000);
        let buffered = "";
        child.stderr!.on("data", chunk => { stderr += chunk; });
        child.stdout!.on("data", chunk => {
          stdout += chunk; buffered += chunk;
          while (buffered.includes("\n")) {
            const index = buffered.indexOf("\n"), line = buffered.slice(0, index); buffered = buffered.slice(index + 1);
            try {
              const frame = JSON.parse(line);
              if (frame.type === "ready") void (async () => {
                await parentClosed; loopback = await request("127.0.0.1", lease.port);
                nonLoopbackResult = await request(nonLoopback, lease.port); child?.stdin?.end("finish\n");
              })().catch(error => { child?.kill(); reject(error); });
              else if (frame.type === "complete") completed = frame.report;
            } catch (error) { child?.kill(); reject(error); }
          }
        });
        child.once("error", error => { clearTimeout(timeout); reject(error); });
        child.once("close", code => {
          clearTimeout(timeout);
          if (code !== 0 || !completed) reject(new Error(`Inherited lease probe failed (${code}): ${stderr} ${stdout}`)); else resolve(completed);
        });
      });
      expect(result.own).toBe("own-fixture"); expect(result.private).toHaveLength(4);
      for (const error of result.private) expect(["EPERM", "EACCES"]).toContain(error);
      expect(result.subprocessPrivateDenied).toBe(true);
      for (const denied of Object.values(result.newBinds) as any[]) expect(["EPERM", "EACCES"]).toContain(denied.error);
      expect(["EPERM", "EACCES"]).toContain(result.grandchildBind.error);
      expect(result.inheritedAddress).toEqual(expectedAddress); expect(result.addressBeforeClose).toEqual(expectedAddress);
      expect(loopback).toEqual({ status: 200, body: "child-http-ok" });
      expect(nonLoopbackResult).toEqual({ error: "ECONNREFUSED" }); expect(result.requests).toBe(1);
      expect(() => validateHostListeners([lease], "alice")).toThrow("stale");
    } finally { child?.kill(); await releaseHostListener(lease); await Promise.all([close(baseline), close(reservation)]); rmSync(root, { recursive: true, force: true }); }
  }, 15_000);
