import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env } from "node:process";
import { afterEach, beforeEach, expect, test } from "vitest";
import { defaultTools } from "../index.js";
import {
  defaultNativeHost,
  inputClickTool,
  inputKeyTool,
  inputTypeTool,
  openNativeHost,
  screenCaptureTool,
  screenReadTool,
} from "./native.js";

/**
 * A stand-in for the Swift helper speaking the same line protocol, so the client, the tree
 * formatting and the screenshot fallback are all testable without AX, a display or a Mac.
 * `ax.read` answers late on purpose: the runtime must still match each reply to its request.
 */
const FAKE_HELPER = `
import { createInterface } from "node:readline";

/** A real 1x1 PNG, so the tool has bytes worth decoding and writing. */
const PNG =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==";

const TREE = {
  id: "e1",
  role: "AXWindow",
  title: "Finder",
  frame: { x: 0, y: 0, w: 800, h: 600 },
  children: [
    { id: "e2", role: "AXButton", title: "OK", frame: { x: 10, y: 20, w: 60, h: 24 } },
    { id: "e3", role: "AXTextField", value: "hello", frame: { x: 10, y: 60, w: 200, h: 24 } },
  ],
};

const send = (body, request, delay = 0) =>
  setTimeout(() => {
    process.stdout.write(JSON.stringify({ ok: !body.error, ...body, rid: request.rid }) + "\\n");
  }, delay);

let previous = null;

createInterface({ input: process.stdin }).on("line", (line) => {
  const request = JSON.parse(line);
  // The request before this one, verbatim: how a test asserts what actually crossed the pipe.
  if (request.cmd === "last") return send({ last: previous }, request);
  previous = request;
  if (process.env.FAKE_MODE === "denied") {
    return send({ error: "the window is not readable", permission: "accessibility" }, request);
  }
  switch (request.cmd) {
    case "slow":
      return; // Never answers, so the client's own timeout is what has to fire.
    case "ax.read":
      return send(
        process.env.FAKE_MODE === "empty"
          ? { app: "Empty", tree: {}, count: 0 }
          : { app: "Finder", tree: TREE, count: 3 },
        request,
        30,
      );
    case "screen.capture":
      return send({ png: PNG, width: 1, height: 1 }, request);
    case "input.click":
      return send(
        { clicked: request.id === "e2" ? { x: 40, y: 32 } : { x: request.x, y: request.y } },
        request,
      );
    case "input.type":
      return send({ typed: request.text.length }, request);
    case "input.key":
      return send({ key: request.key, modifiers: request.modifiers }, request);
    case "ping":
      return send({ pong: true }, request);
    default:
      return send({ error: "unknown command: " + request.cmd }, request);
  }
});
`;

const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

let dir: string;
let helper: string;
const saved: Record<string, string | undefined> = {};

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-native-"));
  helper = join(dir, "helper.mjs");
  writeFileSync(helper, FAKE_HELPER);
  for (const key of ["YOROZU_NATIVE_CMD", "YOROZU_STATE_DIR"]) saved[key] = env[key];
  env.YOROZU_STATE_DIR = dir;
  env.YOROZU_NATIVE_CMD = `node ${helper}`;
});

afterEach(() => {
  defaultNativeHost().close();
  for (const [key, value] of Object.entries(saved)) {
    if (value === undefined) delete env[key];
    else env[key] = value;
  }
  rmSync(dir, { recursive: true, force: true });
});

test("reads the frontmost window as an indented tree with IDs and bounds", async () => {
  const out = await screenReadTool.run({});
  expect(out.split("\n")).toEqual([
    "app: Finder",
    'e1 AXWindow "Finder" [0,0 800x600]',
    '  e2 AXButton "OK" [10,20 60x24]',
    '  e3 AXTextField = "hello" [10,60 200x24]',
  ]);
});

test("an empty tree falls back to a screenshot on its own", async () => {
  env.YOROZU_NATIVE_CMD = `FAKE_MODE=empty node ${helper}`;
  const out = await screenReadTool.run({});
  expect(out).toContain("no accessibility tree");

  const file = /saved to (.+)$/.exec(out)?.[1];
  expect(file).toContain(join(dir, "screenshots"));
  expect(readFileSync(file!).subarray(0, 8)).toEqual(PNG_MAGIC);
});

test("screen_capture writes a PNG and reports its size", async () => {
  const out = await screenCaptureTool.run({});
  expect(out).toMatch(/^screenshot 1x1 saved to /);
  expect(readFileSync(/saved to (.+)$/.exec(out)![1]!).subarray(0, 8)).toEqual(PNG_MAGIC);
});

test("input acts on an element ID or on coordinates", async () => {
  expect(await inputClickTool.run({ id: "e2" })).toBe("clicked 40,32");
  expect(await inputClickTool.run({ x: 5, y: 7 })).toBe("clicked 5,7");
  expect(await inputTypeTool.run({ text: "hi there" })).toBe("typed 8 characters");
  expect(await inputKeyTool.run({ key: "return", modifiers: ["cmd"] })).toBe("pressed cmd+return");
});

