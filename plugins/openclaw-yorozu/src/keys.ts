/**
 * The host identity: an X25519 static key (Noise, and the QR's `key`) and an Ed25519 relay key (the room and
 * every signed frame). Made on first start, then kept in OpenClaw's credentials store, `0600`, and never logged.
 */
import path from "node:path";
import { createSecretFileAtomic, tryReadSecretFileSync } from "openclaw/plugin-sdk/secret-file";
import { resolveOAuthDir } from "openclaw/plugin-sdk/state-paths";
import { b64u, ed25519Keypair, fromB64u, roomId, x25519Keypair, type Keypair } from "./wire.js";

export type HostKeys = { static: Keypair; signing: Keypair; room: string };

/** `<stateDir>/credentials/yorozu/host-keys.json`: the two private keys, base64url. */
export const hostKeysPath = (): string => path.join(resolveOAuthDir(), "yorozu", "host-keys.json");

type Stored = { v: 1; static: string; signing: string };

function parse(text: string): HostKeys {
  const stored = JSON.parse(text) as Partial<Stored>;
  const staticPriv = typeof stored.static === "string" ? fromB64u(stored.static) : null;
  const signingPriv = typeof stored.signing === "string" ? fromB64u(stored.signing) : null;
  if (stored.v !== 1 || staticPriv?.length !== 32 || signingPriv?.length !== 32) {
    throw new Error("yorozu host key file is malformed");
  }
  const signing = ed25519Keypair(signingPriv);
  return { static: x25519Keypair(staticPriv), signing, room: roomId(signing.publicKey) };
}

/** Reads the host keys, making them on first start. A malformed file throws: replacing it would unpair every device. */
export async function loadHostKeys(): Promise<HostKeys> {
  const filePath = hostKeysPath();
  const existing = tryReadSecretFileSync(filePath, "yorozu host keys");
  if (existing) return parse(existing);
  const fresh: Stored = {
    v: 1,
    static: b64u(x25519Keypair().privateKey),
    signing: b64u(ed25519Keypair().privateKey),
  };
  try {
    await createSecretFileAtomic({
      rootDir: resolveOAuthDir(),
      filePath,
      content: JSON.stringify(fresh),
    });
  } catch (error) {
    // First writer wins: another start got there in between, so its keys are the ones.
    const raced = tryReadSecretFileSync(filePath, "yorozu host keys");
    if (!raced) throw error;
    return parse(raced);
  }
  return parse(JSON.stringify(fresh));
}
