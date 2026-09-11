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

export function frontmatter(text: string): Frontmatter {
  const head = /^---\r?\n([\s\S]*?)\r?\n---\r?\n?/.exec(text);
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
