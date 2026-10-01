import { fromBase64Url, toBase64Url, type YorozuEvent } from "@yorozu/shared";
import { syncHostRequest } from "./rust-sync.js";
type Opened = { status: "opened"; event: YorozuEvent; seq?: number } | { status: "unauthenticated" | "malformed" };
/** Rust holds the persisted private identity. This facade exchanges public identifiers,
 * messages and authenticated results through the pinned local worker. */
export class WireCrypto {
  readonly sessionPub: Uint8Array;
  readonly signingPub: Uint8Array;
  constructor(private readonly dir: string) {
    const identity = this.request({ op: "crypto_open" });
    if (identity.unavailable === true) throw new Error("Yorozu couldn't access its connection identity. Restore the saved identity or check storage access, then try again.");
    this.sessionPub = fromBase64Url(identity.sessionPub as string);
    this.signingPub = fromBase64Url(identity.signingPub as string);
    if (this.sessionPub.length !== 32 || this.signingPub.length !== 32) throw new Error("Rust session remains unconfirmed");
  }
  private request(data: Record<string, unknown>): Record<string, unknown> {
    try { return syncHostRequest(this.dir, data); }
    catch { throw new Error("Rust session remains unconfirmed"); }
  }
  validate(pub: string): void { if (this.request({ op: "crypto_peer", pub }).valid !== true) throw new Error("Rust session remains unconfirmed"); }
  forget(pub: string): void { this.request({ op: "crypto_forget", pub }); }
  sign(message: Uint8Array): Uint8Array {
    const signature = fromBase64Url(this.request({ op: "crypto_sign", message: toBase64Url(message) }).signature as string);
    if (signature.length !== 64) throw new Error("Rust session remains unconfirmed");
    return signature;
  }
  helloProof(secret: string, pub: string, signingPub: string): string {
    return this.request({ op: "crypto_hello_proof", secret, pub, signingPub }).proof as string;
  }
  private box(data: Record<string, unknown>): { n: string; c: string } {
    const result = this.request({ op: "crypto_seal", ...data });
    if (typeof result.nonce !== "string" || typeof result.ciphertext !== "string") throw new Error("Rust session remains unconfirmed");
    return { n: result.nonce, c: result.ciphertext };
  }
  seal(pub: string, event: YorozuEvent, seq?: number): { n: string; c: string } {
    return this.box({ pub, event, mode: seq === undefined ? "legacy" : "current", ...(seq === undefined ? {} : { seq }) });
  }
  preview(pub: string, plaintext: Uint8Array): { n: string; c: string } {
    return this.box({ pub, mode: "preview", plaintext: toBase64Url(plaintext) });
  }
  open(pub: string, box: { n: string; c: string }, legacy = false): Opened {
    const result = this.request({ op: "crypto_open_box", pub, mode: legacy ? "legacy" : "current", nonce: box.n, ciphertext: box.c });
    if (!["opened", "malformed", "unauthenticated"].includes(result.status as string)) throw new Error("Rust session remains unconfirmed");
    return result as Opened;
  }
}
