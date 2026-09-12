/**
 * The Swift native tool host. Node cannot call Accessibility, ScreenCaptureKit or CGEvent,
 * so `apps/mac` ships a second executable, `yorozu-native`, speaking one JSON request per
 * line on stdin and one JSON response per line on stdout. It is spawned once and every
 * native tool call is multiplexed over that pipe, matched up by an `id` the helper echoes.
 *
 * Element IDs live in the helper, not here: an AXUIElement ref only means anything inside
 * the process that owns it, so `screen_read` hands out `e1`, `e2`, … and `input_click`
 * sends one back.
 *
 * See docs/spec-v1.html section 3.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { env } from "node:process";
import { createInterface } from "node:readline";
import type { Tool } from "../index.js";
import { stateDir } from "../memory.js";
import { truncate } from "./shell.js";

/** AX reads and a ScreenCaptureKit grab are both fast; anything slower is a hang. */
const TIMEOUT_MS = 15_000;

/**
 * Dev default is the `swift build` product, reachable from `dist/` in a checkout; the Mac
 * app passes `YOROZU_NATIVE_CMD` pointing into its own bundle, which is also what gives the
 * helper the TCC grants (they key on the bundle's signature, not on this path).
 */
export const nativeCommand = (): string =>
  env.YOROZU_NATIVE_CMD ??
  join(import.meta.dirname, "..", "..", "..", "..", "apps", "mac", ".build", "debug", "yorozu-native");

export interface NativeResponse {
  ok: boolean;
  error?: string;
  [key: string]: unknown;
}

export interface NativeHost {
  request(cmd: string, args?: Record<string, unknown>): Promise<NativeResponse>;
  close(): void;
}

interface Pending {
  resolve(response: NativeResponse): void;
  reject(error: Error): void;
  timer: NodeJS.Timeout;
}

/** Spawns the helper lazily and keeps it: the element cache only lives as long as it does. */
export function openNativeHost(command = nativeCommand()): NativeHost {
  let child: ChildProcess | null = null;
  const pending = new Map<string, Pending>();
  let lastId = 0;

  /** The helper died or was closed: nothing in flight can ever be answered now. */
  function fail(reason: string): void {
    child = null;
    for (const entry of pending.values()) {
      clearTimeout(entry.timer);
      entry.reject(new Error(reason));
    }
    pending.clear();
  }

  function start(): ChildProcess {
    if (child) return child;
    // Through /bin/sh, like the sidecar itself, so the command can carry arguments.
    const started = spawn("/bin/sh", ["-c", command], { stdio: ["pipe", "pipe", "pipe"] });
    child = started;

    createInterface({ input: started.stdout! }).on("line", (line) => {
      let response: NativeResponse;
      try {
        response = JSON.parse(line) as NativeResponse;
      } catch {
        return; // Not protocol: the helper's own noise.
      }
      const rid = String(response.rid ?? "");
      const entry = pending.get(rid);
      if (!entry) return;
      pending.delete(rid);
      clearTimeout(entry.timer);
      entry.resolve(response);
    });

    // Kept drained so a chatty helper cannot block on a full stderr pipe.
    started.stderr!.resume();
    // A helper that dies before reading stdin surfaces as EPIPE on the write; the exit
    // handler already rejects every pending request, so the write error is just noise.
    started.stdin!.on("error", () => {});
    started.on("exit", (code) => fail(`${command} exited with ${code}`));
    started.on("error", (error: Error) => fail(error.message));
    return started;
  }

  return {
    request(cmd, args = {}) {
      const helper = start();
      // `rid`, not `id`: an element ID travels as `id`, and the two must not collide.
      const rid = String(++lastId);
      return new Promise<NativeResponse>((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(rid);
          reject(new Error(`${cmd} timed out after ${TIMEOUT_MS}ms`));
        }, TIMEOUT_MS);
        timer.unref?.();
        pending.set(rid, { resolve, reject, timer });
        helper.stdin!.write(`${JSON.stringify({ ...args, rid, cmd })}\n`);
      });
    },

    close() {
      child?.kill();
      fail("native host closed");
    },
  };
}

let shared: NativeHost | undefined;
let sharedCommand: string | undefined;

/** Process-wide host for the tools below. Respawns if the command changes. */
export function defaultNativeHost(): NativeHost {
  const command = nativeCommand();
  if (!shared || sharedCommand !== command) {
    shared?.close();
    shared = openNativeHost(command);
    sharedCommand = command;
  }
  return shared;
}

/**
 * A helper-reported failure is a thrown error: the loop turns it into `error: …`. Shared
 * with the calendar, reminders and mail tools, which speak the same pipe.
 */
export async function askNative(
  cmd: string,
  args: Record<string, unknown> = {},
): Promise<NativeResponse> {
  const response = await defaultNativeHost().request(cmd, args);
  if (!response.ok) throw new Error(String(response.error ?? `${cmd} failed`));
  return response;
}

