import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import type { Provider } from "./provider.js";
import { createThread, listThreads, renameThread } from "./threads.js";
import { autoTitle } from "./title.js";

const titler = (answer: () => AsyncGenerator<{ type: "text"; text: string }>): Provider =>
  ({ stream: answer } as unknown as Provider);

const OPENING = "buy milk and eggs and bread today please";

function thread(): { dir: string; id: string } {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-title-"));
  return { dir, id: createThread(undefined, dir).id };
}

test("the model's answer becomes the title, cleaned", async () => {
  const { dir, id } = thread();
  const model = titler(async function* () { yield { type: "text", text: '"Groceries run."\n' }; });
  expect(await autoTitle(id, OPENING, model, dir)).toBe(true);
  expect(listThreads(dir)[0]!.title).toBe("Groceries run");
});

test("no titler, or one that fails, leaves the first five words", async () => {
  const { dir, id } = thread();
  expect(await autoTitle(id, OPENING, undefined, dir)).toBe(true);
  expect(listThreads(dir)[0]!.title).toBe("buy milk and eggs and");

  const broken = thread();
  const model = titler(async function* () { throw new Error("401"); });
  expect(await autoTitle(broken.id, OPENING, model, broken.dir)).toBe(true);
  expect(listThreads(broken.dir)[0]!.title).toBe("buy milk and eggs and");
});

test("a titled thread is never asked about again", async () => {
  const { dir, id } = thread();
  renameThread(id, "Mine", dir);
  let asked = false;
  const model = titler(async function* () { asked = true; yield { type: "text", text: "Other" }; });
  expect(await autoTitle(id, OPENING, model, dir)).toBe(false);
  expect(asked).toBe(false);
  expect(listThreads(dir)[0]!.title).toBe("Mine");
});
