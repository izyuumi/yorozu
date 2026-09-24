/** Host-owned PTYs. No terminal data is written to a thread log or disk. */
import { existsSync } from "node:fs";
import { homedir, userInfo } from "node:os";
import { basename } from "node:path";
import * as pty from "node-pty";
import headless from "@xterm/headless";
import serialize from "@xterm/addon-serialize";
import type { Terminal as XtermTerminal } from "@xterm/headless";
import type { SerializeAddon as XtermSerializeAddon } from "@xterm/addon-serialize";

const { Terminal } = headless;
const { SerializeAddon } = serialize;

export interface TerminalInfo {
  id: string;
  title: string;
  cwd: string;
  writable: boolean;
  cols: number;
  rows: number;
}

interface Session {
  id: string;
  title: string;
  cwd: string;
  writer: string | null;
  viewers: Set<string>;
  process: pty.IPty;
  screen: XtermTerminal;
  serializer: XtermSerializeAddon;
  sequence: number;
  parsed: Promise<void>;
  lastUsed: number;
}

export interface TerminalSnapshot {
  id: string;
  sequence: number;
  content: string;
}

const MAX_SESSIONS = 16;
const MAX_COLS = 240;
const MAX_ROWS = 100;

export function terminalSize(cols: number | undefined, rows: number | undefined): { cols: number; rows: number } {
  if (!Number.isInteger(cols) || !Number.isInteger(rows) || cols! < 1 || rows! < 1 || cols! > MAX_COLS || rows! > MAX_ROWS) {
    throw new Error("invalid terminal size");
  }
  return { cols: cols!, rows: rows! };
}

/** Fork the host user's normal interactive login shell without passing sidecar secrets. */
export function terminalShell(source: NodeJS.ProcessEnv = process.env): { file: string; args: string[]; env: Record<string, string> } {
  const configured = userInfo().shell;
  const file = configured && configured.startsWith("/") && existsSync(configured) ? configured
    : source.SHELL && source.SHELL.startsWith("/") && existsSync(source.SHELL) ? source.SHELL : "/bin/zsh";
  const shellEnv: Record<string, string> = {};
  for (const key of ["HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "LC_CTYPE", "TMPDIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME"]) {
    if (source[key]) shellEnv[key] = source[key];
  }
  shellEnv.HOME ??= homedir();
  shellEnv.SHELL = file;
  shellEnv.TERM = "xterm-256color";
  return { file, args: ["-l", "-i"], env: shellEnv };
}

export class TerminalSessions {
  private readonly sessions = new Map<string, Session>();
  private nextLabel = 1;
  private nextUse = 1;

  constructor(
    private readonly onOutput: (id: string, data: string, sequence: number, viewers: ReadonlySet<string>) => void,
    private readonly onChange: () => void,
    private readonly spawn: typeof pty.spawn = pty.spawn,
  ) {}

  list(device: string): TerminalInfo[] {
    return [...this.sessions.values()].sort((a, b) => a.lastUsed - b.lastUsed).map((session) => ({
      id: session.id, title: session.title, cwd: session.cwd, writable: session.writer === device,
      cols: session.screen.cols, rows: session.screen.rows,
    }));
  }

  create(id: string, cwd: string, device: string, cols: number, rows: number): void {
    if (this.sessions.size >= MAX_SESSIONS) throw new Error("too many open terminals");
    if (this.sessions.has(id)) throw new Error("terminal already exists");
    const size = terminalSize(cols, rows);
    const shell = terminalShell();
    const screen = new Terminal({ cols: size.cols, rows: size.rows, scrollback: 1000, allowProposedApi: true });
    const serializer = new SerializeAddon();
    screen.loadAddon(serializer);
    const process = this.spawn(shell.file, shell.args, { cwd, cols: size.cols, rows: size.rows, name: "xterm-256color", env: shell.env });
    const session: Session = {
      id, title: `${basename(cwd) || "Home"} · ${this.nextLabel++}`, cwd,
      writer: device, viewers: new Set([device]), process, screen, serializer,
      sequence: 0, parsed: Promise.resolve(), lastUsed: this.nextUse++,
    };
    this.sessions.set(id, session);
    process.onData((data) => {
      session.sequence++;
      session.parsed = new Promise<void>((resolve) => screen.write(data, resolve));
      this.onOutput(id, data, session.sequence, session.viewers);
    });
    process.onExit(() => this.drop(id));
    this.onChange();
  }

  async attach(id: string, device: string): Promise<TerminalSnapshot> {
    const session = this.require(id);
    session.viewers.add(device);
    if (!session.writer) session.writer = device;
    session.lastUsed = this.nextUse++;
    await session.parsed;
    if (this.sessions.get(id) !== session) throw new Error("terminal ended");
    this.onChange();
    return { id, sequence: session.sequence, content: session.serializer.serialize({ scrollback: 1000 }) };
  }

  detach(id: string, device: string): void {
    const session = this.sessions.get(id);
    if (!session) return;
    session.viewers.delete(device);
    if (session.writer === device) session.writer = null;
    this.onChange();
  }

  forgetDevice(device: string): void {
    for (const session of this.sessions.values()) {
      session.viewers.delete(device);
      if (session.writer === device) session.writer = null;
    }
    this.onChange();
  }

  takeover(id: string, device: string, cols: number, rows: number): void {
    const session = this.require(id);
    session.viewers.add(device);
    session.writer = device;
    session.lastUsed = this.nextUse++;
    this.resize(id, device, cols, rows);
    this.onChange();
  }

  input(id: string, device: string, encoded: string): void {
    const session = this.requireWriter(id, device);
    if (encoded.length > 24_000 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
      throw new Error("invalid terminal input");
    }
    const bytes = Buffer.from(encoded, "base64");
    if (bytes.length > 16_384) throw new Error("terminal input too large");
    session.process.write(bytes);
  }

  resize(id: string, device: string, cols: number, rows: number): void {
    const session = this.requireWriter(id, device);
    const size = terminalSize(cols, rows);
    session.process.resize(size.cols, size.rows);
    session.screen.resize(size.cols, size.rows);
    this.onChange();
  }

  close(id: string, device: string, host = false): void {
    const session = this.require(id);
    if (!host && session.writer !== device) throw new Error("take control before closing terminal");
    this.drop(id);
  }

  closeAll(): void {
    for (const id of [...this.sessions.keys()]) this.drop(id);
  }

  count(): number { return this.sessions.size; }

  private require(id: string): Session {
    const session = this.sessions.get(id);
    if (!session) throw new Error("terminal not found");
    return session;
  }

  private requireWriter(id: string, device: string): Session {
    const session = this.require(id);
    if (session.writer !== device) throw new Error("terminal is read-only; take control first");
    return session;
  }

  private drop(id: string): void {
    const session = this.sessions.get(id);
    if (!session) return;
    this.sessions.delete(id);
    session.process.kill();
    session.screen.dispose();
    this.onChange();
  }
}
