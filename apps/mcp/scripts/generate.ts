// Builds src/content.json from the repository: README and docs, the app's settings keys, the Info.plist usage
// strings and entitlements, the troubleshooting tables and CHANGELOG.md. `--check` fails when the committed
// bundle differs from what the sources produce now, except for release notes alone. Run from anywhere: paths resolve from this file.
import { existsSync, readFileSync, readdirSync, renameSync, writeFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { AppSetting, Content, Doc, HostSetting, Permission, Platform, Release, Section, SetupGuide, TroubleEntry } from "../src/content.ts";
import { findPersonalData } from "./privacy.ts";

const pkg = join(dirname(fileURLToPath(import.meta.url)), "..");
const root = join(pkg, "../..");
const out = join(pkg, "src/content.json");
const problems: string[] = [];

const read = (path: string) => readFileSync(join(root, path), "utf8");
const json = (path: string) => JSON.parse(readFileSync(join(pkg, path), "utf8"));
function fail(message: string): never {
  throw new Error(message);
}
function quoted(file: string, text: string): string {
  if (!existsSync(join(root, file))) problems.push(`${file} is gone (quoted by the help bundle)`);
  else if (!read(file).includes(text)) problems.push(`${file} no longer contains ${JSON.stringify(text)}`);
  return file;
}

// --- Docs ---------------------------------------------------------------------------------------------------

function slug(heading: string): string {
  return heading.toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu, "").trim().replace(/\s/g, "-");
}

/** Splits markdown into sections at headings outside fenced code. Text before the first heading is dropped. */
function sections(markdown: string): Section[] {
  const result: Section[] = [];
  let fenced = false;
  for (const line of markdown.split("\n")) {
    if (/^\s*```/.test(line)) fenced = !fenced;
    const heading = !fenced && /^(#{1,6})\s+(.+?)\s*#*\s*$/.exec(line);
    if (heading) result.push({ heading: heading[2], anchor: slug(heading[2]), level: heading[1].length, text: "" });
    else if (result.length) result[result.length - 1].text += line + "\n";
  }
  for (const section of result) section.text = section.text.trim();
  return result;
}

/** A heading's own text plus its subsections', up to the next heading at its level or above. */
function sectionTree(doc: Doc, heading: string): string {
  const start = doc.sections.findIndex((s) => s.heading === heading);
  if (start < 0) fail(`${doc.path} has no heading "${heading}"`);
  const level = doc.sections[start].level;
  const parts = [doc.sections[start].text];
  for (const s of doc.sections.slice(start + 1)) {
    if (s.level <= level) break;
    parts.push(`${"#".repeat(s.level)} ${s.heading}\n\n${s.text}`);
  }
  return parts.join("\n\n").trim();
}

function docs(): Doc[] {
  const paths = [
    "README.md",
    ...readdirSync(join(root, "docs")).filter((f) => f.endsWith(".md")).sort().map((f) => `docs/${f}`),
    "plugins/openclaw-yorozu/README.md",
  ];
  return paths.map((path) => {
    const id = path === "README.md" ? "readme" : path.startsWith("plugins/") ? "plugin" : path.slice(5, -3);
    const text = read(path).trim();
    const title = /^#\s+(.+)$/m.exec(text)?.[1] ?? path;
    return { id, path, title, uri: `yorozu://docs/${id}`, text, sections: sections(text) };
  });
}

// --- Settings -----------------------------------------------------------------------------------------------

interface SwiftFacts {
  constants: Map<string, string>;
  cases: Map<string, string[]>;
  /** Raw values that differ from the case name, by `Type.case`. */
  raw: Map<string, string>;
  storage: { ref: string; defaultExpr: string; file: string }[];
}

function swiftFiles(dir: string): string[] {
  return readdirSync(join(root, dir), { withFileTypes: true })
    .sort((a, b) => a.name.localeCompare(b.name))
    .flatMap((e) => (e.isDirectory() ? swiftFiles(`${dir}/${e.name}`) : e.name.endsWith(".swift") ? [`${dir}/${e.name}`] : []));
}

