# Native SIWC account command coordinator

`packages/runtime/src/native-account-coordinator.ts` owns the native account
command lifecycle. `packages/runtime/src/native-account-callback.ts` supplies the
numeric-loopback HTTP endpoint factory. Both constructors are inert. Neither
status publication nor importing either module initializes protected storage,
opens a browser, acquires a callback port, or acquires an account token.

The implementation requires the exact in-flight cancellation fence in
`siwc-account-lifecycle.ts` from commit
`e7167736db48888fd23587f1818444923f3be9d8`. A late exchange result cannot adopt an
account after cancellation, even if the transport ignores its abort signal. An
already-dispatched durable mutation can still have an unknown outcome; the
coordinator does not promise rollback.

## Host composition API

```ts
const coordinator = createNativeSiwcAccountCoordinator({
  validateSender(sender, command) { /* actual native transport authority */ },
  initializeAccountServices: async (signal) => ({
    host: { hostId: protectedInstallationIdentity, appName: "Yorozu" },
    services: nativeAccountServices,
  }),
  nativeBrowser: { openAuthorization: trustedNativeBrowser },
  callbackEndpoint: createNumericSiwcCallbackEndpointFactory(),
  onChange() { /* publish getStatus/getResult; update the host command journal */ },
});
```

`initializeAccountServices(signal)` must obtain the stable installation identity
from the protected native snapshot and return its existing identity on restart.
It may return `undefined` when unavailable. The client cannot supply a host ID,
app name, callback address, URL, credential, lifecycle, or storage service.
The optional `makeLifecycle` injection is a trusted test seam.

The returned frozen coordinator exposes:

- `execute(sender, input): Promise<NativeSiwcAccountResult>` for validated native
  commands. Initialization is lazy and memoized. A sign-in command initializes
  services only after sender validation and operation admission.
- `activateSavedAccounts(signal?): Promise<NativeSiwcLifecycle | undefined>` for
  explicit host-owned preparation using an already selected saved binding. This
  calls the same initializer without browser, OAuth registration, or callback
  acquisition. The composer must invoke it only after validating the user run's
  original host-minted person, account binding, and execution scope, or an
  explicit native account action. It is not a model/chat command.
- `getLifecycle()` for the host inference-broker selector. It returns the same
  owned lifecycle, including `canExecute` and `getAccessToken`, only while the
  coordinator is open and has no initialization or held-account uncertainty.
  This reference must never enter a renderer response or harness configuration.
- `getStatus()` for safe host publication, without allocating a command ID or
  triggering initialization. `getResult(operationId)` returns a copy of the
  current safe receipt without performing an action.
- `close()` to abort owned operations, fence/cancel exact live sign-in attempts,
  close the lifecycle, and release owned callback endpoints.

The service initializer must not adopt another lifecycle or another account
profile. Construction takes no host identity. Saved-account activation does not
grant execution authority; the broker must still verify the exact binding and
the lifecycle's cached readiness for every execution admission.

## Native command and event mapping

The internal command contains `operationId` plus one of:

| Method | Other exact fields |
| --- | --- |
| `sign-in` | `bindingId`, `returning: boolean` |
| `cancel` | `attemptId` |
| `verify-pending`, `select`, `sign-out` | `bindingId` |
| `status` | none |

The host maps the shared account-control event's `event.id` to `operationId` and
removes the outer `version: 1`. For a new sign-in with no binding supplied, the
host mints the binding before dispatch. Returning sign-in requires an explicit
existing binding. Unknown/additional fields are refused before initialization.

`validateSender` receives both the actual transport context and parsed command.
The production composer must require the authenticated local native app for
initial sign-in. Trusted paired native UI may use status/select/sign-out only
under the host's explicit policy. A model, chat event, tool result, or claimed
sender string cannot invoke these commands. `activateSavedAccounts` is a
host-only preparation method and is not exposed through this dispatch.

Safe receipts contain `protocolVersion: 1`, `operationId`,
`status: pending | completed | rejected | unknown`, optional opaque `attemptId`,
and generic enumerated reasons. Status includes public account binding IDs,
phase, plan-use consent, active selection, revision, and revocation certainty.
It copies no tokens, callback/authorization URLs, native snapshot, raw errors,
or account identity claims. The host maps this receipt into the shared
`lastControlResult` envelope and maps safe account status into
`SiwcAccountStatusData` with `version: 1`. The shared terminal receipt must omit
`attemptId`; retain it only for the active pending sign-in. Publishing an
unrelated status-command receipt must not replace that pending sign-in's
original operation ID and Cancel target. The internal status receipt's
`operations` list and `getResult` provide that original operation currency.

`onChange()` has no arguments and receives no sensitive values. The composer
uses `getResult` and `getStatus` to persist/publish safe updates after callback
completion or cancellation. Its callback should catch its own asynchronous
publication failures. Status before activation reports `available: false` and
`nativeIntegration: wired-unverified`. Local Continue with ChatGPT availability
comes from the negotiated native capability and integration status; it must not
be disabled solely because dormant storage has not been initialized.

## Callback and cancellation bounds

Sign-in acquires an endpoint before `beginSignIn` builds the callback URI. The
factory binds only numeric `127.0.0.1`, ephemeral port `0`, exclusive ownership,
and validates the acquired port as 1024–65535. The URL goes directly to the
injected native browser service. Browser rejection/uncertainty closes and
cancels the exact attempt without retry.

Only exact `GET /auth/callback` with an optional query is admitted, from remote
address `127.0.0.1` and one matching numeric Host header. URL size is at most
16 KiB; headers are at most 8 KiB and 32 pairs. Bodies, transfer encoding,
nonzero/duplicate content lengths, encoded paths, fragments, widened hosts,
and duplicate Host headers are refused. The lifecycle independently validates
the state, PKCE, requested scopes, client identity, and callback query. No
request body is read, and no request or raw exception is logged.

An attempt has a maximum five-minute callback window and exactly one completion
handoff. A duplicate during completion receives a generic refusal. Explicit
cancellation and expiry close the endpoint and fence the exact attempt.
Cancellation after code-exchange handoff reports `unknown`, blocks account
execution, and suppresses visibility of any late success. Explicit verification
or confirmed sign-out is required to clear a held binding; a new operation ID
alone cannot escape it. Native initialization, command admission, and callback
completion have bounded waits. Callback HTTP connections have five-second
header/request bounds, at most eight connections, and bounded teardown.

HTTP responses contain fixed text only, with no-store, no-referrer, restrictive
CSP, and close-connection headers. They contain neither credentials nor the
callback URL.

## Replay and readiness limits

The coordinator reserves an operation before asynchronous work and caches up to
256 admitted operation receipts without eviction. A matching duplicate returns
the current safe receipt without redispatch; changed parameters conflict.
Unknown outcomes remain unknown. This is an in-memory fence only.

The production host must persist admission before dispatch in its own atomic,
bounded journal containing only command digest, operation ID, and safe public
receipt. After restart, an admitted operation returns a saved receipt or unknown
and is not redispatched. URLs, callback queries, attempts' private PKCE data,
and tokens must not enter that journal. A new explicit confirmation and new
operation ID are necessary for any new operation.

Tests use injected inert services and a mocked `node:http` server. One test
exercises the concrete account lifecycle with a fake delayed exchange to prove
the cancellation fence. No real listener, browser, OAuth exchange, native
helper, protected storage, credential, provider inference, or account grant was
used for this validation. The production endpoint implementation is present
but was not started. Native composition and actual eligible-account onboarding
remain unverified; every published status retains `productionReady: false`.
