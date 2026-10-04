# Protected account helper packaging

The host-only executable is fixed at
`Yorozu.app/Contents/Resources/YorozuAccounts.app/Contents/MacOS/yorozu-accounts`.
The background-only helper app and executable both use identifier
`to.yumi.yorozu.accounts`. Its stdin/stdout RPC and compiled native backend are unchanged.
The main app, Node, ordinary native tools and workers receive no account access-group grant.

The installed public macOS SDK's `Security.framework/Headers/SecItem.h:201–217` says
Keychain access-group membership comes from signed entitlements and describes the default
group. Lines 1033–1037 describe `kSecUseDataProtectionKeychain` on macOS. The helper's
query now always selects the one fixed group `AN5KM8QGEF.to.yumi.yorozu.accounts`.
Apple [TN3125](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)
documents that `keychain-access-groups` requires a provisioning profile, and that a CLI
executable needs an app-like structure to embed it. An embedded Mach-O `__info_plist`
alone does not provide that structure. The article's official
[JSON representation](https://developer.apple.com/tutorials/data/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles.json)
was readable when its HTML body required JavaScript. Apple's
[daemon packaging guide](https://developer.apple.com/documentation/xcode/signing-a-daemon-with-a-restricted-entitlement)
also describes this structure. Apple
[DTS guidance](https://developer.apple.com/forums/thread/791882) says legacy unique App ID
prefixes have never been supported on Mac.

`scripts/package-accounts-helper.py` copies the same compiled Mach-O into the helper app,
writes `Contents/Info.plist`, and creates helper-owned
`Contents/Resources/AccountsHelper.entitlements` and `accounts-helper.json`. It neither
signs nor launches code. The helper subtree is excluded from `build-mac.sh`'s generic
Mach-O signing loop; its app bundle is signed once with its explicit entitlements before
the outer app is sealed. The separate account helper never uses the tool helper's privacy
or Node's JIT entitlements.

No profile is discovered from Xcode, installed profiles, accounts, environment directories
or Keychain. Future authorized builds must explicitly supply both
`YOROZU_ACCOUNTS_PROFILE` and `YOROZU_ACCOUNTS_APP_IDENTIFIER_PREFIX`. Their CLI equivalents
are `--profile` and `--app-identifier-prefix`. The prefix is mandatory, never inferred.
This Mac helper accepts only the shipping Team `AN5KM8QGEF` and its fixed App ID/group.
The decoded property-list view must match that intended helper App ID, Team and group;
have the matching prefix, macOS platform and a future expiration. An exact group or the
profile's `AN5KM8QGEF.*` allowlist can match the intended group; the claimed entitlement never contains
a wildcard or another app's group. Captured profile bytes are bounded to 4 MiB and copied
unchanged into `Contents/embedded.provisionprofile`. Only three restricted entitlements
are prepared: `com.apple.application-identifier`, `com.apple.developer.team-identifier`
and the one `keychain-access-groups` entry.

Future CMS decoding uses fixed `/usr/bin/security cms -D -i` with an isolated captured
input, bounded output and generic failure reporting. Source preparation and synthetic
tests do not execute it. TN3125 explains that modern systems use the profile's DER form
as their source of truth. The decoded plist is only a static input check for preparing
the intended entitlement subset; it proves no cryptographic or OS authorization.
It does not attest OS trust, the signing certificate, provisioning-device eligibility or
the eventual signature. OS/signature/profile acceptance must be verified independently.
No synthetic profile or test payload may be used for production signing.

With neither input, ordinary candidate assembly continues: no embedded profile, an empty
entitlements dictionary, `provisioning:"absent"` and `productionReady:false`. Account
authentication is unavailable because the backend requires its fixed restricted group.
With matching inputs the manifest says `provisioning:"static-input-checks"` but still
`productionReady:false`; both paths say `osProfileVerification:"unproven"`. Missing one
input, malformed identity/authorization, an expired profile or unsafe input refuses helper
assembly before it is published. Other candidate functionality is preserved when accounts
are unprovisioned.

Evidence for this leaf is synthetic packaging tests and compile-only native code. No real
profile, certificate, signature inspector, Keychain, POSIX account locks, helper process,
browser or provider was accessed. Actual provisioning, signing, protected snapshot
initialization, cross-process locks and subscription onboarding remain future separately
authorized acceptance work.
