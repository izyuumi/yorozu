import { generateKeyPairSync } from "node:crypto";
import { defineWorkersProject } from "@cloudflare/vitest-pool-workers/config";
import { defineConfig } from "vitest/config";

/**
 * A throwaway Apple auth key for the push tests. The relay only ever signs a JWT with it and a
 * fake APNs receives the result, so any P-256 key will do — generated per run rather than
 * committed, because a private key in a repository is a bad habit even when it is a useless one.
 *
 * These have to be real bindings rather than fields a test assigns: a Durable Object is handed
 * its env by the runtime, so an `env` mutated in the test isolate never reaches the room.
 */
const apns = {
  APNS_KEY_ID: "KEY123456",
  APNS_TEAM_ID: "TEAM12345",
  APNS_KEY_P8: generateKeyPairSync("ec", { namedCurve: "P-256" })
    .privateKey.export({ type: "pkcs8", format: "pem" })
    .toString(),
  APNS_HOST: "apns.test",
  APNS_SANDBOX_HOST: "apns-sandbox.test",
};

/**
 * Two projects: the Node relay runs on Node, the Durable Object runs in workerd. They
 * cannot share a pool, so they share `protocol.ts` instead.
 */
export default defineConfig({
  test: {
    projects: [
      { test: { name: "node", include: ["src/index.test.ts", "src/protocol.test.ts"] } },
      defineWorkersProject({
        test: {
          name: "worker",
          include: ["src/worker.test.ts", "src/apns.test.ts"],
          poolOptions: {
            workers: {
              wrangler: { configPath: "./wrangler.toml" },
              miniflare: { bindings: apns },
            },
          },
        },
      }),
    ],
  },
});
