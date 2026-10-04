import { afterEach, expect, test, vi } from "vitest";
import { HarnessProcess } from "./harness-process.js";
import * as listenerApi from "./agent-listener.js";

const processes: HarnessProcess[] = [];
afterEach(async () => { for (const p of processes.splice(0)) await p.close(); vi.restoreAllMocks(); });
const capabilities = { backgroundTasks: true, targetedSteer: true, taskStop: true, approvals: true, reconnect: true, attachments: false };
function peer(scoped = false, wrongIdentity = false): HarnessProcess {
  const isolation = { backend: "macos-seatbelt-v1", agentId: "alice", policyDigest: "a".repeat(64) };
  const p = new HarnessProcess({ pluginId: "hermes", upstreamVersion: "fixture", command: process.execPath, initialize: scoped ? { agentId: "alice", isolation } : {},
    args: ["--input-type=module", "-e", `import{createInterface}from'node:readline';let init=0,opens=0;const send=f=>process.stdout.write(JSON.stringify(f)+'\\n');
      createInterface({input:process.stdin}).on('line',line=>{const f=JSON.parse(line);const reply=result=>send({jsonrpc:'2.0',id:f.id,result});
      if(f.method==='initialize'){init++;return reply({protocolVersion:1,pluginId:'hermes',upstreamVersion:'fixture',capabilities:${JSON.stringify(capabilities)},agentId:${JSON.stringify(wrongIdentity ? "bob" : "alice")},isolation:${JSON.stringify(isolation)}})}
      if(f.method==='session.open'){opens++;if(opens!==1)process.exit(9);return setTimeout(()=>{opens--;reply({sessionId:'owned-'+f.params.conversationId})},30)}
      if(f.method==='count')return reply({init});if(f.method==='shutdown'){reply({});process.exit(0)}});`] });
  processes.push(p); return p;
}
test("concurrent startup is memoized and native session opens are serialized", async () => {
  const p = peer(true); const first = p.start(), second = p.start(); expect(first).toBe(second);
  await Promise.all([first, second]); expect(await p.request("count", {})).toEqual({ init: 1 });
  const receipts = await Promise.all([p.request("session.open", { conversationId: "one" }), p.request("session.open", { conversationId: "two" })]);
  expect(receipts).toEqual([{ sessionId: "owned-one" }, { sessionId: "owned-two" }]);
  expect(await p.start()).toBe(await first);
});
test("scoped startup refuses a ready receipt for another agent before any session or turn", async () => {
  const p = peer(true, true); await expect(p.start()).rejects.toThrow("scoped agent identity");
  await expect(p.request("session.open", { conversationId: "one" })).rejects.toThrow("unavailable");
});


test("unminted listener leases and caller-provided descriptor metadata cannot launch a process", async () => {
  const raw = peer(true); raw.configuration.initialize.gatewayListener = { transport: "inherited-fd-v1", fd: 3, host: "127.0.0.1", port: 52435 };
  await expect(raw.start()).rejects.toThrow("synthesized by the host"); expect(raw.unavailable).toBe(true);
  const forged = peer(true); forged.configuration.pluginId = "openclaw";
  forged.configuration.inheritedListeners = [{ version: 1, id: "forged", agentId: "alice", host: "127.0.0.1", port: 52435 } as any];
  await expect(forged.start()).rejects.toThrow("not minted"); expect(forged.unavailable).toBe(true);
});

test("listener handoff attaches the actual spawn before initialize and serializes only the child descriptor", async () => {
  // Scripted capability boundary; actual socket authority is tested by agent-listener,
  // separately. This verifies process supervision without requesting any network access.
  const consumed = { value: false }, lease = { agentId: "alice", port: 52435 } as any;
  const afterSpawn = vi.fn(async (child: any) => { expect(child.pid).toBeGreaterThan(0); consumed.value = true; });
  const release = vi.fn(async () => {});
  vi.spyOn(listenerApi, "prepareHostListenerTransfer").mockReturnValue({ descriptors: [{ leaseId: "opaque", agentId: "alice", host: "127.0.0.1", port: 52435, fd: 3, stdioFd: 0 }], afterSpawn, release });
  const isolation = { backend: "macos-seatbelt-v1", agentId: "alice", policyDigest: "a".repeat(64) };
  const p = new HarnessProcess({ pluginId: "openclaw", upstreamVersion: "fixture", command: process.execPath, initialize: { agentId: "alice", isolation }, inheritedListeners: [lease],
    args: ["--input-type=module", "-e", `import{createInterface}from'node:readline';let params;
      const reply=(id,result)=>process.stdout.write(JSON.stringify({jsonrpc:'2.0',id,result})+'\\n');
      createInterface({input:process.stdin}).on('line',line=>{const f=JSON.parse(line);
      if(f.method==='initialize'){params=f.params;reply(f.id,{protocolVersion:1,pluginId:'openclaw',upstreamVersion:'fixture',capabilities:${JSON.stringify(capabilities)},agentId:'alice',isolation:${JSON.stringify(isolation)}})}
      else if(f.method==='inspect')reply(f.id,params);else if(f.method==='shutdown'){reply(f.id,{});process.exit(0)}});`] });
  processes.push(p); await p.start(); expect(consumed.value).toBe(true); expect(afterSpawn).toHaveBeenCalledTimes(1);
  const actual = await p.request("inspect", {});
  expect(actual.gatewayListener).toEqual({ transport: "inherited-fd-v1", fd: 3, host: "127.0.0.1", port: 52435 });
  expect(actual.gatewayPort).toBe(52435); expect(JSON.stringify(actual)).not.toMatch(/stdioFd|leaseId|inheritedListeners/);
  await p.close(); expect(release).toHaveBeenCalled();
});
