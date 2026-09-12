import { defineWorkersProject } from "@cloudflare/vitest-pool-workers/config";
import { defineConfig } from "vitest/config";

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
          include: ["src/worker.test.ts"],
          poolOptions: { workers: { wrangler: { configPath: "./wrangler.toml" } } },
        },
      }),
    ],
  },
});
