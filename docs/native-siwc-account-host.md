# Native account composition

This is implemented source with `productionReady: false` and `nativeIntegration:
"wired-unverified"`. Fake integration checks do not establish actual Keychain
availability, publisher signing, operating-system exclusion, subscription eligibility,
or successful provider inference.

`native-account-host.ts` composes the fixed Resources/YorozuAccounts.app helper bridge,
account HTTPS and RS256 verifier, native callback/browser coordinator, durable
command journal, person-scope broker, and fixed HTTPS Responses transport.
The shipping `secretary-serve.ts` entry selects this composition only through the
existing internal build marker; development entries keep their existing route.
Construction/status publication never reads credentials or runs the helper.
The journal contains bounded operation digests and safe receipts, with its own
retained writer and durable admission before mutation. A damaged/unavailable
journal disables account execution while preserving the ordinary host/platform.

The production transport patch routes `siwc_account_control` before logging.
It derives local/paired authority from existing authenticated transport state;
sign-in requires the local Mac channel. Model calls do not supply that provenance.
The containing event ID is the operation ID. No account action enters a chat,
transcript, outbox, or automatic replay. Common Mac/iOS account settings display
only opaque bindings, availability, consent flags, and exact safe receipts. Pending
mutation receipts survive read-only status polls; terminal receipts remove attempt
IDs. Polls use the coordinator's status seam without consuming its mutation cache.
A dirty status read performs a trailing refresh after concurrent account adoption.

First sign-in obtains a stable host identity from protected initialization, holds a
numeric loopback callback before browser dispatch, and adopts credentials only
through the lifecycle's durable exchange and verified identity path. Registration,
consent, and browser execution require later authorized physical verification.
Explicit preparation of a person with an already selected account/model may load
saved protected state after restart; it opens no browser or registration flow.
Empty account/model selection remains unavailable. The host does not infer models
or assign its active account to another person.

`siwc-person-broker.ts` binds the original host-minted scope, immutable person,
execution ID, exact account/model and pinned Hermes function subset. Restricted
handoffs exclude built-in memory. Every provider dispatch obtains credentials
under the native account lock and rechecks identity; provider tokens never enter
the harness profile. Only an execution-specific local bearer does. Sign-out,
replacement, invalid refresh, account selection and shutdown retire exact matching
brokers and actors. Active/unconfirmed work retains a chain hold. An idle retired
actor remains a tombstone; an explicit idle person-settings revision selects a new
execution, preserving conversation history. Ordinary chat opens never respawn it.
Actor retirement and failed preparation release the corresponding broker once.

Routine refresh temporarily holds new credential admission, without retiring
already-admitted streams. The lifecycle's `isAccountCurrent` grants continuation
only for a locally observed rotation; it is not restored from a persisted unknown
refresh. Unknown/invalid outcomes and shutdown remove continuation immediately.
Fresh requests still wait for complete validated rotation and exact scope checks.

Every minted scope denies the account helper, Library/Keychains, the fixed
Application Support/Yorozu/ProtectedAccounts root, and the account journal. The
curated process's existing default-deny Seatbelt policy supplies its operating
system boundary. Real crash exclusion, native locks, helper/client identity,
the helper's restricted Keychain entitlements and authorizing provisioning profile,
Keychain availability, and signed bundle operation remain physical
release gates. This task only compiles native adapter code and tests injected
backends, browser, inspectors, listeners and transports.

Rollback retains the prior installed application and history. Source changes do
not migrate legacy history, credentials, existing connections, owner branches,
stable releases, or TestFlight. No current token is exported for harness switching;
confirmed idle settings changes create a fresh owned execution. Unconfirmed work
cannot escape its hold through an account or harness switch.
