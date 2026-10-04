import { afterEach, expect, test } from "vitest";
import { mkdtempSync, mkdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { createConnection, createServer, type Server } from "node:net";
import { join } from "node:path";
import { tmpdir, networkInterfaces } from "node:os";
import { isolatedAgentLaunch } from "./agent-isolation.js";
import { PersonAgentStore } from "./agent-store.js";

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
function fixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-agent-isolation-"))); roots.push(root);
  const store = new PersonAgentStore(join(root, "state"));
  store.create({ id: "alice", name: "Alice", role: "Writer", pluginId: "hermes", allowedTools: ["file", "terminal"] }, 0);
  store.create({ id: "bob", name: "Bob", role: "Researcher", pluginId: "hermes", allowedTools: ["file", "memory"] }, 1);
  const runtimeDir = join(root, "vendor-runtime"); mkdirSync(runtimeDir);
  return { root, store, scope: store.resolveScope("alice"), runtime: { command: process.execPath,
    args: [] as string[], readPaths: [] as string[], runtimeDir, brokerPorts: [] as number[] } };
}
test("unsupported enforcement fails closed, and runtime dependency ancestors cannot expose private agent state", () => {
  const { root, store, scope, runtime } = fixture();
  expect(() => isolatedAgentLaunch(scope, runtime, "linux")).toThrow("cannot enforce");
  expect(() => isolatedAgentLaunch(scope, { ...runtime, readPaths: [root] }, "darwin")).toThrow("excluded private state");
  expect(() => isolatedAgentLaunch(scope, { ...runtime, readPaths: [store.paths("bob").memoryDir] }, "darwin")).toThrow("excluded private state");
  expect(() => isolatedAgentLaunch(scope, { ...runtime, runtimeDir: root }, "darwin")).toThrow("excluded private root");
  expect(() => isolatedAgentLaunch(scope, { ...runtime, brokerPorts: [80] }, "darwin")).toThrow("broker port");
});
test("policy exposes only scope directories, immutable runtime reads and exact same-Mac broker ports", () => {
  const { scope, runtime } = fixture();
  const launch = isolatedAgentLaunch(scope, { ...runtime, brokerPorts: [32145] }, "darwin");
  expect(launch.command).toBe("/usr/bin/sandbox-exec");
  expect(launch.policy).toContain("(deny default)");
  expect(launch.policy).toContain('remote tcp "localhost:32145"');
  expect(launch.policy).not.toContain("(allow network*)");
  expect(launch.policy).not.toContain("(allow mach-lookup)");
  expect(launch.isolation).toMatchObject({ backend: "macos-seatbelt-v1", agentId: "alice" });
  expect(launch.isolation.policyDigest).toMatch(/^[a-f0-9]{64}$/);
  expect(launch.policy).not.toContain("(allow network-bind");
});
test("listener requests are bounded and fail closed because peer confinement is unsupported", () => {
  const { scope, runtime } = fixture();
  for (const listenerPorts of [[0], [80], [-1], [65536], [NaN], [1234.5], ["32145"], [1234, 2345, 3456, 4567, 5678], null])
    expect(() => isolatedAgentLaunch(scope, { ...runtime, listenerPorts: listenerPorts as any }, "darwin")).toThrow("listener port");
  expect(() => isolatedAgentLaunch(scope, { ...runtime, listenerPorts: [32146] }, "darwin")).toThrow("pinned to numeric loopback");
  expect(() => isolatedAgentLaunch(scope, { ...runtime, brokerPorts: [32145], listenerPorts: [32146, 32146], listenerHost: "127.0.0.1" }, "darwin")).toThrow("cannot enforce loopback listener peers");
  const launch = isolatedAgentLaunch(scope, { ...runtime, brokerPorts: [32145], listenerPorts: [] }, "darwin");
  expect(launch.policy).not.toMatch(/\(allow network\*|\(allow network-(?:bind|inbound)\)|\*:\*/);
  expect(launch.policy).not.toContain("0.0.0.0");
  expect(launch.policy).not.toContain("::1");
  expect(launch.isolation.policyDigest).toBe(isolatedAgentLaunch(scope, { ...runtime, brokerPorts: [32145] }, "darwin").isolation.policyDigest);
});

async function listen(server: Server, host = "127.0.0.1"): Promise<number> {
  await new Promise<void>((resolve, reject) => { server.once("error", reject); server.listen({ host, port: 0 }, resolve); });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("Synthetic TCP listener missing numeric port");
  return address.port;
}
function exchange(host: string, port: number): Promise<{ data?: string; error?: string }> {
  return new Promise(resolve => {
    let data = "";
    const socket = createConnection({ host, port });
    socket.setTimeout(1500, () => { socket.destroy(); resolve({ error: "TIMEOUT" }); });
    socket.on("data", chunk => { data += chunk; });
    socket.once("error", error => resolve({ error: (error as NodeJS.ErrnoException).code }));
    socket.once("end", () => resolve({ data }));
  });
}
function closeServer(server: Server): Promise<void> {
  return new Promise(resolve => { server.close(() => resolve()); });
}
// Synthetic same-Mac TCP only: no Unix sockets, external hosts, authentication or harness/model execution.
test.skipIf(process.platform !== "darwin" || process.env.YOROZU_TEST_AGENT_SANDBOX !== "1")(
  "kernel enforces broker ports and reproduces why native listener launch is gated", async () => {
    const { store, scope, runtime } = fixture();
    const workspace = store.paths("alice").workspace;
    let brokerHits = 0, wrongBrokerHits = 0;
    const broker = createServer(socket => { brokerHits++; socket.end("broker-ok"); });
    const wrongBroker = createServer(socket => { wrongBrokerHits++; socket.end("wrong-broker"); });
    const listenerReservation = createServer(), wrongListenerReservation = createServer();
    const baseline = createServer(socket => socket.end("baseline-ok"));
    const all = [broker, wrongBroker, listenerReservation, wrongListenerReservation, baseline];
    let child: ReturnType<typeof spawn> | undefined;
    try {
      const brokerPort = await listen(broker, "0.0.0.0"), wrongBrokerPort = await listen(wrongBroker);
      const listenerPort = await listen(listenerReservation), wrongListenerPort = await listen(wrongListenerReservation);
      await closeServer(listenerReservation); await closeServer(wrongListenerReservation);
      const nonLoopback = Object.values(networkInterfaces()).flat().find(address => address?.family === "IPv4" && !address.internal)?.address;
      if (!nonLoopback) throw new Error("No local non-loopback IPv4 interface; inbound confinement cannot be verified");
      expect(await exchange(nonLoopback, brokerPort)).toEqual({ data: "broker-ok" });
      await new Promise<void>((resolve, reject) => { baseline.once("error", reject); baseline.listen({ host: "0.0.0.0", port: 0 }, resolve); });
      const baselineAddress = baseline.address();
      if (!baselineAddress || typeof baselineAddress === "string") throw new Error("Baseline listener failed");
      expect(await exchange(nonLoopback, baselineAddress.port)).toEqual({ data: "baseline-ok" });
      const probe = join(workspace, "network-probe.mjs");
      writeFileSync(probe, `import net from 'node:net';import cp from 'node:child_process';
        const ports=${JSON.stringify({ brokerPort, wrongBrokerPort, listenerPort, wrongListenerPort })};
        const report={};
        async function connect(port,host='127.0.0.1'){return await new Promise(resolve=>{
          let data='';const socket=net.createConnection({host,port});
          socket.setTimeout(1500,()=>{socket.destroy();resolve({error:'TIMEOUT'})});
          socket.on('data',chunk=>data+=chunk);socket.once('error',error=>resolve({error:error.code}));socket.once('end',()=>resolve({data}));
        })}
        async function bind(port,host){return await new Promise(resolve=>{
          const server=net.createServer();server.once('error',error=>resolve({error:error.code}));
          server.listen({host,port},()=>server.close(()=>resolve({bound:true})));
        })}
        report.allowedBroker=await connect(ports.brokerPort);
        report.deniedBroker=await connect(ports.wrongBrokerPort);
        report.allowedLocalAddressBroker=await connect(ports.brokerPort,${JSON.stringify(nonLoopback)});
        const nested=cp.spawnSync(process.execPath,['-e',\`const net=require('node:net');
          async function connect(port){return await new Promise(resolve=>{let data='';const socket=net.createConnection({host:'127.0.0.1',port});
            socket.setTimeout(1500,()=>{socket.destroy();resolve({error:'TIMEOUT'})});socket.on('data',chunk=>data+=chunk);
            socket.once('error',error=>resolve({error:error.code}));socket.once('end',()=>resolve({data}));})}
          async function bind(){return await new Promise(resolve=>{const server=net.createServer();server.once('error',error=>resolve({error:error.code}));
            server.listen({host:'127.0.0.1',port:\${ports.listenerPort}},()=>server.close(()=>resolve({bound:true})));})}
          (async()=>console.log(JSON.stringify({allowedBroker:await connect(\${ports.brokerPort}),deniedBroker:await connect(\${ports.wrongBrokerPort}),listener:await bind()})))();\`],
          {encoding:'utf8',timeout:5000});
        report.inherited=nested.status===0?JSON.parse(nested.stdout):{error:nested.stderr,status:nested.status};
        report.deniedListener=await bind(ports.wrongListenerPort,'127.0.0.1');
        report.wildcardBind=await bind(ports.listenerPort,'0.0.0.0');
        report.ipv6LoopbackBind=await bind(ports.listenerPort,'::1');
        if(process.argv[2]==='broker-only'){console.log(JSON.stringify(report));process.exit(0)}
        const listener=net.createServer(socket=>{
          const peer=socket.remoteAddress||'';
          if(peer==='127.0.0.1'||peer==='::1'||peer==='::ffff:127.0.0.1')report.listenerAccepted=true;
          else report.nonLoopbackAccepted=true;
          socket.end('listener-ok');
        });
        listener.once('error',error=>{console.error(error.code);process.exit(1)});
        process.stdin.once('data',()=>listener.close(()=>{console.log(JSON.stringify({type:'complete',report}));process.stdin.destroy()}));
        listener.listen({host:'0.0.0.0',port:ports.listenerPort},()=>console.log(JSON.stringify({type:'listener-ready'})));
      `);
      expect(() => isolatedAgentLaunch(scope, { ...runtime, args: [probe], brokerPorts: [brokerPort], listenerPorts: [listenerPort], listenerHost: "127.0.0.1" })).toThrow("cannot enforce loopback listener peers");
      const launch = isolatedAgentLaunch(scope, { ...runtime, args: [probe], brokerPorts: [brokerPort] });
      const productionResult = await new Promise<any>((resolve, reject) => {
        let output = "", errorOutput = "";
        child = spawn(launch.command, [...launch.args, "broker-only"], { cwd: workspace,
          env: { PATH: "/usr/bin:/bin", HOME: runtime.runtimeDir }, stdio: ["ignore", "pipe", "pipe"] });
        const timeout = setTimeout(() => { child?.kill(); reject(new Error(`Production broker probe timed out: ${errorOutput}`)); }, 5000);
        child.stdout!.on("data", chunk => { output += chunk; });
        child.stderr!.on("data", chunk => { errorOutput += chunk; });
        child.once("error", error => { clearTimeout(timeout); reject(error); });
        child.once("close", code => {
          clearTimeout(timeout);
          if (code !== 0) reject(new Error(`Production broker probe failed (${code}): ${errorOutput}`));
          else { try { resolve(JSON.parse(output)); } catch (error) { reject(error); } }
        });
      });
      expect(productionResult.allowedBroker).toEqual({ data: "broker-ok" });
      expect(productionResult.allowedLocalAddressBroker).toEqual({ data: "broker-ok" });
      expect(productionResult.inherited.allowedBroker).toEqual({ data: "broker-ok" });
      for (const key of ["deniedBroker", "deniedListener", "wildcardBind", "ipv6LoopbackBind"])
        expect(["EPERM", "EACCES"], JSON.stringify(productionResult)).toContain(productionResult[key].error);
      expect(["EPERM", "EACCES"]).toContain(productionResult.inherited.deniedBroker.error);
      expect(["EPERM", "EACCES"]).toContain(productionResult.inherited.listener.error);
      // Test-owned synthetic candidate only: never returned by the production launcher.
      // Characterize the kernel limitation rather than asserting a false peer boundary.
      const candidatePolicy = launch.policy + `(allow network-bind network-inbound (local tcp "localhost:${listenerPort}"))\n`;
      const candidateArgs = ["-p", candidatePolicy, ...launch.args.slice(2)];
      let listenerReply = "", nonLoopbackReply: { data?: string; error?: string } = {}, stderr = "", stdout = "";
      const result = await new Promise<any>((resolve, reject) => {
        child = spawn(launch.command, candidateArgs, { cwd: workspace, env: { PATH: "/usr/bin:/bin", HOME: runtime.runtimeDir }, stdio: ["pipe", "pipe", "pipe"] });
        const timeout = setTimeout(() => { child?.kill(); reject(new Error(`Kernel network probe timed out: ${stderr}`)); }, 15_000);
        let buffered = "", completed: any;
        child.stderr!.on("data", chunk => { stderr += chunk; });
        child.stdout!.on("data", chunk => {
          stdout += chunk; buffered += chunk;
          while (buffered.includes("\n")) {
            const index = buffered.indexOf("\n"), line = buffered.slice(0, index); buffered = buffered.slice(index + 1);
            try {
              const frame = JSON.parse(line);
              if (frame.type === "listener-ready") {
                void (async () => {
                  nonLoopbackReply = await exchange(nonLoopback, listenerPort);
                  listenerReply = (await exchange("127.0.0.1", listenerPort)).data ?? "";
                  child?.stdin?.end("finish\n");
                })().catch(error => { child?.kill(); reject(error); });
              } else if (frame.type === "complete") completed = frame.report;
            } catch (error) { child?.kill(); reject(error); }
          }
        });
        child.once("error", error => { clearTimeout(timeout); reject(error); });
        child.once("close", code => {
          clearTimeout(timeout);
          if (code !== 0 || !completed) reject(new Error(`Kernel network probe failed (${code}): ${stderr} ${stdout}`));
          else resolve(completed);
        });
      });
      expect(result.allowedBroker).toEqual({ data: "broker-ok" });
      expect(result.inherited.allowedBroker).toEqual({ data: "broker-ok" });
      expect(["EPERM", "EACCES"], JSON.stringify(result)).toContain(result.inherited.deniedBroker.error);
      expect(result.inherited.listener).toEqual({ bound: true });
      expect(result.allowedLocalAddressBroker).toEqual({ data: "broker-ok" });
      for (const key of ["deniedBroker", "deniedListener"]) expect(["EPERM", "EACCES"], JSON.stringify(result)).toContain(result[key].error);
      expect(result.wildcardBind).toEqual({ bound: true }); expect(result.ipv6LoopbackBind).toEqual({ bound: true });
      expect(result.nonLoopbackAccepted).toBe(true); expect(nonLoopbackReply).toEqual({ data: "listener-ok" });
      expect(result.listenerAccepted).toBe(true); expect(listenerReply).toBe("listener-ok");
      expect(brokerHits).toBe(7); expect(wrongBrokerHits).toBe(0);
    } finally { child?.kill(); await Promise.all(all.map(closeServer)); }
  }, 20_000);
// This invokes the actual kernel sandbox, including a real inherited shell process.
// Explicit test opt-in is needed where process sandboxing requires execution approval.
test.skipIf(process.platform !== "darwin" || process.env.YOROZU_TEST_AGENT_SANDBOX !== "1")(
  "kernel blocks another agent's files and memory, traversal, symlinks and subprocess escape", () => {
    const { store, scope, runtime } = fixture();
    const a = store.paths("alice"), b = store.paths("bob");
    writeFileSync(join(a.workspace, "own.txt"), "Alice fixture");
    writeFileSync(join(b.workspace, "private.txt"), "Bob private file fixture");
    writeFileSync(join(b.memoryDir, "private.txt"), "Bob private memory fixture");
    symlinkSync(join(b.workspace, "private.txt"), join(a.workspace, "link"));
    const probe = join(a.workspace, "probe.mjs");
    writeFileSync(probe, `import fs from 'node:fs';import cp from 'node:child_process';
      const own=${JSON.stringify(join(a.workspace, "own.txt"))};
      const paths=${JSON.stringify([join(b.workspace, "private.txt"), join(b.memoryDir, "private.txt"), a.workspace + "/../../bob/workspace/private.txt", join(a.workspace, "link")])};
      const result={own:fs.readFileSync(own,'utf8'),denied:[]};
      for(const path of paths){try{fs.readFileSync(path);result.denied.push(false)}catch(e){result.denied.push(['EPERM','EACCES'].includes(e.code))}}
      const child=cp.spawnSync('/bin/cat',[paths[0]],{encoding:'utf8'});
      result.childDenied=child.status!==0&&!child.stdout;console.log(JSON.stringify(result));`);
    const launch = isolatedAgentLaunch(scope, { ...runtime, args: [probe] });
    const result = spawnSync(launch.command, launch.args, { cwd: a.workspace,
      env: { PATH: "/usr/bin:/bin", HOME: runtime.runtimeDir }, encoding: "utf8", timeout: 15_000 });
    expect(result.status, result.stderr).toBe(0);
    expect(JSON.parse(result.stdout)).toEqual({ own: "Alice fixture", denied: [true, true, true, true], childDenied: true });
  });