test("requests in flight together each get their own reply", async () => {
  const host = openNativeHost(`node ${helper}`);
  // ax.read answers 30ms late, ping immediately: the ids are what keeps them apart.
  const [slow, fast] = await Promise.all([host.request("ax.read"), host.request("ping")]);
  expect(slow).toMatchObject({ ok: true, app: "Finder", count: 3 });
  expect(fast).toMatchObject({ ok: true, pong: true });
  host.close();
});

test("a command the helper does not know comes back as a failure", async () => {
  const host = openNativeHost(`node ${helper}`);
  await expect(host.request("nope")).resolves.toMatchObject({
    ok: false,
    error: "unknown command: nope",
  });
  host.close();
});

test("closing the host rejects whatever was in flight", async () => {
  const host = openNativeHost(`node ${helper}`);
  const inFlight = host.request("ax.read");
  host.close();
  await expect(inFlight).rejects.toThrow("native host closed");
});

test("a helper that will not start is an error, not a hang", async () => {
  env.YOROZU_NATIVE_CMD = "exit 1";
  await expect(Promise.resolve(screenReadTool.run({}))).rejects.toThrow(/exited/);
});

test("input_click sends the element ID alone, and coordinates only without one", async () => {
  expect(await inputClickTool.run({ id: "e2" })).toBe("clicked 40,32");
  await expect(defaultNativeHost().request("last")).resolves.toMatchObject({
    last: { cmd: "input.click", id: "e2" },
  });

  expect(await inputClickTool.run({ x: 5, y: 7 })).toBe("clicked 5,7");
  const { last } = await defaultNativeHost().request("last");
  // No stray `id`: the two forms are exclusive, and an undefined one must never be sent.
  expect(last).toEqual({ cmd: "input.click", x: 5, y: 7, rid: expect.any(String) });
});

test("input_type sends the text verbatim and counts characters, unicode and all", async () => {
  const text = "日本語 🎌";

  expect(await inputTypeTool.run({ text })).toBe(`typed ${text.length} characters`);
  const { last } = await defaultNativeHost().request("last");
  expect(last).toEqual({ cmd: "input.type", text, rid: expect.any(String) });

  // Nothing to type is a call the helper still answers, not an error.
  expect(await inputTypeTool.run({ text: "" })).toBe("typed 0 characters");
});

test("input_key sends an array of modifiers, empty when the model gave none", async () => {
  expect(await inputKeyTool.run({ key: "tab" })).toBe("pressed tab");
  const { last } = await defaultNativeHost().request("last");
  expect(last).toEqual({ cmd: "input.key", key: "tab", modifiers: [], rid: expect.any(String) });

  expect(await inputKeyTool.run({ key: "a", modifiers: ["cmd", "shift"] })).toBe(
    "pressed cmd+shift+a",
  );
});

test("the screen tools take no arguments and add none of their own", async () => {
  expect(await screenCaptureTool.run({ nonsense: true })).toMatch(/^screenshot 1x1 saved to /);

  const { last } = await defaultNativeHost().request("last");
  expect(last).toEqual({ cmd: "screen.capture", rid: expect.any(String) });
});

test("a failure that is really a missing macOS grant tells the model to ask for it", async () => {
  env.YOROZU_NATIVE_CMD = `FAKE_MODE=denied node ${helper}`;

  await expect(Promise.resolve(screenReadTool.run({}))).rejects.toThrow(
    'macOS permission "accessibility" is missing',
  );
  // The instruction matters as much as the name: the user is never sent to System Settings.
  await expect(Promise.resolve(screenCaptureTool.run({}))).rejects.toThrow("request_permission");
});

test("a helper that never answers is a timeout, not a hang", async () => {
  const host = openNativeHost(`node ${helper}`);

  await expect(host.request("slow", {}, 50)).rejects.toThrow("slow timed out after 50ms");

  host.close();
});

test("the native tools declare the arguments the model must supply", () => {
  const tools = [
    screenReadTool,
    screenCaptureTool,
    inputClickTool,
    inputTypeTool,
    inputKeyTool,
  ];

  expect(tools.map((tool) => tool.name)).toEqual([
    "screen_read",
    "screen_capture",
    "input_click",
    "input_type",
    "input_key",
  ]);
  // input_click requires neither: an element ID and a point are both whole calls.
  expect(tools.map((tool) => (tool.parameters as { required: string[] }).required)).toEqual([
    [],
    [],
    [],
    ["text"],
    ["key"],
  ]);
});

test("the registry dispatches every native tool to this implementation", async () => {
  for (const tool of [
    screenReadTool,
    screenCaptureTool,
    inputClickTool,
    inputTypeTool,
    inputKeyTool,
  ]) {
    expect(defaultTools.find((t) => t.name === tool.name)).toBe(tool);
  }

  const registered = defaultTools.find((t) => t.name === "input_key")!;
  expect(await registered.run({ key: "escape" })).toBe("pressed escape");
});
