/** Actual Hermes adapter serve() and HarnessProcess pipes + canonical SQL.
 * Native gateway below the adapter is deterministic; NOT Python/live-provider proof. */
import { expect, test } from "vitest";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { HarnessProcess } from "./harness-process.js";
import { WorkerMemory } from "./worker-memory.js";
import { parseWorkerMemoryEnvelope, workerMemoryTools } from "./worker-tools.js";

test("real Hermes-generated memory RPC IDs round-trip through the strict host process and SQL capability", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-worker-hermes-"))), workspace = join(root, "workspace");
  mkdirSync(workspace);
  const memory = new WorkerMemory(join(root, "sql"), id => ["alice", "bob"].includes(id));
  memory.bind("alice").write("note", "HERMES_ADAPTER_SYNTHETIC", "write-1");
  const adapter = new URL("../../harness-plugins/hermes/adapter.mjs", import.meta.url).href;
  // This fixture's attestation is a protocol value only. The separate relay test
  // launches under actual Seatbelt and proves the SQL file itself is inaccessible.
  const isolation = { backend: "macos-seatbelt-v1", agentId: "alice", policyDigest: "a".repeat(64) };
  const p = new HarnessProcess({ pluginId: "hermes", upstreamVersion: "0.21.5", command: process.execPath,
    initialize: { workerMemory: true, agentId: "alice", isolation, workspace,
      scope: { allowedTools: ["memory"], directories: [{ path: workspace, access: "write" }], workspace, memoryDir: join(root, "ungranted-native-memory") },
      platform: { team: false, computer: false, peers: [] } },
    workerTool: (method, params, signal) => {
      const envelope = parseWorkerMemoryEnvelope(params);
      expect(envelope.execution).toEqual({ sessionId: "durable-1", runId: "run-1", attemptId: "attempt-1" });
      return workerMemoryTools(memory.bind("alice"), () => {}, async () => { throw new Error("No sharing approval in this fixture"); })(method, envelope.request, signal);
    },
    args: ["--input-type=module", "-e", `
      import {serve} from ${JSON.stringify(adapter)};
      const gateway = {
        closed:false, nextSeq:0,
        onFrame(fn){this.frame=fn}, onClose(fn){this.close=fn},
        event(type,payload){this.frame({jsonrpc:'2.0',method:'event',params:{type,payload,session_id:'live-1',seq:++this.nextSeq}})},
        async call(method,params){
          if(method==='client.capabilities')return {server_requests:true};
          if(method==='session.create')return {session_id:'live-1',stored_session_id:'durable-1',info:{},messages:[]};
          if(method==='session.activate')return {running:false,inflight:null};
          if(method==='prompt.submit'){
            setImmediate(()=>{this.event('tool.start',{name:'worker_memory',tool_id:'native-tool-1'});
              this.frame({jsonrpc:'2.0',id:'native-memory-1',method:'yorozu.worker_memory',params:{session_id:'live-1',agent_session_id:'durable-1',tool_call_id:'native-tool-1',action:'read',ownerId:'alice',key:'note'}})});
            return {status:'streaming'};
          }
          throw Error('Unexpected synthetic gateway method');
        },
        respond(id,result,error){this.event('message.complete',{status:'complete',text:JSON.stringify({id,result,error})})},
        async shutdown(){this.closed=true;this.close('synthetic gateway closed')}
      };
      serve(process.stdin,process.stdout,{launch:async()=>({gateway,authAvailable:true})});
    `] });
  try {
    expect((await p.start()).workerMemory).toBe(true);
    const currency = { conversationId: "worker-conversation", bindingId: "binding-1", runId: "run-1", attemptId: "attempt-1" };
    expect(await p.request("session.open", currency)).toEqual({ sessionId: "durable-1" });
    let timer: NodeJS.Timeout | undefined;
    const terminal = new Promise<any>((resolve, reject) => {
      timer = setTimeout(() => reject(new Error("Real adapter memory request did not round-trip")), 4000);
      p.listeners.add(event => { if (event.kind === "turn.terminal") resolve(event); });
    });
    try {
      expect(await p.request("turn.submit", { ...currency, text: "synthetic native tool call" })).toEqual({ status: "accepted" });
      expect(JSON.parse((await terminal).data.text)).toEqual({ id: "native-memory-1", result: { value: "HERMES_ADAPTER_SYNTHETIC" } });
      expect(p.unavailable).toBe(false);
    } finally { clearTimeout(timer); }
  } finally { await p.close(); memory.close(); rmSync(root, { recursive: true, force: true }); }
});
