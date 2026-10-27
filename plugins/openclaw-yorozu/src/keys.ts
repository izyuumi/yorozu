import path from "node:path";
import { createSecretFileAtomic, tryReadSecretFileSync } from "openclaw/plugin-sdk/secret-file";
import { resolveOAuthDir } from "openclaw/plugin-sdk/state-paths";
import { b64u, ed25519Keypair, fromB64u, roomId, x25519Keypair, type Keypair } from "./wire.js";

export type HostKeys = { static: Keypair; signing: Keypair; room: string };

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
    const raced = tryReadSecretFileSync(filePath, "yorozu host keys");
    if (!raced) throw error;
    return parse(raced);
  }
  return parse(JSON.stringify(fresh));
}
