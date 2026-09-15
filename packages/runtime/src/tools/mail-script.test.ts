import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { expect, test } from "vitest";

test.skipIf(process.platform !== "darwin")("native mail.read returns text, not an AppleScript list", () => {
  const source = readFileSync(new URL("../../../../apps/mac/Sources/YorozuNative/Apple.swift", import.meta.url), "utf8");
  const read = source.slice(source.indexOf("static func mailRead("));
  const expression = read.match(/return (\(.*?\n\s*\(\(date received of m\).*?\(content of m\))/s)?.[1];
  expect(expression).toBeDefined();
  // Execute the production return expression with synthetic fields: no Mail launch,
  // account access, or private message content needed to catch the descriptor-type bug.
  const script = expression!
    .replaceAll("(id of m)", "68013")
    .replaceAll("(sender of m)", '"sender@example.com"')
    .replaceAll("(subject of m)", '"Subject"')
    .replaceAll("(date received of m)", '"Date"')
    .replaceAll("(content of m)", '"Body"');
  const run = (text: string) => execFileSync("/usr/bin/osascript", ["-e", text], { encoding: "utf8" }).trimEnd();
  expect(run(`return class of (${script})`)).toBe("text");
  expect(run(`return ${script}`)).toBe("68013\tsender@example.com\tSubject\tDate\nBody");
});
