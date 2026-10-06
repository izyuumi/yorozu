/** Real bounded child pipes; protocol peer is synthetic, not native/provider proof. */
import { afterEach, expect, test, vi } from "vitest";
import { HarnessProcess, type SupervisedHarnessConfiguration } from "./harness-process.js";
const processes: HarnessProcess[] = [];
afterEach(async () => { for (const p of processes.splice(0)) await p.close(); });
function peer(tool?: SupervisedHarnessConfiguration["workerTool"], mode = "normal") {
  const p = new HarnessProcess({ pluginId: "hermes", upstreamVersion: "synthetic", initialize: { workerMemory: true }, workerTool: tool,
    command: process.execPath, args: ["--input-type=module", "-e", `
      import {createInterface} from 'node:readline';
      const send = f => process.stdout.write(JSON.stringify({jsonrpc:'2.0', ...f})+'\\n'); let waiting;
      createInterface({input:process.stdin}).on('line', line => {const f = JSON.parse(line);
        if(f.method==='initialize') return send({id:f.id,result:{protocolVersion:1,pluginId:'hermes',upstreamVersion:'synthetic',workerMemory:${mode !== "unconfirmed"},capabilities:{backgroundTasks:false,targetedSteer:false,taskStop:false,approvals:true,reconnect:false,attachments:false}}});
        if(f.method==='invoke'){waiting=f.id;send({id:'tool-1',method:'worker.memory',params:f.params});${mode === "duplicate" ? "send({id:'tool-1',method:'worker.memory',params:f.params});" : ""}return;}
        if(f.id==='tool-1' && !f.method) return send({id:waiting,result:{result:f.result,error:f.error}});
        if(f.method==='shutdown'){send({id:f.id,result:{stopped:true}});process.exit(0);}
      });`] });
  processes.push(p); return p;
}
test("only an explicitly configured, acknowledged callback gets bounded child tool requests", async () => {
  const calls = vi.fn(async (_method, _params, _signal) => ({ value: "owned note" }));
  const p = peer(calls); await p.start();
  expect(await p.request("invoke", { action: "read", ownerId: "alice", key: "note" })).toEqual({ result: { value: "owned note" } });
  expect(calls).toHaveBeenCalledOnce(); expect(calls.mock.calls[0][0]).toBe("worker.memory");
  expect(JSON.stringify(p.configuration.initialize)).not.toContain("workerTool");
  const disabled = peer(); await expect(disabled.start()).rejects.toThrow("confirm uniform");
  const unconfirmed = peer(calls, "unconfirmed"); await expect(unconfirmed.start()).rejects.toThrow("confirm uniform");
});
test("tool failures are static and do not leak data or retry", async () => {
  const calls = vi.fn(async () => { throw new Error("SYNTHETIC_PRIVATE_NOTE"); });
  const p = peer(calls); await p.start();
  const reply = await p.request("invoke", { action: "read", ownerId: "bob", key: "note" });
  expect(reply.error.code).toBe(-32001); expect(JSON.stringify(reply)).not.toContain("SYNTHETIC_PRIVATE_NOTE");
  expect(calls).toHaveBeenCalledOnce();
});
test("duplicate transport IDs fence the process rather than dispatch a mutation twice", async () => {
  const calls = vi.fn(async () => ({ ok: true }));
  const p = peer(calls, "duplicate"); await p.start();
  await expect(p.request("invoke", { action: "write", key: "note", body: "text", operationId: "op-1" })).rejects.toThrow("protocol");
  expect(calls.mock.calls.length).toBeLessThanOrEqual(1); expect(p.unavailable).toBe(true);
});
test("closing the process aborts an outstanding privileged tool request", async () => {
  let enter!: () => void; const entered = new Promise<void>(resolve => { enter = resolve; });
  let aborted = false;
  const p = peer(async (_method, _params, signal) => {
    enter(); return new Promise((_resolve, reject) => signal.addEventListener("abort", () => { aborted = true; reject(signal.reason); }, { once: true }));
  });
  await p.start(); const pending = p.request("invoke", { action: "grant", key: "note", toAgentId: "bob", operationId: "grant-1" }).catch(() => undefined);
  await entered; await p.close(); await pending; expect(aborted).toBe(true);
});
