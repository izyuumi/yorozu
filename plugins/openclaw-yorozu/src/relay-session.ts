import { DIRECT, LIVE_ACTIVITY_PUSH, PUSH_PROXY } from "./envelope.js";

/** The current relay socket's send path and whether that socket advertised push-proxy. */
export class RelaySession {
  send: ((raw: string) => void) | null = null;
  frames: ((payloads: string[]) => void) | null = null;
  pushProxy = false;

  registered(opts: { send: (raw: string) => void; frames: (payloads: string[]) => void; pushProxy: boolean }): void {
    this.send = opts.send;
    this.frames = opts.frames;
    this.pushProxy = opts.pushProxy;
  }

  closed(): void {
    this.send = null;
    this.frames = null;
    this.pushProxy = false;
  }

  capabilities(base: string[], opts: { liveActivity: boolean; direct: boolean }): string[] {
    return [
      ...base,
      ...(opts.liveActivity ? [LIVE_ACTIVITY_PUSH] : []),
      ...(opts.direct ? [DIRECT] : []),
      ...(this.pushProxy ? [PUSH_PROXY] : []),
    ];
  }
}
