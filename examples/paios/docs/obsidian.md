# Using PAIOS with Obsidian

Optional. PAIOS is a plain folder of Markdown and needs no app. This page is for people who already use Obsidian or want to browse PAIOS with it. Nothing here is required, and the installer sets none of it up.

## Open it

Pick one:

- **PAIOS inside an existing vault.** Install PAIOS into your vault folder (`install.sh "/path/to/your vault"`). It appears as the `PAIOS` folder next to your own notes. Agents may read the rest of the vault but edit only inside `PAIOS/` unless you ask (see `System/Policies/Vault Boundary.md`).
- **PAIOS as its own vault.** In Obsidian choose "Open folder as vault" and select the `PAIOS` folder, or its parent folder.

Either way `PAIOS_ROOT` stays the folder that contains `PAIOS/`.

## Links

The default files use ordinary relative Markdown links such as `[Now](../Runtime/Now.md)`. Obsidian follows them and shows them in backlinks and the graph. Links to a file name with spaces use the angle-bracket form, `[text](<Some File.md>)`, which Obsidian also follows.

To keep new links in the same portable style, turn off Settings → Files and links → "Use [[Wikilinks]]" and set "New link format" to "Relative path to file". You can write `[[wikilinks]]` in your own notes if you prefer; they just won't resolve in other editors, so keep them out of files your agents share with other tools.

One place reads the double-bracket form on purpose: `System/Scripts/paios-log/log-receipt-check.sh` accepts a later log note that names an earlier one as `[[<note name>]]`. That is a plain-text marker and works without Obsidian.

## Optional extras

These need community plugins. Install one only if you want it; agents must ask before installing any plugin.

**Dataview: a projects table.** With the Dataview plugin, paste this into a note of your own (for example next to `PAIOS/`, not into the default files). Change `"PAIOS/Projects"` to `"Projects"` if you opened the `PAIOS` folder itself as the vault.

````markdown
```dataview
TABLE objective, status, priority, target_date, next_review
FROM "PAIOS/Projects"
WHERE type = "project"
SORT choice(status = "active", 0, 1) ASC, priority ASC, file.name ASC
```
````

**Templates.** `System/Templates/` holds plain Markdown templates. Obsidian's built-in Templates plugin can use that folder as its template folder; no community plugin is needed.

## Sync and privacy

Any sync works (Obsidian Sync, a cloud drive, git, or none). Obsidian keeps its own settings in a `.obsidian` folder inside the vault; PAIOS neither needs nor reads it. Keep your filled-in copy private.
