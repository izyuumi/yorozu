# Native protected account bridge

`packages/runtime/src/siwc-protected-store.ts` implements the host-side account
store and private JSON-lines RPC boundary for the separate `yorozu-accounts`
executable. It implements `SiwcProtectedAccountStore` with
`protection: "os-protected"`; the executable owns actual Keychain persistence and
native locks. The bridge does not implement Keychain persistence in JavaScript.

Construction, `available()` and `status()` perform no filesystem, signing,
subprocess or credential work. `available()` is cached evidence from this bridge,
initially false. The native host must call `activate()` only after an explicit
trusted account action. Activation verifies the packaged executable, probes its
availability and initializes or retrieves its native-owned snapshot. Account
status in a renderer must use the separate bounded lifecycle/coordinator
projection; neither RPC replies nor protected snapshots belong in renderer
events, transcript entries, logs or errors.

## Trusted configuration and API

```ts
const store = new SiwcNativeProtectedStore({
  signedResourcesPath: trustedAppResources,
  executable: trustedAppResources + "/yorozu-accounts",
  appIdentifier: "to.yumi.yorozu", // Optional trusted packaging identity.
  fenceAccounts: () => retireAccountExecutionOwners(),
});

store.available(); // Cached boolean; no probe or credential read.
store.status();    // { productionReady: false, available, state }.
await store.activate(explicitActionSignal);
await store.read();
await store.withAccountLock(bindingId, async () => {
  const current = await store.read();
  return store.replace(current.revision, validatedNextSnapshot);
});
await store.openBrowser(hostGeneratedAuthorizationUrl, explicitActionSignal);
store.close();
```

Paths come from fixed trusted app packaging configuration. There is no discovery
through environment variables, registry records, renderer input or alternate
helper locations. The only accepted location is
`<app>.app/Contents/Resources/yorozu-accounts`. There is no MacOS-directory
fallback. `activate()` rejects unsupported platforms.

The default inspector verifies canonical, nonsymlink app/Contents/Resources/helper
paths, expected file types and absence of group/world write permission. It runs
fixed `/usr/bin/codesign --verify --strict` checks with an explicit identifier and
Apple signing anchor requirement, then checks displayed TeamIdentifier,
identifier and designated signing requirement. Both outer app and helper must
belong to the shipping publisher `AN5KM8QGEF`; the helper identifier is fixed to
`to.yumi.yorozu.accounts`. The default outer app identifier is `to.yumi.yorozu`.
Ad-hoc and foreign signatures are unsupported. There is no hash-based fallback
that enables authentication for an ad-hoc package.

Inspector subprocesses have sanitized environment, a five-second timeout and a
32 KiB output limit. Overall activation is bounded to thirty seconds. Helper
launch uses the verified executable with no arguments, no shell, sanitized
environment, Resources as its working directory, private piped stdin/stdout and
ignored stderr. Authorization URLs, snapshots and tokens never enter argv or
environment. Tests inject an inert inspector and in-memory fake child; injection
is a trusted host/test seam, not a renderer-configurable option.

## RPC and lease ownership

Requests are version-one JSON lines with unpredictable request IDs. The exact
commands are `available`, `initialize`, `read`, `replace`, `lock`, `unlock` and
`open-browser`. Initialization sends only `{ appName: "Yorozu" }`; the native
helper provides the stable opaque host ID. Later snapshots must preserve that
identity and pass the shared pure lifecycle schema validator.

Snapshots are limited to 1 MiB; each RPC line is limited to 1 MiB plus 16 KiB.
The bridge bounds pending requests and locks to 32 and per-request deadlines to
at most thirty seconds. Native replies require strict UTF-8, duplicate-aware
JSON parsing, exact fields, request correlation and a closed error enum. Foreign
IDs, repeated receipts, malformed replies and arbitrary diagnostic fields cannot
be mistaken for successful outcomes.

`withAccountLock()` owns the exact native lease, keeps concurrent account
contexts separate with AsyncLocalStorage and releases that lease in `finally`.
`replace()` requires a live lease context and revision CAS; the native helper
also enforces its global CAS lock, immutable established registration and no
deletion of known account bindings. The bridge never fabricates a release
receipt when unlock is missing or unsuccessful. The operation callback is
trusted host code; its own errors are returned to that caller, while native
process, transport and parsing errors have only generic account error codes.

EOF, process loss, malformed frames, timeout or an aborted submitted request
permanently fences this instance, invalidates its leases, and calls the trusted
`fenceAccounts()` once. It rejects late CAS calls from unfinished callbacks.
There is no automatic helper restart, request replay or old refresh-token retry.
A valid initialization reply followed by immediate EOF, abort or a malformed
frame cannot resurrect availability. `close()` also fences execution when the
store was never activated. Killing a lost helper is best effort; the bridge
does not claim that physical exit or native lock release was confirmed.

`openBrowser()` accepts only the lifecycle's exact official authorization
endpoint, scopes, resource, native host identity, numeric IPv4 loopback callback
and bounded OAuth parameters. Dynamic registration and issued-client forms are
distinct. The native helper additionally checks returning-client identity and
the retained ID-token hint against its own protected snapshot.

## Validation and remaining limits

The bridge's 38 tests use fake child streams, fake inspectors and synthetic
snapshots. They cover signing/path refusal, inert status, activation sharing,
lease isolation, CAS, lost acknowledgements, malformed and fragmented replies,
timeouts, cancellation, secret-free status and the initialization race. The
lifecycle's 46 tests and the runtime TypeScript check also pass.

No real signing inspection, helper launch, Keychain read/write, native flock,
browser opening, callback socket, OAuth grant or credential access was performed
for this slice. Its status deliberately retains `productionReady: false`.
Successful fake protocol tests establish host-side behavior, not live Keychain,
publisher-signature, browser or account readiness. Native account initialization
and live checks remain explicit authorized native actions; the trusted host
must compose this store with the lifecycle, verified account transport,
ID-token verifier and exact execution-owner fencing.
