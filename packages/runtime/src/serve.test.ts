import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay, type Relay } from "@yorozu/relay";
import { connectPhone } from "@yorozu/relay/dist/testing.js";
import {
  decodeQrPayload,
  deriveSessionKey,
  fromBase64Url,
  generateKeypair,
  open,
  seal,
  toBase64Url,
  type YorozuEvent,
} from "@yorozu/shared";
import { afterEach, expect, test, vi } from "vitest";
import { openaiCompat } from "./provider.js";
import { serve, type Sidecar } from "./serve.js";

let relay: Relay;
let sidecar: Sidecar;

afterEach(async () => {
  await sidecar?.close();
  await relay?.close();
});

/** A one-turn chat completion, streamed the way the adapter expects it. */
const sse = (text: string) =>
  new Response(
    `data: ${JSON.stringify({ choices: [{ delta: { content: text }, finish_reason: "stop" }] })}\n\n` +
      "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );

const frameBody = (payload: string) => JSON.parse(Buffer.from(payload, "base64url").toString());

const encodeBody = (body: unknown) => toBase64Url(Buffer.from(JSON.stringify(body)));

test("a sealed message from a phone round-trips through the agent loop", async () => {
  relay = await startRelay(0);

  const lines: string[] = [];
  let qrLine!: (line: string) => void;
  const qrPrinted = new Promise<string>((resolve) => (qrLine = resolve));

  const fetchMock = vi.fn<typeof fetch>().mockImplementation(async () => sse("pong"));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-serve-")),
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: fetchMock }),
    log: (line) => {
      lines.push(line);
      if (line.startsWith("QR ")) qrLine(line.slice(3));
    },
  });

  const qr = decodeQrPayload(await qrPrinted);
  expect(lines.filter((l) => l.startsWith("STATE "))).toEqual([
    "STATE connecting",
    "STATE connected",
    "STATE registered",
  ]);
  expect(qr.relayUrl).toBe(`ws://127.0.0.1:${relay.port}`);

  const { phone, keys } = await connectPhone(relay.port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  // The phone announces its X25519 key in the clear, then everything is sealed.
  const phoneKeys = generateKeypair();
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(encodeBody({ t: "hello", pub: toBase64Url(phoneKeys.publicKey) }), keys);

  const sent: YorozuEvent = {
    id: "e1",
    threadId: "home",
    ts: 1,
    agentId: "phone",
    kind: "message",
    data: { role: "user", text: "ping" },
  };
  const box = seal(sessionKey, Buffer.from(JSON.stringify(sent)));
  phone.frame(
    encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }),
    keys,
  );

  const reply = frameBody((await phone.next()).payload);
  const plain = open(sessionKey, fromBase64Url(reply.n), fromBase64Url(reply.c));
  const event = JSON.parse(Buffer.from(plain).toString()) as YorozuEvent;

  expect(event).toMatchObject({ threadId: "home", kind: "message", data: { role: "agent", text: "pong" } });
  expect(lines).toContain("STATE paired");
  expect(fetchMock.mock.calls[0]![0]).toBe("https://example.invalid/v1/chat/completions");
});
