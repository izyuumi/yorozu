import assert from "node:assert/strict";
import { once } from "node:events";
import { readFileSync } from "node:fs";
import { createServer, type IncomingHttpHeaders, type ServerResponse } from "node:http";
import type { TestContext } from "node:test";
import { setTimeout as delay } from "node:timers/promises";

export const fixtureDir = new URL("./fixtures/hermes-0.23.1/", import.meta.url);

type Reply = {
  status?: number;
  headers?: Record<string, string>;
  body?: string;
  chunks?: { afterMs: number; body: string }[];
  end?: "hang" | "reset";
};

type Step = {
  method: "GET" | "POST";
  path: string;
  key?: string;
  reply: Reply | { fixture: string };
};

type RecordedRequest = {
  method: string | undefined;
  path: string | undefined;
  headers: IncomingHttpHeaders;
  body: Buffer;
};

function fixture(name: string): Reply {
  const [statusLine = "", ...lines] = readFileSync(new URL(name + ".headers", fixtureDir), "utf8")
    .trimEnd().split(/\r?\n/);
  const status = Number(statusLine.split(" ")[1]);
  const headers = Object.fromEntries(lines.map((line) => {
    const colon = line.indexOf(":");
    return [line.slice(0, colon), line.slice(colon + 1).trim()];
  }));
  const extension = headers["Content-Type"]?.startsWith("text/event-stream") ? ".sse" : ".body";
  return { status, headers, body: readFileSync(new URL(name + extension, fixtureDir), "utf8") };
}

async function respond(res: ServerResponse, source: Step["reply"]): Promise<void> {
  const reply = "fixture" in source ? fixture(source.fixture) : source;
  if (reply.status === undefined && !reply.headers && reply.body === undefined && !reply.chunks) {
    if (reply.end === "reset") {
      res.socket?.resetAndDestroy();
      return;
    }
    if (reply.end === "hang") return;
  }
  res.writeHead(reply.status ?? 200, reply.headers);
  if (reply.body !== undefined) res.write(reply.body);
  for (const chunk of reply.chunks ?? []) {
    await delay(chunk.afterMs);
    if (res.destroyed) return;
    res.write(chunk.body);
  }
  if (reply.end === "reset") res.socket?.resetAndDestroy();
  else if (reply.end === "hang") res.flushHeaders();
  else res.end();
}

export async function fakeHermes(t: TestContext, script: Step[]) {
  const requests: RecordedRequest[] = [];
  const arrivals = new Map<number, ReturnType<typeof Promise.withResolvers<RecordedRequest>>>();
  const responseErrors: unknown[] = [];
  function arrival(n: number) {
    let result = arrivals.get(n);
    if (!result) {
      result = Promise.withResolvers<RecordedRequest>();
      arrivals.set(n, result);
    }
    return result;
  }

  const server = createServer((req, res) => {
    const row = { method: req.method, path: req.url, headers: req.headers, body: Buffer.alloc(0) };
    const n = requests.push(row);
    const step = script[n - 1];
    const chunks: Buffer[] = [];
    req.on("data", (chunk: Buffer) => chunks.push(chunk));
    req.on("error", (error) => responseErrors.push(error));
    req.on("end", () => {
      row.body = Buffer.concat(chunks);
      arrival(n).resolve(row);
      if (!step || row.method !== step.method || row.path !== step.path || row.headers["idempotency-key"] !== step.key) {
        res.writeHead(500).end();
        return;
      }
      void respond(res, step.reply).catch((error: unknown) => {
        responseErrors.push(error);
        res.destroy();
      });
    });
  });

  let closing: Promise<void> | undefined;
  function close(): Promise<void> {
    return closing ??= new Promise((resolve, reject) => {
      server.close((error) => error ? reject(error) : resolve());
      server.closeAllConnections();
    });
  }
  t.after(async () => {
    await close();
    assert.deepEqual(responseErrors, []);
    assert.deepEqual(requests.map(({ method, path, headers }) => [method, path, headers["idempotency-key"]]),
      script.map(({ method, path, key }) => [method, path, key]));
  });

  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  return { url: new URL(`http://127.0.0.1:${address.port}`), request: (n: number) => arrival(n).promise, close };
}
