import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, expect, test } from "vitest";
import {
  agentsDir,
  inherit,
  installAgents,
  listAgents,
  loadAgent,
  parseAgent,
  type AgentConfig,
} from "./agents.js";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-agents-"));
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
});

const write = (name: string, text: string): void => writeFileSync(join(dir, `${name}.md`), text);

test("the body is the prompt and the frontmatter is optional", () => {
  expect(parseAgent("calendar", "Handle calendars.\n")).toEqual({
    name: "calendar",
    prompt: "Handle calendars.",
  });

  expect(
    parseAgent(
      "email",
      [
        "---",
        "description: reads and sends email",
        "model: claude-cli/claude-sonnet-5",
        "tools: [echo, remember]",
        "memory: email",
        "unknown: ignored",
        "---",
        "",
        "You handle email.",
        "",
      ].join("\n"),
    ),
  ).toEqual({
    name: "email",
    prompt: "You handle email.",
    description: "reads and sends email",
    model: "claude-cli/claude-sonnet-5",
    tools: ["echo", "remember"],
    memory: "email",
  });
});

test("an empty tools list is a restriction, not an absent field", () => {
  expect(parseAgent("mute", "---\ntools:\n---\nNo tools.").tools).toEqual([]);
  expect(parseAgent("free", "No frontmatter.").tools).toBeUndefined();
});

test("absent fields inherit the main agent's, present ones win", () => {
  const main: AgentConfig = {
    name: "main",
    prompt: "You are Yorozu.",
    model: "openai/gpt-4o-mini",
    memory: "shared",
  };

  expect(inherit({ name: "calendar", prompt: "Calendars." }, main)).toEqual({
    name: "calendar",
    prompt: "Calendars.",
    model: "openai/gpt-4o-mini",
    memory: "shared",
  });

  expect(
    inherit({ name: "email", prompt: "Email.", model: "codex-cli/gpt-5.6", tools: ["echo"] }, main),
  ).toEqual({
    name: "email",
    prompt: "Email.",
    model: "codex-cli/gpt-5.6",
    tools: ["echo"],
    memory: "shared",
  });
});

test("the bundled agents install once and never overwrite an edited file", () => {
  installAgents(dir);
  const names = listAgents(dir).map((agent) => agent.name);
  expect(names).toEqual(["browser", "calendar", "email", "main", "reservation"]);
  expect(loadAgent("main", dir)?.prompt).toContain("Yorozu");
  expect(loadAgent("calendar", dir)?.description).toBe("reads and edits the user's calendar");

  write("main", "Mine now.");
  rmSync(join(dir, "email.md"));
  installAgents(dir);

  expect(readFileSync(join(dir, "main.md"), "utf8")).toBe("Mine now.");
  // A deleted agent comes back: only the file's absence is what "missing" means.
  expect(loadAgent("email", dir)?.name).toBe("email");
});

test("a newer bundle refreshes untouched agents and leaves edited ones alone", () => {
  const bundle = mkdtempSync(join(tmpdir(), "yorozu-bundle-"));
  writeFileSync(join(bundle, "main.md"), "v1 main");
  writeFileSync(join(bundle, "calendar.md"), "v1 calendar");
  installAgents(dir, bundle);
  write("main", "Mine now.");

  writeFileSync(join(bundle, "main.md"), "v2 main");
  writeFileSync(join(bundle, "calendar.md"), "v2 calendar");
  installAgents(dir, bundle);

  expect(readFileSync(join(dir, "main.md"), "utf8")).toBe("Mine now.");
  expect(readFileSync(join(dir, "calendar.md"), "utf8")).toBe("v2 calendar");
  expect(listAgents(dir).map((agent) => agent.name)).not.toContain(".bundled");
});

test("agents live under the state directory and unknown names resolve to nothing", () => {
  expect(agentsDir("/tmp/state")).toBe("/tmp/state/agents");
  expect(listAgents(join(dir, "nope"))).toEqual([]);
  write("calendar", "Calendars.");
  expect(loadAgent("../../etc/passwd", dir)).toBeUndefined();
});
