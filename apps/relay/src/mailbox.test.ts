/// <reference types="@cloudflare/vitest-pool-workers/types" />

import { env, runInDurableObject, SELF } from "cloudflare:test";
import { expect, test } from "vitest";
import { Mailbox, MAILBOX_TTL_MS, MAX_LETTER_BYTES } from "./mailbox.js";
import type { Env } from "./worker.js";

/** The mailbox a Mac's code names, exercised as the Mac (a WebSocket) and the paired device (a POST) use it. */

let counter = 0;
/** A fresh 22-character id per test, so no test sees another's letter. */
const mailboxId = () => `mailbox${String(++counter).padStart(15, "0")}`;
const url = (id: string) => `https://relay.test/mailbox/${id}`;
const post = (id: string, body: string) => SELF.fetch(url(id), { method: "POST", body });

async function listen(id: string) {
  const response = await SELF.fetch(url(id), { headers: { Upgrade: "websocket" } });
  expect(response.status).toBe(101);
  const ws = response.webSocket!;
  const letters: string[] = [];
  const waiters: ((letter: string) => void)[] = [];
  ws.addEventListener("message", (event: MessageEvent) => {
    const waiter = waiters.shift();
    if (waiter) waiter(String(event.data));
    else letters.push(String(event.data));
  });
  ws.accept();
  return {
    ws,
    next: (): Promise<string> =>
      letters.length > 0 ? Promise.resolve(letters.shift()!) : new Promise((r) => waiters.push(r)),
  };
}

test("a letter reaches the Mac waiting on the mailbox, once", async () => {
  const id = mailboxId();
  const mac = await listen(id);
  expect((await post(id, "c2VhbGVk")).status).toBe(204);
  expect(await mac.next()).toBe("c2VhbGVk");
  expect((await post(id, "c2Vjb25k")).status).toBe(409);
  mac.ws.close();
});

test("a letter that came first waits for the Mac to dial", async () => {
  const id = mailboxId();
  expect((await post(id, "ZWFybHk")).status).toBe(204);
  const mac = await listen(id);
  expect(await mac.next()).toBe("ZWFybHk");
  mac.ws.close();
});

test("only base64url letters up to the limit, to well-formed ids", async () => {
  expect((await post("short", "YQ")).status).toBe(400);
  expect((await post(mailboxId(), "not base64url!")).status).toBe(400);
  expect((await post(mailboxId(), "")).status).toBe(400);
  expect((await post(mailboxId(), "a".repeat(MAX_LETTER_BYTES + 1))).status).toBe(413);
  expect((await SELF.fetch(url(mailboxId()))).status).toBe(405);
});

test("ten minutes on, the mailbox is gone", async () => {
  const id = mailboxId();
  expect((await post(id, "bGF0ZQ")).status).toBe(204);
  const stub = (env as unknown as Env).MAILBOX.get((env as unknown as Env).MAILBOX.idFromName(id));
  await runInDurableObject(stub, async (_mailbox: Mailbox, state) => {
    await state.storage.put("opened", Date.now() - MAILBOX_TTL_MS);
  });
  expect((await post(id, "bGF0ZXI")).status).toBe(410);
  await runInDurableObject(stub, async (mailbox: Mailbox, state) => {
    await mailbox.alarm();
    expect(await state.storage.get("letter")).toBeUndefined();
  });
});
