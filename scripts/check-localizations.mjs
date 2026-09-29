import { readFileSync, readdirSync } from "node:fs";
import { resolve, join } from "node:path";

// Validate the shipped catalogs, or a specific catalog against Swift compiler extraction.
// Compiler .stringsdata records reachability without guessing keys from source text.
const defaults = [
  "apps/ios/Resources/Localizable.xcstrings",
  "apps/ios/Resources/InfoPlist.xcstrings",
  "apps/ios/Resources/YorozuWatch/Localizable.xcstrings",
  "apps/mac/Resources/Localizable.xcstrings",
  "apps/mac/Resources/InfoPlist.xcstrings",
];
const [catalogPath, extractionDirectory] = process.argv.slice(2);
const errors = [];

function placeholders(value) {
  let next = 1;
  return [...value.matchAll(/%%|%(?:(\d+)\$)?[-+ #0]*(?:\d+)?(?:\.\d+)?(hh|h|ll|l|z|t|j)?([@diuoxXfFeEgGcCsSp])/g)]
    .filter(match => match[0] !== "%%")
    .map(match => `${match[1] ?? next++}:${match[2] ?? ""}${match[3]}`)
    .sort().join(",");
}

function units(localization) {
  if (!localization) return [];
  if (localization.stringUnit) return [localization.stringUnit];
  return Object.values(localization).flatMap(value => value && typeof value === "object" ? units(value) : []);
}

for (const path of catalogPath ? [catalogPath] : defaults) {
  const catalog = JSON.parse(readFileSync(resolve(path), "utf8"));
  if (catalog.sourceLanguage !== "en") errors.push(`${path}: source language must be en`);
  for (const [key, entry] of Object.entries(catalog.strings)) {
    if (entry.shouldTranslate === false) continue;
    const english = units(entry.localizations?.en);
    const source = english[0]?.value ?? key;
    const japanese = units(entry.localizations?.ja);
    if (!japanese.length) errors.push(`${path}: missing Japanese: ${key}`);
    for (const unit of japanese) {
      if (unit.state !== "translated" || !unit.value.trim()) errors.push(`${path}: unfinished Japanese: ${key}`);
      if (placeholders(source) !== placeholders(unit.value)) errors.push(`${path}: Japanese placeholder mismatch: ${key}`);
    }
  }
  if (extractionDirectory) {
    for (const file of readdirSync(extractionDirectory)) {
      if (!file.endsWith(".stringsdata")) continue;
      const extracted = JSON.parse(readFileSync(join(extractionDirectory, file), "utf8"));
      for (const entry of extracted.tables?.Localizable ?? []) {
        if (!Object.hasOwn(catalog.strings, entry.key)) errors.push(`${path}: missing compiler key: ${entry.key} (${file})`);
      }
    }
  }
}
if (errors.length) {
  console.error(errors.join("\n"));
  process.exitCode = 1;
} else {
  console.log("English/Japanese catalogs and interpolation placeholders verified.");
}