function swiftFacts(files: { path: string; text: string }[]): SwiftFacts {
  const facts: SwiftFacts = { constants: new Map(), cases: new Map(), raw: new Map(), storage: [] };
  for (const { path, text } of files) {
    let type = "";
    const lines = text.split("\n");
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const decl = /^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|public|internal|final|nonisolated)\s+)*(?:enum|struct|class|actor|extension)\s+(\w+)/.exec(line);
      if (decl) type = decl[1];
      const constant = /^\s*(?:(?:private|fileprivate|nonisolated)\s+)*static\s+let\s+(\w+)\s*=\s*"([^"]+)"/.exec(line);
      if (constant && type) facts.constants.set(`${type}.${constant[1]}`, constant[2]);
      const raw = /^\s*case\s+([a-z]\w*)\s*=\s*"([^"]*)"\s*$/.exec(line);
      if (raw && type) {
        facts.cases.set(type, [...(facts.cases.get(type) ?? []), raw[2]]);
        facts.raw.set(`${type}.${raw[1]}`, raw[2]);
      }
      if (/^\s*case\s+[a-z]\w*(\s*,\s*[a-z]\w*)*\s*,?\s*$/.test(line) && type) {
        let list = line;
        while (list.trimEnd().endsWith(",") && i + 1 < lines.length) list += lines[++i];
        const names = list.replace(/^\s*case\s+/, "").split(",").map((s) => s.trim()).filter(Boolean);
        facts.cases.set(type, [...(facts.cases.get(type) ?? []), ...names]);
      }
      const storage = /@AppStorage\((\w+\.\w+)(?:,\s*store:\s*[\w.]+)?\)\s+(?:private\s+)?var\s+\w+\s*(?:=\s*(.+?)|:\s*(\w+)\?)\s*$/.exec(line);
      // An optional setting (`var x: Kind?`) has no default: unset until the owner picks one.
      if (storage) facts.storage.push({ ref: storage[1], defaultExpr: storage[2] ?? `${storage[3]}.`, file: path });
    }
  }
  return facts;
}

function appSettings(): AppSetting[] {
  // The voice package declares the types some settings store.
  const files = [...swiftFiles("apps/ios/Sources"), ...swiftFiles("packages/YorozuVoice/Sources")].map((path) => ({ path, text: read(path) }));
  const facts = swiftFacts(files);
  const curated: Record<string, Omit<AppSetting, "key" | "type" | "default" | "options" | "source">> = json("content/settings.json").app;
  const found = new Map<string, AppSetting>();
  for (const { ref, defaultExpr, file } of facts.storage) {
    const key = facts.constants.get(ref) ?? fail(`@AppStorage(${ref}) in ${file}: no string constant ${ref}`);
    let setting: Pick<AppSetting, "type" | "default" | "options">;
    if (defaultExpr === "true" || defaultExpr === "false") setting = { type: "boolean", default: defaultExpr === "true" };
    else if (/^-?\d+$/.test(defaultExpr)) setting = { type: "integer", default: Number(defaultExpr) };
    else if (defaultExpr === '""') setting = { type: "string", default: "" };
    else {
      const parts = defaultExpr.split(".");
      const kind = parts.at(-2) ?? "";
      const options = facts.cases.get(kind) ?? fail(`@AppStorage(${ref}) in ${file}: unknown default ${defaultExpr}`);
      const name = parts.at(-1)!;
      setting = { type: "enum", default: name ? (facts.raw.get(`${kind}.${name}`) ?? name) : null, options };
    }
    const previous = found.get(key);
    if (previous && previous.default !== setting.default) fail(`${key} has defaults ${previous.default} and ${setting.default}`);
    const about = curated[key];
    if (!about) {
      problems.push(`app setting "${key}" (${file}) has no entry in apps/mcp/content/settings.json`);
      continue;
    }
    found.set(key, { key, ...about, ...setting, source: [...new Set([...(previous?.source ?? []), file])] });
  }
  for (const key of Object.keys(curated)) if (!found.has(key) && !problems.some((p) => p.includes(`"${key}"`)))
    problems.push(`apps/mcp/content/settings.json describes "${key}", which no @AppStorage in apps/ios/Sources uses`);
  return [...found.values()].sort((a, b) => a.key.localeCompare(b.key));
}