export interface AxNode {
  id: string;
  role: string;
  title?: string;
  value?: string;
  frame?: { x: number; y: number; w: number; h: number };
  children?: AxNode[];
}

/**
 * One indented line per element. The model needs IDs, labels and bounds it can click, not
 * the JSON the helper sent.
 */
export function formatTree(node: AxNode, depth = 0): string[] {
  const box = node.frame;
  const lines = [
    [
      `${"  ".repeat(depth)}${node.id}`,
      node.role,
      node.title ? JSON.stringify(node.title) : "",
      node.value ? `= ${JSON.stringify(node.value)}` : "",
      box ? `[${Math.round(box.x)},${Math.round(box.y)} ${Math.round(box.w)}x${Math.round(box.h)}]` : "",
    ]
      .filter(Boolean)
      .join(" "),
  ];
  for (const child of node.children ?? []) lines.push(...formatTree(child, depth + 1));
  return lines;
}

/**
 * Saves the PNG and returns its path rather than image content. None of the three adapters
 * can carry an image back into a turn today — the OpenAI-compatible one sends tool results
 * as plain strings, the Claude one denies every call and never sees a result, and Codex
 * takes no tools at all — so an image-bearing tool result would be plumbing with nothing
 * on the other end. The path is what the provider chain, and the user, can actually use.
 */
export async function captureScreen(dir = join(stateDir(), "screenshots")): Promise<string> {
  const response = await askNative("screen.capture");
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `${new Date().toISOString().replace(/[:.]/g, "-")}.png`);
  writeFileSync(file, Buffer.from(String(response.png ?? ""), "base64"));
  return `screenshot ${String(response.width)}x${String(response.height)} saved to ${file}`;
}

export const screenReadTool: Tool = {
  name: "screen_read",
  description:
    "Read the frontmost window as an accessibility tree, with an element ID and bounds per " +
    "line. IDs stay valid until the next call and are what input_click takes. Falls back to " +
    "a screenshot when the window exposes no tree.",
  parameters: { type: "object", properties: {}, required: [] },
  run: async () => {
    const response = await askNative("ax.read");
    const tree = response.tree as AxNode | undefined;
    const lines = tree?.id ? formatTree(tree) : [];
    // Spec: the screenshot is the automatic fallback when the tree is empty, so the model
    // gets something to work with rather than a dead end it has to notice and recover from.
    if (!lines.length) {
      return `the frontmost window exposes no accessibility tree; ${await captureScreen()}`;
    }
    return truncate([`app: ${String(response.app ?? "")}`, ...lines].join("\n"));
  },
};

export const screenCaptureTool: Tool = {
  name: "screen_capture",
  description:
    "Screenshot the main display to a PNG file and return its path. Used when a window has " +
    "no accessibility tree to read.",
  parameters: { type: "object", properties: {}, required: [] },
  run: () => captureScreen(),
};

export const inputClickTool: Tool = {
  name: "input_click",
  description:
    "Click an element from the last screen_read by its ID, or a point in screen coordinates.",
  parameters: {
    type: "object",
    properties: {
      id: { type: "string", description: "Element ID from the last screen_read." },
      x: { type: "number" },
      y: { type: "number" },
    },
    required: [],
  },
  run: async ({ id, x, y }) => {
    const response = await askNative("input.click", {
      ...(id ? { id: String(id) } : { x: Number(x), y: Number(y) }),
    });
    const at = response.clicked as { x: number; y: number };
    return `clicked ${Math.round(at.x)},${Math.round(at.y)}`;
  },
};

export const inputTypeTool: Tool = {
  name: "input_type",
  description: "Type text into whatever currently has keyboard focus.",
  parameters: {
    type: "object",
    properties: { text: { type: "string" } },
    required: ["text"],
  },
  run: async ({ text }) => {
    const body = String(text ?? "");
    await askNative("input.type", { text: body });
    return `typed ${body.length} characters`;
  },
};

export const inputKeyTool: Tool = {
  name: "input_key",
  description:
    "Press one key, optionally with modifiers — for shortcuts and keys text cannot carry, " +
    "like return, tab, escape or the arrows.",
  parameters: {
    type: "object",
    properties: {
      key: { type: "string", description: "Key name, e.g. return, tab, escape, left, f, 1." },
      modifiers: {
        type: "array",
        items: { type: "string" },
        description: "Any of cmd, shift, ctrl, alt, fn.",
      },
    },
    required: ["key"],
  },
  run: async ({ key, modifiers }) => {
    const names = Array.isArray(modifiers) ? modifiers.map(String) : [];
    await askNative("input.key", { key: String(key ?? ""), modifiers: names });
    return `pressed ${[...names, String(key ?? "")].join("+")}`;
  },
};
