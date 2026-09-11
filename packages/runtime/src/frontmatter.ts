/**
 * The `---` head shared by every markdown file the runtime reads: memory notes,
 * agent definitions and SKILL.md. Deliberately not YAML — one `key: value` per line,
 * tolerant of hand-edited files, no dependency.
 */

export interface Frontmatter {
  fields: Map<string, string>;
  /** Everything after the head, trimmed. */
  body: string;
}

const HEAD = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/;

export function frontmatter(text: string): Frontmatter {
  const head = HEAD.exec(text);
  const fields = new Map<string, string>();
  for (const line of head?.[1]?.split(/\r?\n/) ?? []) {
    const colon = line.indexOf(":");
    // Hand-written skills quote their description; the quotes are not part of the value.
    if (colon > 0) {
      fields.set(
        line.slice(0, colon).trim(),
        line.slice(colon + 1).trim().replace(/^["']|["']$/g, ""),
      );
    }
  }
  return { fields, body: text.slice(head?.[0]?.length ?? 0).trim() };
}

/**
 * Sets one field, in place, on the raw file text: everything the file already held —
 * comments, spacing, the body — survives. A file without a head gets one. `key` is always
 * the runtime's own, never model input.
 */
export function setField(text: string, key: string, value: string): string {
  const head = HEAD.exec(text);
  if (!head) return `---\n${key}: ${value}\n---\n${text}`;
  const line = new RegExp(`^${key}:.*$`, "m");
  const fields = head[1]!;
  const next = line.test(fields)
    ? fields.replace(line, `${key}: ${value}`)
    : `${fields}\n${key}: ${value}`;
  return `---\n${next}\n---\n${text.slice(head[0].length)}`;
}