function hostSettings(setup: Doc): HostSetting[] {
  const manifest = "plugins/openclaw-yorozu/openclaw.plugin.json";
  const schema = JSON.parse(read(manifest)).channelConfigs.yorozu.schema.properties as Record<string, { type: string }>;
  const rows = [...sectionTree(setup, "2. Config").matchAll(/^\|\s*`channels\.yorozu\.(\w+)`\s*\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*$/gm)];
  const documented = new Set(rows.map((r) => r[1]));
  for (const key of Object.keys(schema)) if (!documented.has(key)) problems.push(`channels.yorozu.${key} (${manifest}) is missing from the Config table in docs/setup.md`);
  return rows.map(([, key, defaultText, meaning]) => {
    const property = schema[key];
    if (!property) problems.push(`docs/setup.md documents channels.yorozu.${key}, which ${manifest} doesn't define`);
    return {
      key: `channels.yorozu.${key}`,
      type: property?.type ?? "unknown",
      default: defaultText.replace(/`/g, ""),
      description: meaning,
      set: `openclaw config set channels.yorozu.${key} <value>`,
      source: [manifest, "docs/setup.md#2-config"],
    };
  });
}

// --- Troubleshooting, permissions, guides, releases ---------------------------------------------------------

function troubleshooting(setup: Doc): TroubleEntry[] {
  const table = sectionTree(setup, "Troubleshooting");
  const rows = [...table.matchAll(/^\|\s*(.+?)\s*\|\s*(.+?)\s*\|\s*$/gm)].filter((r) => !/^-+$/.test(r[1]) && r[1] !== "Symptom");
  const fromDocs = rows.map(([, symptom, fix]) => ({ symptom, fix, source: "docs/setup.md#troubleshooting" }));
  const curated: { symptom: string; fix: string; quotes: { file: string; text: string }[] }[] = json("content/troubleshooting.json").entries;
  const fromApp = curated.map(({ symptom, fix, quotes }) => ({ symptom, fix, source: quotes.map((q) => quoted(q.file, q.text)).filter((f, i, all) => all.indexOf(f) === i).join(", ") }));
  return [...fromApp, ...fromDocs];
}

function permissions(): Record<Platform, Permission[]> {
  const projectPath = "apps/ios/Project.swift";
  const project = read(projectPath);
  const start = project.indexOf('name: "YorozuIOS"');
  const end = project.indexOf(".target(", start);
  if (start < 0 || end < 0) fail(`${projectPath}: no YorozuIOS target`);
  const app = project.slice(start, end);
  const curated = json("content/permissions.json");
  const meaning = (group: "usage" | "entitlements", key: string) => {
    const text = curated[group][key];
    if (!text) problems.push(`${key} has no entry under "${group}" in apps/mcp/content/permissions.json`);
    return text ?? "";
  };
  const usage: Permission[] = [...app.matchAll(/"(NS\w+UsageDescription)":\s*"([^"]*)"/g)].map(([, key, prompt]) => ({
    key, kind: "usage", prompt, meaning: meaning("usage", key), source: projectPath,
  }));
  const iosEntitlements = /entitlements:\s*\.dictionary\(\[([\s\S]*?)\]\),\n/.exec(app)?.[1] ?? fail(`${projectPath}: YorozuIOS has no entitlements dictionary`);
  const entitlement = (key: string, source: string): Permission => ({ key, kind: "entitlement", meaning: meaning("entitlements", key), source });
  const ios = [...iosEntitlements.matchAll(/"([a-z][\w.-]+)":/g)].map((m) => entitlement(m[1], projectPath));
  const macPath = "apps/ios/Resources/MacHardenedRuntime.entitlements";
  const mac = [...read(macPath).matchAll(/<key>([^<]+)<\/key>/g)].map((m) => entitlement(m[1], macPath));
  const used = new Set([...usage, ...ios, ...mac].map((p) => p.key));
  for (const group of ["usage", "entitlements"] as const)
    for (const key of Object.keys(curated[group])) if (!used.has(key)) problems.push(`apps/mcp/content/permissions.json describes ${key}, which the app no longer declares`);
  const runtime = (platform: Platform): Permission[] =>
    curated.runtime
      .filter((r: { platforms: Platform[] }) => r.platforms.includes(platform))
      .map((r: { name: string; meaning: string; quote: { file: string; text: string } }) => ({ key: r.name, kind: "runtime", meaning: r.meaning, source: quoted(r.quote.file, r.quote.text) }));
  return { ios: [...usage, ...ios, ...runtime("ios")], macos: [...usage, ...mac, ...runtime("macos")] };
}

function guides(all: Doc[]): Record<Platform, SetupGuide> {
  const curated = json("content/setup-guides.json").platforms;
  const build = (platform: Platform): SetupGuide => ({
    platform,
    title: curated[platform].title,
    steps: curated[platform].steps.map((step: { title: string; text: string; section?: { doc: string; heading: string }; inline?: boolean; quote?: { file: string; text: string } }) => {
      if (step.quote) quoted(step.quote.file, step.quote.text);
      if (!step.section) return { title: step.title, text: step.text };
      const doc = all.find((d) => d.id === step.section!.doc) ?? fail(`setup-guides.json: no doc "${step.section.doc}"`);
      const details = sectionTree(doc, step.section.heading);
      const link = `${doc.uri}#${slug(step.section.heading)}`;
      return step.inline === false ? { title: step.title, text: step.text, doc: link } : { title: step.title, text: step.text, doc: link, details };
    }),
  });
  return { ios: build("ios"), macos: build("macos") };
}

