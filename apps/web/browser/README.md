# Yorozu Web

A separate HTTPS client for the owner's existing Yorozu/OpenClaw host. No account
or repeat sign-in. Use an up-to-date Chrome or Edge, or Safari on iOS 18.4 or newer (Web Crypto X25519 support). Pair using a browser-only invitation from the OpenClaw CLI and compare the host fingerprint. A link passed as `/#pair=<encoded invitation>` pre-fills the form. The app strips the fragment before pairing; it never goes to the site server. Continue and compare the host fingerprint before approving. The web client uses the standard Yorozu relay and
the plugin's explicitly negotiated browser protocol. It never connects to the
plugin's local-only listener or adds an origin exception to it.

Only the device identity and host pin are persisted, in IndexedDB on this origin
and browser profile. The persistent private signing key is a non-extractable Web Crypto key. The
invite token and secret never enter browser storage. Opting out of remembering
keeps the pairing in the current tab's memory only. Safari cannot reliably restore X25519 from IndexedDB, so none is stored. Save is checked by reading back the signing key. If it fails, the app explicitly stays paired only for the current tab. No exportable-key fallback is used. Transcripts are fetched from
the host, not written to IndexedDB. A second tab waits for the first to close so
only one Noise session uses the same device keys. Forgetting closes the socket
and clears local storage; removing the paired device at the host revokes remote
access.

## Checks

At the repository root:
```sh
pnpm install --frozen-lockfile --filter @yorozu/relay
pnpm --dir apps/web/browser install --frozen-lockfile
pnpm --dir apps/web/browser build
pnpm --dir apps/web/browser exec playwright-core install chromium
pnpm --dir apps/web/browser test
```
Set `YOROZU_CHROMIUM_PATH` to use an installed Chromium executable instead.
The test host uses the existing plugin's Hub and Node relay on loopback, with
only synthetic chat data. The dev server's test relay override isn't in the
production bundle.

## Release gates

Use the **Yorozu browser client** workflow's staging target before production.
It builds once, checks browser conformance and deploys to a separate staging
Worker. Smoke test the HTTPS origin with an isolated Yorozu profile and confirm
all of: fingerprint, text and history, browser restart, host restart during chat,
and host revocation. Check production-equivalent response headers and verify that
no injected script or third-party request appears in the page, including
Cloudflare analytics or optimization injection. Use only synthetic chat. Do not
reuse a live host's credentials or room.

Production must be dispatched from the reviewed main commit using the existing
Cloudflare deployment credentials. It's served by a static Worker on a separate
hostname (`app.yorozu.yumi.to`), not under the marketing site's origin. Don't
turn on Cloudflare Web Analytics or script injection on the client hostname.
Freezing a Web Crypto key against export does not prevent JavaScript running at
the app origin from using it; a trusted delivery origin is part of the web
client's threat model. The staging origin is separately paired and cannot read
or reuse production device keys. The updated browser supports existing v4 hosts. Displaying its QR for another device to scan also requires the updated, browser-enabled Gateway plugin and an already paired Apple client that supports browser invitations. Coordinate Gateway/plugin changes with the repository’s existing Mac beta workflow.

## Durable browser credentials (v4)

Production browser builds only accept explicit v4 browser invitations via
`openclaw yorozu pair-browser`. Legacy native links and key binding are unchanged.
With the feature disabled (the default), the Gateway will not issue or accept
v4 browser pairing. Browser invitations are relay only.

To pair by QR, scan the browser invitation shown by the Gateway command, or
choose **Show QR code** and, on an already paired iPhone or iPad that
supports browser invites, go to **Settings › Add a Device › Scan QR Code**. The reverse QR is a one-time encrypted
mailbox request, not a pairing invitation. Both methods ask you to compare the
host fingerprint before pairing. Pasting the invitation link still works.
Scanning asks for camera access only when selected, uses no microphone, and
can also read a local PNG, JPEG, or WebP image.

A browser stores a non-extractable Ed25519 signing key, the pinned host key,
and its connection metadata. Each reconnect makes fresh X25519 keys for the
domain-separated Noise IK handshake. The host checks the signed init and only
authorizes the device or replaces its live session after decrypting its first
peer frame. A valid init alone cannot spend an invitation, bind an allowlist
entry, or send chat. The owner can remove the browser via a native client's
Devices settings or the usual CLI.

The browser role may send plain text and request conversation list/history.
The host rejects messages with attachment references, quote metadata, or unknown
message fields, and does not expose direct-path hints, device administration, or
tool events through this role. The agent's configured approval policy is unchanged.

The staging build uses `pnpm --dir apps/web/browser build:staging`; it pins the
separate staging relay in both link validation and the response CSP. It is
served by the separate v4 staging Worker. Use synthetic test state only with
`YOROZU_BROWSER_EPHEMERAL=1` on the staging Gateway. Production remains
separately gated.
