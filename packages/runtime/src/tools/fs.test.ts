import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test } from "vitest";
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
