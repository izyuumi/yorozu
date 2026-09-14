/**
 * File tools: read, write, list. Unrestricted and running as the user, like `shell` —
 * Full Disk Access is what the onboarding wizard gets for them.
 * See docs/spec-v1.html section 3.
 */

import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { hashContent, summarize } from "../approval.js";
import type { Tool } from "../index.js";
import { expandHome, truncate } from "./shell.js";

export const fsReadTool: Tool = {
  name: "fs_read",
  description: "Read a text file and return its contents.",
  parameters: {
    type: "object",
    properties: { path: { type: "string", description: "Absolute path, or one starting with ~." } },
    required: ["path"],
  },
  // Same cap as shell output: a result the model cannot afford is no use to it.
  run: ({ path }) => truncate(readFileSync(expandHome(String(path ?? "")), "utf8")),
};

export const fsWriteTool: Tool = {
  name: "fs_write",
  description: "Write a text file, creating or replacing it and any missing parent directories.",
  actionClass: "edit-file",
  action: ({ path, content }) => ({
    target: expandHome(String(path ?? "")),
    operation: "edit",
    contentSummary: summarize(String(content ?? "")),
    contentHash: hashContent(String(content ?? "")),
    consequence: `Replaces ${expandHome(String(path ?? ""))} with this text.`,
  }),
  parameters: {
    type: "object",
    properties: {
      path: { type: "string", description: "Absolute path, or one starting with ~." },
      content: { type: "string" },
    },
    required: ["path", "content"],
  },
  run: ({ path, content }) => {
    const file = expandHome(String(path ?? ""));
    if (!file) throw new Error("fs_write: path is empty");
    const body = String(content ?? "");
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, body);
    return `wrote ${body.length} characters to ${file}`;
  },
};

export const fsListTool: Tool = {
  name: "fs_list",
  description: "List a directory. Sub-directories are marked with a trailing slash.",
  parameters: {
    type: "object",
    properties: { path: { type: "string", description: "Absolute path, or one starting with ~." } },
    required: ["path"],
  },
  run: ({ path }) => {
    const dir = expandHome(String(path ?? ""));
    const entries = readdirSync(dir, { withFileTypes: true })
      .map((entry) => {
        if (entry.isDirectory()) return `${entry.name}/`;
        // Size is the one thing the model would otherwise have to shell out for.
        const bytes = entry.isFile() ? statSync(`${dir}/${entry.name}`).size : 0;
        return entry.isFile() ? `${entry.name} (${bytes} bytes)` : entry.name;
      })
      .sort();
    return entries.length ? truncate(entries.join("\n")) : `${dir} is empty`;
  },
};
