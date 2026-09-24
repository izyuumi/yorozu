# Release assets and notes audit — 2026-09-24

New releases publish one installer, `yorozu.dmg`. Its candidate tag gives the URL a permanent
version/build identity. `appcast.xml` remains necessary for Sparkle's update discovery and
archive signature; `candidate.json` records the source, hashes, notes, and Apple build selected
for promotion. See the [Sparkle publishing guide](https://sparkle-project.org/documentation/publishing/).

The Mac's `Updater.swift` embeds the `main-beta/appcast.xml` URL. The live beta appcast also
references `main-beta/Yorozu-0.4.0-302.dmg` directly. Deleting that release or its legacy DMG
would break installed clients. The stable `0.4.0 (293)` appcast references the legacy website
download URL; preserve its redirect and DMG too. New publications do not add numbered DMGs.

Model discovery already uses OpenClaw `models.list`, Claude SDK `supportedModels()`, and
Codex `model/list`. The release's `models.json` is unrelated to those model pickers; only the
dormant direct-provider catalog uses it. That catalog now reads raw repository content, with
existing offline fallbacks. New releases omit the catalog snapshot.

Release Please's default notes hid documentation/maintenance and repeated some GitHub merge
titles. Reading `CHANGELOG.md` also missed changes made after version preparation. GitHub's
[automatic notes](https://docs.github.com/en/repositories/releasing-projects-on-github/automatically-generated-release-notes)
list merged PRs, so they alone cannot guarantee every direct commit appears. Final notes now
come from the exact Git range, with every type supported by the
[Conventional Commits specification](https://www.conventionalcommits.org/en/v1.0.0/), including
custom types and breaking-change markers. Standard sections are also enabled in
[Release Please configuration](https://github.com/googleapis/release-please/blob/main/schemas/config.json).

The published `v0.4.0` body was corrected and read back to verify six actual commits: two
features, two fixes, one documentation change, and one release-preparation commit. This restores
`c89cce1` and `b9d686e` and removes three synthetic merge duplicates. The local changelog agrees.
The comparison uses full SHAs, so removing the old tag cannot break the history link.

The obsolete `v0.3.0` tag pointed to `f78492cfc1494b1676cfd8a3f6b200a9293f39a2`, an ancestor
of `v0.4.0`; it had no GitHub Release. Initial deletion was blocked by the repository's active
[`release tags: signed, immutable` ruleset](https://github.com/izyuumi/yorozu/rules/23879938).
After explicit authorization, only `refs/tags/v0.3.0` was temporarily excluded, the tag deleted,
and the exact original active protection restored and verified field-for-field.

The owner then confirmed this is a single-user development project and waived legacy beta
compatibility. The old `main-beta` release/tag is removed. New beta discovery lives at the
website's `/beta` and `/beta/appcast.xml` endpoints, which select retained main candidates.
Candidate publication now performs the version/build/source progression guard previously
owned by the rolling pointer. This supersedes the earlier retention decision above.

Stable `v0.4.0` also uses one lowercase installer. Its appcast now names that permanent asset;
the old website download path redirects to the identical signed bytes, preserving cached feeds.
The duplicate numbered DMG and release catalog snapshot are removed after verifying this route.
