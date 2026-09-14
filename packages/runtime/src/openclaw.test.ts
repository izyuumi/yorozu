import { EventEmitter } from "node:events";
import { mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import type { GatewayClientOptions } from "@openclaw/gateway-client";
import { describe, expect, test, vi } from "vitest";
import { OpenClawRunner } from "./openclaw.js";

const stored = {
  identity: { deviceId: "device", publicKeyPem: "public", privateKeyPem: "private" },
  token: "device-token",
  scopes: ["operator.read", "operator.write"],
};

function harness() {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-openclaw-"));
  writeFileSync(join(dir, "openclaw-gateway.json"), JSON.stringify(stored));
  let options!: GatewayClientOptions;
  const request = vi.fn(async (method: string) => method === "chat.send" ? { runId: "run-1" } : {});
  const clientFactory = vi.fn((value: GatewayClientOptions) => {
    options = value;
    return { start: () => options.onHelloOk?.({ auth: {} } as never), stop: vi.fn(), request };
  });
  return {
    dir,
    request,
    clientFactory,
    event: (payload: object) => options.onEvent?.({ type: "event", event: "chat", payload } as never),
  };
}

describe("OpenClawRunner", () => {
  test("sends through Gateway and publishes streaming deltas", async () => {
    const gateway = harness();
    const updates: string[] = [];
    const result = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "one",
      text: "private text",
      attachments: [{ name: "note.txt", mime: "text/plain", data: Buffer.from("hello").toString("base64") }],
      onUpdate: (text) => updates.push(text),
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.objectContaining({
      sessionKey: "agent:main:yorozu:one",
      message: "private text",
      deliver: false,
      attachments: [{ type: "file", mimeType: "text/plain", fileName: "note.txt", content: "aGVsbG8=", sizeBytes: 5 }],
    })));
    gateway.event({ state: "delta", sessionKey: "agent:main:yorozu:one", runId: "run-1", seq: 1, deltaText: "new" });
    gateway.event({ state: "delta", sessionKey: "agent:main:yorozu:one", runId: "run-1", seq: 2, deltaText: " answer" });
    expect(updates).toEqual(["new", "new answer"]);
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:one", runId: "run-1", seq: 3 });
    await expect(result).resolves.toBe("new answer");
  });

  test("patches model and effort before sending", async () => {
    const gateway = harness();
    const result = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory }).run({
      threadId: "two", text: "hello", model: "openai/gpt-6-astra", effort: "high",
    });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("sessions.patch", {
      key: "agent:main:yorozu:two", model: "openai/gpt-6-astra", thinkingLevel: "high",
    }));
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:two", runId: "run-1", seq: 1, message: { content: [{ type: "text", text: "done" }] } });
    await expect(result).resolves.toBe("done");
  });

  test("steers an active turn instead of starting a parallel run in one thread", async () => {
    const gateway = harness();
    const first = new OpenClawRunner({ stateDir: gateway.dir, clientFactory: gateway.clientFactory });
    const running = first.run({ threadId: "one", text: "start" });
    await vi.waitFor(() => expect(gateway.request).toHaveBeenCalledWith("chat.send", expect.objectContaining({ message: "start" })));
    await expect(first.run({ threadId: "one", text: "change course" })).resolves.toBeUndefined();
    expect(gateway.request).toHaveBeenLastCalledWith("chat.send", expect.objectContaining({
      message: "change course", queueMode: "steer",
    }));
    gateway.event({ state: "final", sessionKey: "agent:main:yorozu:one", runId: "run-1", seq: 1, message: { content: "revised" } });
    await expect(running).resolves.toBe("revised");
  });

  test("persists bootstrap device credentials with owner-only permissions", async () => {
    const dir = mkdtempSync(join(tmpdir(), "yorozu-openclaw-bootstrap-"));
    const payload = Buffer.from(JSON.stringify({ url: "ws://127.0.0.1:18789", bootstrapToken: "bootstrap" })).toString("base64url");
    const spawnProcess = vi.fn(() => {
      const child = Object.assign(new EventEmitter(), { stdout: new PassThrough(), stderr: new PassThrough() });
      queueMicrotask(() => { child.stdout.end(`oc-pair://${payload}`); child.emit("close", 0); });
      return child;
    }) as never;
    let options!: GatewayClientOptions;
    const clientFactory = (value: GatewayClientOptions) => {
      options = value;
      return {
        start: () => {
          value.hostDeps?.storeDeviceAuthToken?.({ deviceId: value.deviceIdentity!.deviceId, role: "operator", token: "issued", scopes: ["operator.read", "operator.write"] });
          value.onHelloOk?.({ auth: {} } as never);
        },
        stop: vi.fn(),
        request: vi.fn(async () => ({ runId: "run-1" })),
      };
    };
    const result = new OpenClawRunner({ stateDir: dir, spawnProcess, clientFactory }).run({ threadId: "new", text: "hi" });
    await vi.waitFor(() => expect(options.bootstrapToken).toBe("bootstrap"));
    options.onEvent?.({ type: "event", event: "chat", payload: { state: "final", sessionKey: "agent:main:yorozu:new", runId: "run-1", seq: 1 } } as never);
    await result;
    const file = join(dir, "openclaw-gateway.json");
    expect(JSON.parse(readFileSync(file, "utf8")).token).toBe("issued");
    expect(statSync(file).mode & 0o777).toBe(0o600);
  });
});
