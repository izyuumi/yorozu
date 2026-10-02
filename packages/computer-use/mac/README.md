# Mac helper integration (staged, not installed)

This independent slice adds a real HTTP provider adapter, a single-request helper,
and a Foundation `Process` client. It does not modify Yorozu.app or connect its
scheduler. No native execution or paid provider request has been verified.

## Launch and identity

Proposed stable identity: `com.yorozu.computer-use-helper`, executable
`YorozuComputerUseHelper.app/Contents/MacOS/yorozu-computer-use-helper`, macOS 14+.
Keep the identifier, approved signing team/designated requirement and final install
path stable across updates. A bundle identifier alone does not establish TCC identity.
The actual responsible process may include the launching app; verify it on the target
Mac before relying on Screen Recording or Accessibility permission.

`package.sh` stages only an already-built release binary under this package's ignored
`target/mac-stage`. It requires an explicitly supplied Developer ID Application signing
identity, signs with hardened runtime and verifies the signature. No identity discovery,
ad-hoc signing, installation, registration, notarization or permission changes occur.
The script has not been run against a signing identity. The plist and script are build
inputs, not evidence of a signed/installed helper. Distribution also needs the normal
reviewed license-notice and notarization steps. Preserve upstream dependency notices.

Build separately with `cargo +1.92.0 build --locked --release --manifest-path
packages/computer-use/Cargo.toml --bin yorozu-computer-use-helper`. After approving a
signing identity, invoke `sh packages/computer-use/mac/package.sh`. Do not overwrite
an installed app or run the native mode as part of build/CI.

## App-to-worker protocol v1

`HelperClient.swift` launches the exact bundled executable via Foundation `Process`,
with private inherited `Pipe` endpoints, no shell and an empty environment. Run it
off the UI thread (the client does so). It is single-use; keep the one desktop-owner
lease in the trusted app until the child has exited and any unknown effect is reconciled.
Before production use the app must verify its embedded helper signature and enforce
one owner across app instances. These host admission requirements are not implemented
by this standalone client. It is not an authenticated general-purpose service.

Each direction carries one frame: 4-byte unsigned big-endian byte count, then UTF-8
JSON, capped at 65,536 bytes. No polling endpoint, socket listener, logs containing
payloads, or shared temporary request file. Request fields:

- `version: 1`, `goal`: the existing WorkerGoal with task/parent/origin/attempt IDs.
- `process_id`, `window_id`, `display_id`: trusted app-selected native target.
- `allowed`, `action_budget`, `duration_ms`: trusted grant, existing limits enforced.
- `model`: explicit image/custom-function capable model; no implicit model choice.
- `api_key`: explicitly supplied API key on the private pipe. No keychain, environment,
  browser session, Codex credential file or ChatGPT subscription credential lookup.

Do not allow model output to construct a launch request or select its grant. The
human-readable goal authorization is not the app's authorization decision.
The binary requires `--check-stdio` (always inert, returns `stuck`) or an explicitly
approved `--native-stdio`. The Swift client defaults to inert. Unknown/malformed
requests return `{version:1,error:...}` with no echoed input. Valid requests return
`{version:1,outcome:WorkerOutcome}`. The Swift client validates version, status and matching IDs
before accepting the outcome. Missing/partial frames or abnormal process exit are
unknown outcomes, not permission to replay. The client terminates after 130 seconds;
termination does not prove that a previously dispatched input was not accepted.

This is deliberately one bounded run, not a durable scheduler. Queue/steer/stop routing,
cooperative cancellation over IPC, restart reconciliation, cross-process exclusivity,
and retained screenshot retrieval remain host integration work. The helper currently
drops its private screenshot history on exit; evidence IDs cannot be retrieved afterward.
Do not enable production native runs until host evidence retention and admission exist.

## Provider transport

`ResponsesModel` uses reqwest/rustls to POST the documented Responses API. The helper
uses only `https://api.openai.com/v1/responses`; the Rust adapter additionally allows
explicit HTTPS endpoints and numeric loopback HTTP fixture servers. Redirects, proxy
environment discovery and automatic retries are disabled. Key/model are passed explicitly;
HTTP errors never include response bodies or credentials in returned errors.

Each request contains a bounded stateless snapshot: user goal and untrusted receipts
as text, separate PNG data URLs with observation IDs, and the single generated custom
function. No hosted computer tool and no orphaned function-result messages are sent.
`store:false`, one tool call maximum, 30-second request timeout, 128 KiB response cap.
The adapter accepts one custom call or one JSON final `{completed,summary}`; unknown
outputs, refusals, incomplete responses and parallel/mixed actions stop the loop. The
worker still enforces fresh post-input observation before a `done` claim. Done remains
model-reported, not verified app acceptance. This API-key route is not a ChatGPT login
integration, and live model compatibility remains unverified.

## Verification and next real Mac test

Automated checks use only inert desktop code, synthetic local HTTP and `--check-stdio`.
They do not inspect the screen or permissions. Before a real test, approve and stage the
signed helper, verify actual responsible-process identity and existing permissions,
implement host admission/evidence retention, then coordinate the disposable TextEdit
fixture on an idle desktop. An API-driven test separately requires an explicit provider
key, model and paid-call approval. The existing fixed-text native example can establish
capture/Unicode evidence without a provider call, but its executable identity differs
from this helper and cannot establish this helper's permissions.

References: [Apple Process and pipe lifecycle](https://developer.apple.com/forums/thread/690310),
[CFBundleIdentifier](https://developer.apple.com/documentation/bundleresources/information-property-list/cfbundleidentifier),
[OpenAI custom functions](https://developers.openai.com/api/docs/guides/function-calling),
[Responses API](https://developers.openai.com/api/reference/resources/responses/methods/create).
