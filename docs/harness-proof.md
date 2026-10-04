# Real Hermes runtime acceptance fixture

`scripts/harness-proof.mjs` runs the **actual pinned Hermes native gateway** through Yorozu's
version 1 stdio adapter. An ephemeral HTTP server on `127.0.0.1` supplies deterministic
Responses API inference. Hermes performs its own planning loop, tool dispatch, delegation,
steering delivery and child-result continuation. The fixture never manufactures outer task
events or substitutes a host-owned secretary continuation.

This is a local execution and protocol acceptance test. Its synthetic inference is not proof
of live subscription access, model quality, a native UI or an OS permission boundary.

## Run

Use the integration candidate's Node binary and an already provisioned, pinned Hermes
environment. The fixture does not install or download anything.

```sh
node scripts/harness-proof.mjs \
  --adapter /absolute/candidate/packages/harness-plugins/hermes/adapter.mjs \
  --source /absolute/pinned/hermes-source \
  --python /absolute/pinned/hermes-source/.venv/bin/python \
  --output /absolute/new/task-local/proof-directory
```

The Hermes adapter checks release `0.21.5`, commit
`f97608f178d1ffeca59860195ab7da295f7c8e5f` and unchanged tracked upstream source.
The output directory must be new. It contains a fresh Hermes profile, isolated home,
workspace files and `evidence.json`. Successful artifacts remain available for inspection;
failure evidence remains too. The script uses no installed profile, real provider key,
external inference service or inherited credential environment. The loopback key is a fixed
dummy. Inference requests must stream and cannot request a priority/fast service tier.

A sandbox that prohibits listening on `127.0.0.1` must approve this exact local-only test run.
If that approval is denied, stop the test; do not substitute another transport.

## Checks and evidence

| Behavior | Runtime evidence |
| --- | --- |
| Harmless real execution | Hermes `write_file` and `read_file`; host independently checks `artifact.txt` bytes. |
| Context and selected language | Supplied prior-context and Japanese preference appear in native inference input/instructions; the Japanese reply survives outer projection. This checks supplied bootstrap data, not the installed history database. |
| Responsive secretary | Real `delegate_task` creates two independently identified children. A new foreground turn completes before either child artifact exists. |
| Targeted steering | Exact child currency receives `queued`; child A's next inference sees the correction and produces changed bytes. Child B sees no correction and produces original bytes. Foreign origin control is rejected. |
| Recursive ancestry | Child A delegates a real grandchild. Its task projection points to child A and retains the original run/attempt; its file bytes are independently checked. |
| Child-result continuation | A secretary continuation terminal arrives after actual child completion without the fixture submitting a continuation turn. |
| Approval refusal | Hermes requests approval for deleting a fixture file. The fixture answers `deny` and independently verifies that the file remains. |
| Unsupported operation | An unknown method returns JSON-RPC `-32601`. |
| Disabled capabilities | Actual inference schemas do not advertise scheduler or computer-use tools. |
| Stop | A terminal action first writes its start marker, receives a requested Stop, then an upstream stopped terminal. Its later file write remains absent beyond the original deadline. |
| Active-topic refusal | An unrelated fresh topic during the actual running command is rejected, never retried and remains absent from native inference and its later history. |
| Restart without action replay | A real terminal append occurs once. The fixture kills only its owned adapter process group during a later wait, starts a fresh adapter, resumes snapshot-only and verifies no new inference or duplicate append. |

The synthetic provider examines only its own fixture requests. It emits regular Responses
function calls using the tool names Hermes actually advertises. Real gateway notifications,
task identifiers, permission requests and terminal results are recorded in `evidence.json`.
Provider-side summaries record scenario, step, tier and receipt of relevant markers rather
than copying complete prompts. All prompts in this fixture are invented and local.

The fixture retains an input for up to five seconds when admission explicitly returns
`status: "busy", handoff: "not-submitted"`, then retries the identical run/attempt/text.
This handles native post-terminal cleanup without manufacturing readiness. Every receipt is
recorded. A queued, rejected, lost or uncertain handoff is never retried.

## Limits and remaining acceptance

- Standard-tier live subscription onboarding and inference remain a separate explicit gate.
- SwiftUI/iOS history, pairing, language selection UI and assembled production packaging
  require the integration owner's end-to-end candidate run. This script accepts an adapter
  path so the same fixture can run against the assembled candidate's included adapter.
- The adapter owns no host queue. Queue cancellation, durable admission and engine switch
  admission must be covered at the host boundary rather than claimed by this fixture.
- A process-group crash has no upstream terminal evidence. The host must retain an explicit
  uncertain outcome. Snapshot-only resume proves no replay; it does not prove cessation of
  an earlier external effect or reconstruct settled child authority.
- The provider emits only hardcoded harmless actions within its workspace. A fresh profile
  and approval prompt do not sandbox all Hermes tools. Actual native grants and unsupported
  capabilities must remain truthful in the product.
- The script exercises two specialists and a nested grandchild. Exact child Stop needs
  separate coverage if that capability is enabled in the integration candidate.

Do not mark the candidate release-ready based on this fixture alone.
