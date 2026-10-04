import { createHash } from "node:crypto";
import { existsSync, realpathSync, statSync } from "node:fs";
import { dirname } from "node:path";
import type { EffectiveAgentScope } from "./agent-scope.js";
import { pathWithin, safeAgentPath } from "./agent-scope.js";

export interface AgentIsolationRuntime {
  command: string;
  args: string[];
  /** Curated code/interpreter/dependencies only; never an agent-state ancestor. */
  readPaths: string[];
  /** Fresh vendor runtime scratch. Host ledgers and account tokens stay outside it. */
  runtimeDir: string;
  /** A host-owned authenticated inference/tool broker. Never an arbitrary model URL. */
  brokerPorts: number[];
}
export interface AgentIsolatedLaunch {
  command: string;
  args: string[];
  policy: string;
  isolation: { backend: "macos-seatbelt-v1"; agentId: string; policyDigest: string };
}

const quoted = (value: string): string => JSON.stringify(value);
function filter(path: string): string {
  return `(${statSync(path).isDirectory() ? "subpath" : "literal"} ${quoted(path)})`;
}
/** Mandatory below-harness confinement on the selected Mac host. No permissive fallback.
 * The system profile language is private API: its availability is tested on this host,
 * not presented as a portable or App Store sandbox guarantee.
 */
export function isolatedAgentLaunch(scope: EffectiveAgentScope, runtime: AgentIsolationRuntime,
  platform = process.platform): AgentIsolatedLaunch {
  if (platform !== "darwin" || !existsSync("/usr/bin/sandbox-exec"))
    throw new Error("This host cannot enforce agent scope; the harness was not launched");
  if (scope.version !== 1 || !scope.agentId || scope.chain.at(-1) !== scope.agentId)
    throw new Error("Invalid host-minted agent scope");
  const command = realpathSync(runtime.command);
  const runtimeDir = safeAgentPath(runtime.runtimeDir, true);
  if (!statSync(runtimeDir).isDirectory()) throw new Error("Invalid vendor runtime directory");
  const readPaths = [...new Set([command, ...runtime.readPaths.map(path => realpathSync(path))])];
  const directories = scope.directories.map(grant => ({ ...grant, path: safeAgentPath(grant.path, true) }));
  const denied = scope.deniedRoots.map(path => safeAgentPath(path));
  // A broad dependency root must not accidentally expose private state or token stores.
  const overlaps = (path: string, root: string): boolean => pathWithin(path, root) || pathWithin(root, path);
  if (readPaths.some(path => denied.some(root => overlaps(path, root)))
    || directories.some(grant => denied.some(root => overlaps(grant.path, root))))
    throw new Error("Runtime or directory grant overlaps excluded private state");
  if (denied.some(root => overlaps(root, runtimeDir)))
    throw new Error("Vendor scratch enters an excluded private root");
  if (runtime.brokerPorts.length > 4 || runtime.brokerPorts.some(port => !Number.isInteger(port) || port < 1024 || port > 65535))
    throw new Error("Invalid host broker port");
  const ancestors = new Set<string>(["/", "/private", "/private/tmp", "/private/var", "/Library"]);
  for (const path of [runtimeDir, ...readPaths, ...directories.map(grant => grant.path)]) {
    for (let parent = dirname(path);; parent = dirname(parent)) {
      ancestors.add(parent);
      if (parent === "/") break;
    }
  }
  // Ancestor directory enumeration is necessary for dyld startup; it grants no descendant data.
  const lines = ["(version 1)", "(deny default)",
    "(allow process-exec process-fork signal sysctl-read)", "(allow file-read-metadata)",
    '(allow file-read* (subpath "/System") (subpath "/usr/lib") (subpath "/usr/bin") (subpath "/usr/share") (subpath "/bin") (subpath "/sbin") (subpath "/Library/Apple/System") (subpath "/private/var/db/dyld") (subpath "/private/var/db/uuidtext") (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random") (literal "/dev/zero"))',
    `(allow file-read* ${[...ancestors].sort().map(path => `(literal ${quoted(path)})`).join(" ")})`,
    `(allow file-read* ${[...readPaths, runtimeDir, ...directories.map(grant => grant.path)].map(filter).join(" ")})`,
    `(allow file-write* ${[runtimeDir, ...directories.filter(grant => grant.access === "write").map(grant => grant.path)].map(filter).join(" ")})`,
  ];
  for (const port of [...new Set(runtime.brokerPorts)])
    lines.push(`(allow network-outbound (remote tcp "127.0.0.1:${port}"))`);
  if (denied.length) lines.push(`(deny file-read-data file-write* ${denied.map(path => `(subpath ${quoted(path)})`).join(" ")})`);
  const policy = lines.join("\n") + "\n";
  return { command: "/usr/bin/sandbox-exec", args: ["-p", policy, command, ...runtime.args], policy,
    isolation: { backend: "macos-seatbelt-v1", agentId: scope.agentId,
      policyDigest: createHash("sha256").update(policy).digest("hex") } };
}
