// Patterns that must never reach the public bundle: home-directory paths, email addresses and credential shapes.
const patterns: [string, RegExp][] = [
  ["home directory path", /\/(?:Users|home)\/[A-Za-z0-9._-]+/],
  ["email address", /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/],
  ["GitHub token", /\bgh[pousr]_[A-Za-z0-9]{20,}/],
  ["API key", /\bsk-[A-Za-z0-9_-]{20,}/],
  ["Slack token", /\bxox[abprs]-[A-Za-z0-9-]{10,}/],
  ["AWS access key", /\bAKIA[0-9A-Z]{16}\b/],
  ["private key", /-----BEGIN [A-Z ]*PRIVATE KEY-----/],
  ["JWT", /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]+/],
];

/** Each personal-data match in `text`, as "kind: match". Empty when the text is clean. */
export function findPersonalData(text: string): string[] {
  const found: string[] = [];
  for (const [kind, pattern] of patterns) {
    for (const match of text.matchAll(new RegExp(pattern, "g"))) found.push(`${kind}: ${match[0]}`);
  }
  return found;
}
