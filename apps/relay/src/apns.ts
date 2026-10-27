/// <reference types="@cloudflare/workers-types" />

import { APNS_TIMEOUT_MS } from "./protocol.js";

export interface ApnsEnv {
  APNS_KEY_ID?: string;
  APNS_TEAM_ID?: string;
  APNS_KEY_P8?: string;
  APNS_HOST?: string;
  APNS_SANDBOX_HOST?: string;
  APNS_TOPIC?: string;
}

export const DEFAULT_HOST = "api.push.apple.com";
export const SANDBOX_HOST = "api.sandbox.push.apple.com";
export const DEFAULT_TOPIC = "to.yumi.yorozu.ios";
export const TOKEN_TTL_MS = 50 * 60_000;

export const configured = (env: ApnsEnv): boolean =>
  Boolean(env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_KEY_P8);

const b64url = (bytes: Uint8Array): string =>
  btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

const utf8 = (text: string): Uint8Array => new TextEncoder().encode(text);

function pkcs8(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/, "")
    .replace(/-----END [^-]+-----/, "")
    .replace(/\s+/g, "");
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
}

let cached: { token: string; at: number; kid: string } | null = null;

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
  token: string;
  payload: unknown;
  pushType: "alert" | "background";
  priority?: number;
}

export type ApnsResult = { status: number; reason?: string };

export async function send(
  env: ApnsEnv,
  request: ApnsRequest,
  now: number = Date.now(),
  sandbox = false,
): Promise<ApnsResult> {
  const host = sandbox ? (env.APNS_SANDBOX_HOST ?? SANDBOX_HOST) : (env.APNS_HOST ?? DEFAULT_HOST);
  const response = await fetch(`https://${host}/3/device/${request.token}`, {
    method: "POST",
    signal: AbortSignal.timeout(APNS_TIMEOUT_MS),
    headers: {
      authorization: `bearer ${await authToken(env, now)}`,
      "apns-topic": env.APNS_TOPIC ?? DEFAULT_TOPIC,
      "apns-push-type": request.pushType,
      "apns-priority": String(request.priority ?? 10),
      "content-type": "application/json",
    },
    body: JSON.stringify(request.payload),
  });
  if (response.ok) return { status: response.status };
  const body = (await response.json().catch(() => null)) as { reason?: string } | null;
  return { status: response.status, ...(body?.reason ? { reason: body.reason } : {}) };
}

export const gone = (status: number): boolean => status === 410;

export const misaddressed = ({ status, reason }: ApnsResult): boolean =>
  status === 400 && reason === "BadDeviceToken";
