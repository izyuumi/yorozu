import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test } from "vitest";
import { defaultTools } from "../index.js";
import { fsListTool, fsReadTool, fsWriteTool } from "./fs.js";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-fs-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

test("writes a file, creating parents, and reads it back", async () => {
  const file = join(dir, "deep", "nested", "note.md");
  expect(await fsWriteTool.run({ path: file, content: "hello" })).toBe(
    `wrote 5 characters to ${file}`,
  );
  expect(readFileSync(file, "utf8")).toBe("hello");
  expect(await fsReadTool.run({ path: file })).toBe("hello");
});

test("lists a directory, marking sub-directories and file sizes", async () => {
  writeFileSync(join(dir, "a.txt"), "12345");
  mkdirSync(join(dir, "sub"));
  expect(await fsListTool.run({ path: dir })).toBe("a.txt (5 bytes)\nsub/");
});

test("an empty directory says so rather than returning nothing", async () => {
  expect(await fsListTool.run({ path: dir })).toBe(`${dir} is empty`);
});

test("a missing file is an error the loop can report", () => {
  expect(() => fsReadTool.run({ path: join(dir, "nope") })).toThrow("ENOENT");
});

test("an empty path is refused", () => {
  expect(() => fsWriteTool.run({ path: "", content: "x" })).toThrow("empty");
});

test("a long file is truncated like shell output", async () => {
  const file = join(dir, "big.txt");
  writeFileSync(file, "x".repeat(30_000));
  expect(String(await fsReadTool.run({ path: file }))).toContain("truncated");
});

test("fs_write replaces a file rather than appending to it", async () => {
  const file = join(dir, "note.md");
  await fsWriteTool.run({ path: file, content: "first" });

  expect(await fsWriteTool.run({ path: file, content: "second" })).toBe(
    `wrote 6 characters to ${file}`,
  );
  expect(readFileSync(file, "utf8")).toBe("second");
});

test("unicode is written whole, and counted in characters rather than bytes", async () => {
  const file = join(dir, "日本語.txt");
  const content = "日本語 🎌";

  expect(await fsWriteTool.run({ path: file, content })).toBe(
    `wrote ${content.length} characters to ${file}`,
  );
  expect(await fsReadTool.run({ path: file })).toBe(content);
});

test("fs_read on a directory is an error, not an empty file", () => {
  expect(() => fsReadTool.run({ path: dir })).toThrow("EISDIR");
});

test("fs_list on a path that is not there is an error the loop can report", () => {
  expect(() => fsListTool.run({ path: join(dir, "nope") })).toThrow("ENOENT");
});

test("the file tools declare the arguments the model must supply", () => {
  const tools = [fsReadTool, fsWriteTool, fsListTool];

  expect(tools.map((tool) => tool.name)).toEqual(["fs_read", "fs_write", "fs_list"]);
  expect(tools.map((tool) => (tool.parameters as { required: string[] }).required)).toEqual([
    ["path"],
    ["path", "content"],
    ["path"],
  ]);
  // Writing is the only one of the three with an effect outside the runtime.
  expect(tools.map((tool) => tool.actionClass)).toEqual([undefined, "edit-file", undefined]);
});

test("a call with no path at all is refused rather than acting on the cwd", () => {
  expect(() => fsWriteTool.run({ content: "x" })).toThrow("fs_write: path is empty");
  // Read and list have nothing to open either, and say so with the errno the model can read.
  expect(() => fsReadTool.run({})).toThrow("ENOENT");
  expect(() => fsListTool.run({})).toThrow("ENOENT");
});

test("the registry dispatches each file tool to this implementation", async () => {
  for (const tool of [fsReadTool, fsWriteTool, fsListTool]) {
    expect(defaultTools.find((t) => t.name === tool.name)).toBe(tool);
  }

  const file = join(dir, "registry.txt");
  const write = defaultTools.find((t) => t.name === "fs_write")!;
  const read = defaultTools.find((t) => t.name === "fs_read")!;
  const list = defaultTools.find((t) => t.name === "fs_list")!;

  expect(await write.run({ path: file, content: "through the registry" })).toContain(file);
  expect(await read.run({ path: file })).toBe("through the registry");
  expect(await list.run({ path: dir })).toBe("registry.txt (20 bytes)");
});
