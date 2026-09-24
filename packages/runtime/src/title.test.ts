import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env } from "node:process";
import { afterEach, expect, test } from "vitest";
import { createThread, listThreads, renameThread } from "./threads.js";
import { autoTitle, onDeviceTitler, type Titler } from "./title.js";
import { defaultNativeHost } from "./tools/native.js";

const OPENING = "buy milk and eggs and bread today please";

function thread(): { dir: string; id: string } {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-title-"));
  return { dir, id: createThread(undefined, dir).id };
}

afterEach(() => {
  defaultNativeHost().close();
  delete env.YOROZU_NATIVE_CMD;
});

test("the model's answer becomes the title, cleaned", async () => {
  const { dir, id } = thread();
  const model: Titler = async () => '"Groceries run."\n';
  expect(await autoTitle(id, OPENING, model, dir)).toBe(true);
  expect(listThreads(dir)[0]!.title).toBe("Groceries run");
});

test("a titler that answers nothing, or fails, leaves the first five words", async () => {
  const { dir, id } = thread();
  expect(await autoTitle(id, OPENING, async () => "", dir)).toBe(true);
  expect(listThreads(dir)[0]!.title).toBe("buy milk and eggs and");

  const broken = thread();
  const model: Titler = async () => { throw new Error("on-device model is not available"); };
  expect(await autoTitle(broken.id, OPENING, model, broken.dir)).toBe(true);
  expect(listThreads(broken.dir)[0]!.title).toBe("buy milk and eggs and");
});

test("a titled thread is never asked about again", async () => {
  const { dir, id } = thread();
  renameThread(id, "Mine", dir);
  let asked = false;
  const model: Titler = async () => { asked = true; return "Other"; };
  expect(await autoTitle(id, OPENING, model, dir)).toBe(false);
  expect(asked).toBe(false);
  expect(listThreads(dir)[0]!.title).toBe("Mine");
});

test("the on-device titler asks the native helper and takes its title", async () => {
  // A stand-in for yorozu-native that echoes the text it was given, so the test can see it.
  const helper = join(mkdtempSync(join(tmpdir(), "yorozu-title-helper-")), "helper.mjs");
  writeFileSync(helper, `
    import { createInterface } from "node:readline";
    createInterface({ input: process.stdin }).on("line", (line) => {
      const { rid, cmd, text } = JSON.parse(line);
      const body = cmd === "title.generate" ? { ok: true, title: "Title of " + text } : { ok: false, error: "unknown command" };
      process.stdout.write(JSON.stringify({ ...body, rid }) + "\\n");
    });
  `);
  env.YOROZU_NATIVE_CMD = `node ${helper}`;
  expect(await onDeviceTitler("milk")).toBe("Title of milk");
});
