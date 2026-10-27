import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { generateKeyPairSync } from "node:crypto";
import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

const poolRequire = createRequire(import.meta.resolve("@cloudflare/vitest-pool-workers"));
const miniflareRequire = createRequire(poolRequire.resolve("miniflare"));
const supported = miniflareRequire("workerd").compatibilityDate as string;
const configured = readFileSync(new URL("./wrangler.toml", import.meta.url), "utf8")
  .match(/^compatibility_date\s*=\s*"(\d{4}-\d{2}-\d{2})"/m)?.[1];
if (!configured || !supported || configured > supported) {
  throw new Error(`Relay compatibility date ${configured} exceeds test workerd ${supported}; update the test pool before changing deployment behavior.`);
}

const apns = {
  APNS_KEY_ID: "KEY123456",
  APNS_TEAM_ID: "TEAM12345",
  APNS_KEY_P8: generateKeyPairSync("ec", { namedCurve: "P-256" })
    .privateKey.export({ type: "pkcs8", format: "pem" })
    .toString(),
  APNS_HOST: "apns.test",
  APNS_SANDBOX_HOST: "apns-sandbox.test",
};

export default defineConfig({
  test: {
    projects: [
      { test: { name: "node", include: ["src/index.test.ts", "src/protocol.test.ts"] } },
      {
        plugins: [
          cloudflareTest({
            wrangler: { configPath: "./wrangler.toml" },
            miniflare: { bindings: apns },
          }),
        ],
        test: {
          name: "worker",
          include: ["src/worker.test.ts", "src/apns.test.ts", "src/mailbox.test.ts"],
        },
      },
    ],
  },
});
