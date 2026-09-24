/**
 * The shell tool: unrestricted, running as the user, exactly as the spec's tool table says.
 * See docs/spec-v1.html section 3.
 */

import { execFile } from "node:child_process";
import { homedir } from "node:os";
import type { Tool } from "../index.js";

const DEFAULT_TIMEOUT_MS = 60_000;

/** Room for a command to produce more than we will show, so the tail can be reported. */
const MAX_BUFFER = 10 * 1024 * 1024;

/** How much output any one tool result may hand the model. */
export const MAX_OUTPUT = 20_000;

export function truncate(text: string, max = MAX_OUTPUT): string {
  return text.length <= max
    ? text
    : `${text.slice(0, max)}\n… truncated, ${text.length - max} more characters`;
}

/** Models write `~/…`; the shell would only expand it unquoted. */
export const expandHome = (path: string): string =>
  path.replace(/^~(?=\/|$)/, homedir());

export interface ShellOptions {
  cmd: string;
  cwd?: string;
  timeoutMs?: number;
  /** Aborting kills the command; the result then says it was stopped. */
  signal?: AbortSignal;
}

export interface ShellResult {
  /** Combined stdout and stderr, truncated, with the status on its last line when not `ok`. */
  output: string;
  /** Exited zero. */
  ok: boolean;
}

/**
 * A non-zero exit, a timeout and a stop are all results, not throws: whoever asked wants to
 * know what happened, and the output plus the status is the answer.
 */
export function execShell(options: ShellOptions): Promise<ShellResult> {
  const timeout = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  return new Promise((resolve) => {
    execFile(
      "/bin/sh",
      ["-c", options.cmd],
      {
        ...(options.cwd ? { cwd: expandHome(options.cwd) } : {}),
        ...(options.signal ? { signal: options.signal } : {}),
        timeout,
        maxBuffer: MAX_BUFFER,
        encoding: "utf8",
      },
      (error, stdout, stderr) => {
        const combined = `${stdout}${stderr}`.trimEnd();
        if (!error) return resolve({ output: truncate(combined) || "(no output)", ok: true });
        const { code, killed } = error as Error & { code?: number | string; killed?: boolean };
        const status = options.signal?.aborted ? "stopped" : killed ? `killed after ${timeout}ms` : `exit ${code ?? "?"}`;
        resolve({ output: `${truncate(combined)}\n[${status}]`.trimStart(), ok: false });
      },
    );
  });
}

/** `execShell` as the one string the model reads. */
export const runShell = async (options: ShellOptions): Promise<string> => (await execShell(options)).output;

export const shellTool: Tool = {
  name: "shell",
  description:
    "Run a shell command on the user's Mac and return its combined output and exit status.",
  actionClass: "run-command",
  action: ({ cmd, cwd }) => ({
    target: String(cmd ?? ""),
    operation: "run",
    consequence: `Runs this command ${cwd ? `in ${String(cwd)}` : "on the Mac"} with the user's own permissions.`,
  }),
  parameters: {
    type: "object",
    properties: {
      cmd: { type: "string", description: "The command line, run through /bin/sh." },
      cwd: { type: "string", description: "Directory to run in. Defaults to the runtime's." },
      timeoutMs: { type: "number", description: "Kill the command after this long. Defaults to 60000." },
    },
    required: ["cmd"],
  },
  run: ({ cmd, cwd, timeoutMs }) => {
    const command = String(cmd ?? "").trim();
    if (!command) throw new Error("shell: cmd is empty");
    const ms = Number(timeoutMs);
    return runShell({
      cmd: command,
      ...(cwd ? { cwd: String(cwd) } : {}),
      ...(Number.isFinite(ms) && ms > 0 ? { timeoutMs: ms } : {}),
    });
  },
};
