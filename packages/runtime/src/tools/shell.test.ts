import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { defaultTools } from "../index.js";
import { MAX_OUTPUT, execShell, expandHome, runShell, shellTool, truncate } from "./shell.js";

test("returns combined stdout and stderr", async () => {
  expect(await runShell({ cmd: "echo out; echo err 1>&2" })).toBe("out\nerr");
});

test("a non-zero exit is a result, not a throw", async () => {
  const out = await runShell({ cmd: "echo nope 1>&2; exit 3" });
  expect(out).toContain("nope");
  expect(out).toContain("[exit 3]");
});

test("a command with no output says so", async () => {
  expect(await runShell({ cmd: "true" })).toBe("(no output)");
});

test("runs in the given directory", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-shell-"));
  // macOS hands out /var symlinks for temp dirs, so resolve both sides the same way.
  expect(await runShell({ cmd: "pwd -P", cwd: dir })).toBe(
    await runShell({ cmd: `cd ${dir} && pwd -P` }),
  );
  rmSync(dir, { recursive: true, force: true });
});

test("a command that overruns its timeout is killed and says so", async () => {
  expect(await runShell({ cmd: "sleep 5", timeoutMs: 100 })).toContain("killed after 100ms");
});

test("output is truncated to what the model can afford", async () => {
  const out = await runShell({ cmd: "seq 1 20000" });
  expect(out.length).toBeLessThan(MAX_OUTPUT + 100);
  expect(out).toContain("truncated");
});

test("truncate keeps short text and counts what it dropped", () => {
  expect(truncate("short")).toBe("short");
  expect(truncate("abcdef", 3)).toBe("abc\n… truncated, 3 more characters");
});

test("a leading ~ is expanded, a bare one is not", () => {
  expect(expandHome("~/Documents")).toBe(`${homedir()}/Documents`);
  expect(expandHome("~user/x")).toBe("~user/x");
  expect(expandHome("/tmp")).toBe("/tmp");
});

test("the tool refuses an empty command", () => {
  expect(() => shellTool.run({ cmd: "  " })).toThrow("empty");
});

test("the tool passes cwd and the timeout through", async () => {
  expect(String(await shellTool.run({ cmd: "sleep 5", timeoutMs: 100 }))).toContain(
    "killed after 100ms",
  );
  expect(String(await shellTool.run({ cmd: "pwd -P", cwd: "/tmp" }))).toBe(realpathSync("/tmp"));
});

test("the schema names the tool and the one argument the model must supply", () => {
  expect(shellTool.name).toBe("shell");
  const { properties, required } = shellTool.parameters as {
    properties: Record<string, unknown>;
    required: string[];
  };
  expect(required).toEqual(["cmd"]);
  expect(Object.keys(properties)).toEqual(["cmd", "cwd", "timeoutMs"]);
  // Running a command has an effect outside the runtime, so it carries what the card shows.
  expect(shellTool.actionClass).toBe("run-command");
  expect(shellTool.action!({ cmd: "rm -rf /" })).toMatchObject({
    target: "rm -rf /",
    operation: "run",
  });
});

test("a call with no cmd at all never reaches a shell", () => {
  expect(() => shellTool.run({})).toThrow("shell: cmd is empty");
});

test("unicode survives the round trip through the shell", async () => {
  expect(await runShell({ cmd: "printf '%s' '日本語 🎌 ünïcode'" })).toBe("日本語 🎌 ünïcode");
});

test("execShell keeps the exit status beside the output the model reads", async () => {
  expect(await execShell({ cmd: "true" })).toEqual({ output: "(no output)", ok: true });
  expect(await execShell({ cmd: "echo out; exit 2" })).toEqual({ output: "out\n[exit 2]", ok: false });
});

test("aborting kills the command, and the result says it was stopped rather than timed out", async () => {
  const stop = new AbortController();
  const pending = execShell({ cmd: "sleep 5", signal: stop.signal });
  stop.abort();
  expect(await pending).toEqual({ output: "[stopped]", ok: false });
});

test("the card's consequence names the folder the command would run in", () => {
  expect(shellTool.action!({ cmd: "ls", cwd: "/tmp" }).consequence).toContain("in /tmp");
  expect(shellTool.action!({ cmd: "ls" }).consequence).toContain("on the Mac");
});

test("the registry dispatches `shell` to this implementation", async () => {
  const registered = defaultTools.find((tool) => tool.name === "shell");

  expect(registered).toBe(shellTool);
  // What the loop does with a call: find the name, then run it.
  expect(await registered!.run({ cmd: "echo registry" })).toBe("registry");
});
