#!/usr/bin/env node
// The smallest App Store Connect client that does the two things the TestFlight ticket
// needs and nothing else: read builds, and flip a beta group's public link on. Both are
// public-API endpoints, unlike creating the app record itself, which is why fastlane is
// still in build-ios.sh for that one step.
//
//   ASC_KEY_ID=… ASC_ISSUER_ID=… ASC_KEY_PATH=…/AuthKey_X.p8 \
//     node scripts/asc.mjs GET '/v1/builds?filter[app]=123'
//   … node scripts/asc.mjs POST /v1/betaGroups '{"data":{…}}'
//
// The key may also arrive base64 in ASC_KEY_P8, which is how CI carries it. Neither the
// key nor the token is ever printed.
import { createSign } from "node:crypto";
import { readFileSync } from "node:fs";

const b64 = (o) => Buffer.from(typeof o === "string" ? o : JSON.stringify(o)).toString("base64url");

export function token() {
  const keyId = process.env.ASC_KEY_ID;
  const issuer = process.env.ASC_ISSUER_ID;
  const key = process.env.ASC_KEY_P8
    ? Buffer.from(process.env.ASC_KEY_P8, "base64").toString()
    : readFileSync(process.env.ASC_KEY_PATH, "utf8");
  if (!keyId || !issuer) throw new Error("ASC_KEY_ID and ASC_ISSUER_ID are required");

  const head = b64({ alg: "ES256", kid: keyId, typ: "JWT" });
  const body = b64({
    iss: issuer,
    exp: Math.floor(Date.now() / 1000) + 600,
    aud: "appstoreconnect-v1",
  });
  // ES256 is the raw r‖s pair, not the DER sequence node signs by default.
  const sig = createSign("SHA256")
    .update(`${head}.${body}`)
    .sign({ key, dsaEncoding: "ieee-p1363" })
    .toString("base64url");
  return `${head}.${body}.${sig}`;
}

// A path is resolved against the public API; a full URL is passed through, which is how
// the one call the public API forbids — creating the app record — reaches the same
// endpoint fastlane's `produce` uses, on the console's own `iris` host, with this token.
export async function asc(method, path, body) {
  const url = path.startsWith("http") ? path : `https://api.appstoreconnect.apple.com${path}`;
  const res = await fetch(url, {
    method,
    headers: {
      Authorization: `Bearer ${token()}`,
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : {};
  if (!res.ok) throw new Error(`${method} ${url} → ${res.status} ${text}`);
  return json;
}

if (import.meta.filename === process.argv[1]) {
  const [method, path, body] = process.argv.slice(2);
  console.log(JSON.stringify(await asc(method, path, body && JSON.parse(body)), null, 2));
}
