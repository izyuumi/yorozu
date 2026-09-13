/// <reference types="@cloudflare/workers-types" />
/**
 * APNs, token-based. The relay holds an Apple auth key and signs a short-lived ES256 JWT with
 * it; there is no certificate to carry and nothing per-device to keep but the tokens phones
 * register themselves.
 *
 * What goes out of here is built in `protocol.ts` from a class and an opaque reference. This
 * file only signs, addresses and sends it — it never looks inside a payload and has no way to
 * put anything else in one.
 */

export interface ApnsEnv {
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  /** The .p8 itself, PEM, as a Wrangler secret. Never logged, never returned. */
  APNS_KEY_P8?: string;
  /** Overridden only by tests; TestFlight and the App Store are both production APNs. */
  APNS_HOST?: string;
  APNS_TOPIC?: string;
}

export const DEFAULT_HOST = "api.push.apple.com";
export const DEFAULT_TOPIC = "to.yumi.yorozu.ios";
/** Apple rejects a token older than an hour and throttles re-minting, so it is cached well inside that. */
export const TOKEN_TTL_MS = 50 * 60_000;

export const configured = (env: ApnsEnv): boolean =>
  Boolean(env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_KEY_P8);

const b64url = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

const utf8 = (text: string): Uint8Array => new TextEncoder().encode(text);

/** PKCS#8 out of the PEM Apple hands you, whitespace and armour and all. */
function pkcs8(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

/**
 * One JWT per isolate per 50 minutes. Held in a module variable rather than storage: it is
 * derived from the secret and the clock, so an isolate that lost it simply signs another.
 */
let cached: { token: string; at: number; kid: string } | null = null;

/** Exported for tests, which must not inherit a token another test minted. */
export const resetToken = (): void => void (cached = null);

export async function authToken(env: ApnsEnv, now: number = Date.now()): Promise<string> {
  const kid = env.APNS_KEY_ID!;
  if (cached && cached.kid === kid && now - cached.at < TOKEN_TTL_MS) return cached.token;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pkcs8(env.APNS_KEY_P8!),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const head = b64url(utf8(JSON.stringify({ alg: "ES256", kid })));
  const body = b64url(utf8(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) })));
  // WebCrypto signs ECDSA as the raw r‖s pair, which is exactly what JWS asks for.
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    utf8(`${head}.${body}`),
  );
  const token = `${head}.${body}.${b64url(new Uint8Array(sig))}`;
  cached = { token, at: now, kid };
  return token;
}

export interface ApnsRequest {
  /** The device token every alert for that phone is addressed to. */
  token: string;
  payload: unknown;
  /** 10 for something a person should see now, 5 for a background nudge. */
  priority?: number;
}

/**
 * Sends one push and reports the status. A token Apple no longer knows — the app was deleted
 * or reinstalled — comes back 410 or 400, which is the caller's cue to forget it.
 */
export async function send(
  env: ApnsEnv,
  request: ApnsRequest,
  now: number = Date.now(),
): Promise<number> {
  const host = env.APNS_HOST ?? DEFAULT_HOST;
  const response = await fetch(`https://${host}/3/device/${request.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await authToken(env, now)}`,
      "apns-topic": env.APNS_TOPIC ?? DEFAULT_TOPIC,
      "apns-push-type": "alert",
      "apns-priority": String(request.priority ?? 10),
      "content-type": "application/json",
    },
    body: JSON.stringify(request.payload),
  });
  return response.status;
}

/** Whether a status means the token is dead and should be dropped rather than retried. */
export const gone = (status: number): boolean => status === 410 || status === 400;
