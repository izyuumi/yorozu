# Yorozu Web

A separate HTTPS client for the owner's existing Yorozu/OpenClaw host. No account
or repeat sign-in. Pair using a link from a paired device or the OpenClaw CLI and
compare the host fingerprint. The web client uses the standard Yorozu relay and
the plugin's current legacy-compatible Noise v3 wire. It never connects to the
plugin's local-only listener or adds an origin exception to it.

Only the device identity and host pin are persisted, in IndexedDB on this origin
and browser profile. Both private keys are non-extractable Web Crypto keys. The
invite token and secret never enter browser storage. Opting out of remembering
keeps the pairing in the current tab's memory only. Transcripts are fetched from
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
or reuse production device keys. No change to macOS/iOS/Windows release channels,
relay permissions, or native pairing is needed.
