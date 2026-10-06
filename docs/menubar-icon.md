# Native branded menu-bar template

The 18-point template transcribes the saved `AppIcon.icon` front/back loop `M/L/C/Z`
coordinates and ±45° transforms exactly. No invented replacement mark or app-icon
raster is used. The paper center ring becomes negative space, the vermilion center
becomes template ink. Offline retains both loops, hollows the center and reduces
coverage to 55% so the state remains distinguishable at 1x. macOS owns template tint
(including selected menu appearance); no hard-coded UI foreground color is shipped.
The existing host/client connectivity predicate, accessibility label, attention overlay
and task modifier are unchanged.

`YorozuMenuBarIcon.swift` contains native drawing code, not a resource lookup. SwiftPM
includes it automatically; the internal stage overlays the entire `apps/mac` subtree,
and the signed package copies the resulting executable. No new resource-copy or
Bundle.module assumption is required. The generator is a developer provenance tool,
not a build-time dependency. Canonical artwork remains untouched.

## Bounded proof

```sh
python3 scripts/generate-menubar-icon.py --check
mkdir -p .build/menubar-proof
xcrun swiftc -swift-version 6 -warnings-as-errors \
  apps/mac/Sources/YorozuMac/YorozuMenuBarIcon.swift \
  scripts/check-menubar-icon.swift -o .build/menubar-proof/check
.build/menubar-proof/check
xcrun swiftc -frontend -parse apps/mac/Sources/YorozuMac/YorozuMacApp.swift
```

The executable exercises the real NSImage drawing handler, asserts 18pt/template,
1x/2x nonempty alpha and unclipped margins, distinct center states, and opaque correct
light/dark preview backgrounds. It exports twelve PNGs (four transparent masks plus
eight composed previews). Composed black/white backgrounds are inspectable contrast
fixtures, not screenshots of macOS's live menu bar. At 1x the hollow center alone is
subpixel; dimming supplies the additional state cue. Retina retains the small hollow
center. Installed appearance/attention badge acceptance remains parent-owned.

## Mac-only signed deployment plan — do not run as a release workflow

Do **not** modify `/Applications/Yorozu.app`, inject an executable into the published
bundle, or ad-hoc resign it and call it notarized. Changed executable bytes require a
fresh complete Developer ID signature and Apple notarization. No workflow dispatch,
push, tag, appcast, GitHub release, iOS archive or TestFlight upload is needed.

For this 0.6 internal/secretary source, the smallest established production-equivalent
Mac-only route is **`scripts/build-internal-alpha.sh`**, which stages exact committed
source and calls `scripts/build-mac.sh`. Calling `build-mac.sh` directly on raw source
would bypass the established baseline/production patch assembly. The internal wrapper
also checks runtime intake/provenance and produces no Sparkle feed entry.

Parent prerequisites: integrate the signed change into a clean isolated source tree;
verify signature and exact HEAD; rerun bounded checks; confirm the already-existing
Developer ID identity and `yorozu-notary` keychain profile are available without exporting
credentials. Preserve existing unprovisioned helper behavior; do not silently introduce
new provisioning. Approve local build identity explicitly. A local-only rebuild can
retain `VERSION=0.6.0 BUILD=10267` with `VERSION_LABEL=0.6.0-local-menubar`, **but it is
not the published 10267 artifact**: retain exact source SHA and fresh provenance/DMG
hash, and never publish/upload it under that candidate identity. If a new distribution
is desired instead, use the separate allocation/approval process; do not invent 10268.

After approval, in the clean integrated checkout (fresh task-owned paths):

```sh
SOURCE_SHA=$(git rev-parse HEAD)
git verify-commit "$SOURCE_SHA"
test -z "$(git status --porcelain)"
PROOF="$PWD/.build/local-menubar-$SOURCE_SHA"
mkdir -p "$PROOF"
python3 scripts/intake-hermes-runtime.py \
  --pin scripts/hermes-runtime-release-input.json --source-root "$PWD" \
  --download-directory "$PROOF/runtime-download" --destination "$PROOF/runtime-intake"
VERSION=0.6.0 BUILD=10267 VERSION_LABEL=0.6.0-local-menubar \
  REQUIRE_NOTARIZATION=1 NOTARY_PROFILE=yorozu-notary \
  IDENTITY='Developer ID Application: Yumi Izumi (AN5KM8QGEF)' \
  YOROZU_HERMES_RUNTIME_ARTIFACT="$PROOF/runtime-intake/hermes" \
  DIST="$PROOF/mac" sh scripts/build-internal-alpha.sh
codesign --verify --deep --strict "$PROOF/mac/Yorozu.app"
xcrun stapler validate "$PROOF/mac/Yorozu.dmg"
spctl --assess --type open --context context:primary-signature -v "$PROOF/mac/Yorozu.dmg"
```

Notary submission is an external Apple action: the parent owns that authorization and
execution. The script staples the **DMG**, not the loose app. Mount that verified DMG
read-only, verify its app with `codesign --verify --deep --strict` and
`spctl --assess --type execute -v`, compare its source/provenance and TeamIdentifier,
then use the parent's authorized controlled quit/rollback/install procedure. Preserve
an intact old bundle outside `/Applications` for rollback; never copy live app data or
credentials. After installation verify exact executable/source identity, signature,
Gatekeeper, launch and connected/offline/attention appearances. Do not launch a second
same-ID app beside the running production app for testing. No installation or notary
operation was performed by this implementation task.
