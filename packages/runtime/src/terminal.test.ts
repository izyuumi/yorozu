import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir, userInfo } from "node:os";
import { join } from "node:path";
import * as pty from "node-pty";
import { Terminal } from "@xterm/headless";
import { SerializeAddon } from "@xterm/addon-serialize";
import { afterEach, beforeEach, expect, test } from "vitest";
import { TerminalSessions, terminalShell, terminalSize } from "./terminal.js";

let cwd: string;
beforeEach(() => { cwd = mkdtempSync(join(tmpdir(), "yorozu-terminal-")); });
afterEach(() => rmSync(cwd, { recursive: true, force: true }));

test("host PTY survives detach, shares screen, and transfers the only writer", async () => {
  const output: string[] = [];
  const sessions = new TerminalSessions(
    (_id, data) => output.push(data),
    () => {},
    ((_file, _args, options) => pty.spawn("/bin/sh", ["-i"], options)) as typeof pty.spawn,
  );
  try {
    sessions.create("s", cwd, "phone", 80, 24);
    expect(() => sessions.input("s", "phone", "not-base64!")).toThrow("invalid terminal input");
    sessions.input("s", "phone", Buffer.from("printf 'YOROZU_PTY_READY\\n'\n").toString("base64"));
    await expect.poll(() => output.join("")).toContain("YOROZU_PTY_READY");
    const first = await sessions.attach("s", "phone");
    expect(first.content).toContain("YOROZU_PTY_READY");

    sessions.detach("s", "phone");
    expect(sessions.count()).toBe(1);
    const resumed = await sessions.attach("s", "mac");
    expect(resumed.content).toContain("YOROZU_PTY_READY");
    expect(sessions.list("mac")[0]?.writable).toBe(true);
    sessions.takeover("s", "phone", 100, 30);
    expect(sessions.list("mac")[0]?.writable).toBe(false);
    expect(sessions.list("mac")[0]).toMatchObject({ cols: 100, rows: 30 });
    expect(() => sessions.input("s", "mac", Buffer.from("exit\n").toString("base64"))).toThrow("read-only");
    expect(() => sessions.close("s", "mac")).toThrow("take control");
    sessions.forgetDevice("phone");
    expect(sessions.count()).toBe(1);
    await sessions.attach("s", "mac");
    expect(sessions.list("mac")[0]?.writable).toBe(true);
    sessions.close("s", "mac");
    expect(sessions.count()).toBe(0);
  } finally {
    sessions.closeAll();
  }
}, 10_000);

test("terminal size and input validation reject malformed control frames", () => {
  expect(() => terminalSize(0, 24)).toThrow("invalid terminal size");
  expect(() => terminalSize(241, 24)).toThrow("invalid terminal size");
});

test("sessions list the most recently attached terminal last", async () => {
  const sessions = new TerminalSessions(() => {}, () => {},
    ((_file, _args, options) => pty.spawn("/bin/sh", ["-i"], options)) as typeof pty.spawn);
  try {
    sessions.create("old", cwd, "phone", 80, 24);
    sessions.create("new", cwd, "mac", 80, 24);
    expect(sessions.list("mac").at(-1)?.id).toBe("new");
    await sessions.attach("old", "mac");
    expect(sessions.list("mac").at(-1)?.id).toBe("old");
  } finally {
    sessions.closeAll();
  }
});

test("shell comes from host account rather than inherited process environment", () => {
  if (userInfo().shell) expect(terminalShell({ SHELL: "/bin/sh" }).file).toBe(userInfo().shell);
});

test("host serializer emits a restorable alternate screen for SwiftTerm", async () => {
  const terminal = new Terminal({ cols: 20, rows: 4, scrollback: 10, allowProposedApi: true });
  const serializer = new SerializeAddon();
  terminal.loadAddon(serializer);
  await new Promise<void>((resolve) => terminal.write("one\r\ntwo\r\n\x1b[?1049h\x1b[2J\x1b[H\x1b[31mVIM\x1b[0m", resolve));
  expect(serializer.serialize({ scrollback: 10 })).toBe("one\r\ntwo\x1b[1B\x1b[3D\x1b[?1049h\x1b[H\x1b[31mVIM\x1b[0m");
  terminal.dispose();
});