function releases(changelog: string): Release[] {
  return [...changelog.matchAll(/^## (\d+\.\d+\.\d+)\s*\n([\s\S]*?)(?=^## |(?![\s\S]))/gm)].map(([, version, text]) => ({ version, text: text.trim() }));
}

// --- Main ---------------------------------------------------------------------------------------------------

function generate(): string {
  const all = docs();
  const setup = all.find((d) => d.id === "setup") ?? fail("docs/setup.md is missing");
  const content: Content = {
    docs: all,
    settings: { app: appSettings(), host: hostSettings(setup) },
    troubleshooting: troubleshooting(setup),
    permissions: permissions(),
    guides: guides(all),
    releases: releases(read("CHANGELOG.md")),
  };
  if (!content.releases.length) problems.push("CHANGELOG.md has no ## x.y.z sections");
  const text = JSON.stringify(content, null, 1) + "\n";
  for (const hit of findPersonalData(text)) problems.push(`personal data in the bundle: ${hit}`);
  if (problems.length) fail(`The help bundle can't be generated:\n- ${problems.join("\n- ")}`);
  return text;
}

function withoutReleases(text: string): string | undefined {
  try {
    return JSON.stringify({ ...JSON.parse(text), releases: [] });
  } catch {
    return undefined;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  const check = process.argv.includes("--check");
  try {
    const text = generate();
    const current = existsSync(out) ? readFileSync(out, "utf8") : "";
    if (check) {
      const name = relative(root, out);
      if (current !== text && withoutReleases(current) !== withoutReleases(text)) {
        console.error(`${name} is stale. Run: pnpm --filter @yorozu/help-mcp generate`);
        process.exit(1);
      }
      // A stable release PR changes only CHANGELOG.md (scripts/release_pr.sh) and must stay green, so
      // release notes alone never fail the check; the next regeneration picks them up.
      if (current !== text) console.warn(`${name}: only the release notes are behind CHANGELOG.md; the next generate picks them up.`);
      else console.log(`${name} is up to date.`);
    } else if (current === text) {
      console.log(`${relative(root, out)} is already up to date.`);
    } else {
      writeFileSync(`${out}.tmp`, text);
      renameSync(`${out}.tmp`, out);
      console.log(`Wrote ${relative(root, out)}.`);
    }
  } catch (error) {
    console.error((error as Error).message);
    process.exit(1);
  }
}
