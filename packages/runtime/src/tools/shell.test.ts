import { mkdtempSync, realpathSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { MAX_OUTPUT, expandHome, runShell, shellTool, truncate } from "./shell.js";

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
