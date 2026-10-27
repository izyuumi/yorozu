/// <reference types="@cloudflare/workers-types" />
export const MAILBOX_TTL_MS = 10 * 60_000;
export const MAX_LETTER_BYTES = 4096;

const MAILBOX_ID = /^[A-Za-z0-9_-]{22}$/;
const LETTER = /^[A-Za-z0-9_-]+$/;

export const isMailboxId = (value: string): boolean => MAILBOX_ID.test(value);

export class Mailbox implements DurableObject {
  constructor(private readonly state: DurableObjectState) {}

  async fetch(request: Request): Promise<Response> {
    const now = Date.now();
    let opened = await this.state.storage.get<number>("opened");
    if (opened === undefined) {
      opened = now;
      await this.state.storage.put("opened", opened);
      await this.state.storage.setAlarm(opened + MAILBOX_TTL_MS);
    }
    if (now >= opened + MAILBOX_TTL_MS) return new Response("expired", { status: 410 });
    const letter = await this.state.storage.get<string>("letter");

    if (request.method === "POST") {
      if (letter !== undefined) return new Response("already delivered", { status: 409 });
      const body = await request.text();
      if (body.length === 0 || body.length > MAX_LETTER_BYTES || !LETTER.test(body)) {
        return new Response("bad letter", { status: 400 });
      }
      await this.state.storage.put("letter", body);
      for (const ws of this.state.getWebSockets()) {
        try {
          ws.send(body);
        } catch {
        }
      }
      return new Response(null, { status: 204 });
    }
    if (request.method === "GET" && request.headers.get("Upgrade") === "websocket") {
      const { 0: client, 1: server } = new WebSocketPair();
      this.state.acceptWebSocket(server);
      if (letter !== undefined) server.send(letter);
      return new Response(null, { status: 101, webSocket: client });
    }
    return new Response("method not allowed", { status: 405, headers: { Allow: "GET, POST" } });
  }

  webSocketMessage(ws: WebSocket): void {
    ws.close(1008, "mailboxes only deliver");
  }

  async alarm(): Promise<void> {
    for (const ws of this.state.getWebSockets()) ws.close(1000, "expired");
    await this.state.storage.deleteAll();
  }
}
