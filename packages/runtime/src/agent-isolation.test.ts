import { afterEach, expect, test } from "vitest";
import { mkdtempSync, mkdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
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
test("policy exposes only scope directories, immutable runtime reads and exact host broker ports", () => {
  const { scope, runtime } = fixture();
  const launch = isolatedAgentLaunch(scope, { ...runtime, brokerPorts: [32145] }, "darwin");
  expect(launch.command).toBe("/usr/bin/sandbox-exec");
  expect(launch.policy).toContain("(deny default)");
  expect(launch.policy).toContain('remote tcp "127.0.0.1:32145"');
  expect(launch.policy).not.toContain("(allow network*)");
  expect(launch.policy).not.toContain("(allow mach-lookup)");
  expect(launch.isolation).toMatchObject({ backend: "macos-seatbelt-v1", agentId: "alice" });
  expect(launch.isolation.policyDigest).toMatch(/^[a-f0-9]{64}$/);
});
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
