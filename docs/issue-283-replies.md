# Issue 283: explicit native replies and draft recovery

This local slice implements explicit reply composition for existing assistant-channel conversations.
It follows [issue 283](https://github.com/izyuumi/yorozu/issues/283) and the approved continuous-chat
UX direction while keeping the current thread and execution contracts. It does not implement the
new continuous-chat task store, PAIOS memory, or a schedule backend.

## User-visible behavior

Reply appears in a settled message's secondary actions when this host and its connected adapter
both advertise `reply-context-v1`. Selecting it displays the quoted message above the native text
field and takes keyboard focus. Selection does not replace existing text or staged files. Cancel
clears only the target. Selecting another message changes only the target; each conversation and
host keeps its own composer. Text, files and the target survive relaunch.

A user message is a valid target after host acceptance. An assistant message must be finished.
Internal delegated messages, unfinished answers, pending device-outbox submissions and messages
in another conversation are not offered as targets. Direct-agent threads keep their existing
controls; explicit quoted context for those runners needs a separate supported contract.

Sending commits the target's ID with the ordinary durable message, including attachment-only
messages and the chunked attachment path. The composer clears only after its encrypted outbox
owns the operation. Recovery after an interrupted prepare uses that exact message ID to decide
whether the input still belongs to the composer or has committed. Retrying or renewing an expired
message retains its reference.

A missing target or unsupported connection produces a visible refusal, not a plain message with
its target silently discarded. **Use in composer** recovers an explicitly rejected reply's text
and files without replacing a newer draft or automatically sending. Repeated recovery is
idempotent. An empty composer can recover the original target when the source message is still
available; otherwise the content remains editable without an unavailable reference. Cancel
remains available on a restored reply when connectivity or capability changes.

A new pending request cannot consume a draft that is still explicitly replying to a message.
Finish the pending request or cancel the reply before sending. The host also does not interpret
an explicit quoted reply as a typed approval answer.

The reply heading and preview use native layout and Dynamic Type; VoiceOver receives the full
preview and a named Cancel action explaining that text and attachments remain. Reply dismissal,
attachment removal, Attach, Send and Stop keep their existing hit areas. Their symbols fit the
geometry of these custom controls rather than growing outside their shapes at accessibility sizes.

## Protocol and execution

`MessageData.replyTo` means an explicit reference on a user message and the existing triggering
user-message correlation on an assistant message. Swift now preserves both. Only the ID goes
from the native composer to the host; a client never supplies trusted quoted text.

The host accepts a new reference only to an available, settled message in the same conversation.
It rejects missing, foreign, self, delegated and unfinished targets. The reference participates
in immutable admission identity, so reusing a message ID with a different target is a conflict.
Existing messages without references retain their prior identity algorithm and compatibility.
The new capability is optional; required security capabilities remain unchanged.

For the channel adapter, the host resolves a bounded quote from its own history. Text is limited
to 4,096 UTF-16 code units; a file-only parent contributes file names, not implicitly fetched file
contents. The composer preview is bounded by bytes before grapheme counting. The adapter uses
OpenClaw's official `supplemental.quote` contract (`id`, `body`, `sender`, `isQuote`). Raw body,
agent body and command body remain the current user's text. This is quoted context, not a command
prefix or a promise of unrestricted memory retrieval.

Delivery selects an adapter that supports both quoted context and any attached media. A definite
refusal before the first dispatch is recorded as a stable `admission_status` in host history,
replayed to native clients and returned to later admission queries. It remains recoverable after
relaunch, including after the initial acceptance receipt removed the device outbox copy.

The host persists a reply-attempt marker before sending a socket frame. If an acknowledgment is
lost and a restarted or downgraded adapter cannot accept that reply, the host preserves the
original queued ID and reports delivery as **unconfirmed**. It cannot assert that a possibly
started operation was rejected. Restoring support retries that same ID. The marker stays inside
the host outbox and is not passed to the SDK.

No new gateway identity, pairing, token, grant, scope or configuration is needed by this reply
slice. The separate schedule SDK check remains stopped under the boundary documented in the
[schedule checkpoint](issue-283-schedule-contract.md).

## Control review

| Element | Decision and reason |
| --- | --- |
| Reply | Keep in message actions; it is a specific context choice and does not need a permanent composer button. |
| Quoted target | Keep visibly in the composer and on sent user replies; the user must know which message their request refers to. A sent reference remains labelled when its source is not locally loaded. |
| Cancel reply | Keep beside the quote; it changes context only and must never discard input. |
| Copy and native selection | Keep their existing separate user/assistant behaviors; Reply does not replace them. |
| Retry, Use in composer, cancel send and Stop | Keep their distinct meanings. A refusal can be edited; an uncertain send cannot be safely duplicated as a fresh operation without settlement. |
| Model, effort, agent and workspace choices | Retain current capabilities pending supported replacements. Explicit reply support is limited by the real adapter contract, not by removing those workflows. |
| Legacy saved-draft recovery | Keep the first slice's safe recovery menu only for existing data; no stash creation returns. |
| Chat / Schedules / Settings navigation | Still a separate production slice. A native schedule screen needs a verified, authorized backend or an explicit unavailable state; prototype records are not production schedules. |
| Setup and answering readiness | Still requires independent connection, adapter and execution evidence. A successful reply test with synthetic transport does not establish provider readiness. |

## Verification

All runtime and native fixtures below use synthetic conversations and files. The channel tests
exercise the real local socket and encrypted relay. SDK dispatch tests inject the documented
adapter callbacks; neither those tests nor the screenshots prove live provider execution.

- Shared TypeScript protocol: 60 tests passed.
- The repository's TypeScript build passed for all non-web workspace packages.
- OpenClaw channel adapter: 31 tests passed, including supplemental quote separated from commands.
- Runtime admission and thread-history suites: 261 tests passed. Coverage includes duplicate IDs,
  retargeting rejection, foreign/unfinished/delegated references, bounded quotes, old adapters,
  durable refusal before dispatch, lost reply acknowledgments, media downgrade and host restart.
- Native macOS application package: 16 tests passed. Interactive Mac verification remains
  unverified; no security permission was changed to obtain it.
- Shared Swift suite: 454 tests passed, including reply persistence, capability changes,
  attachment commits, interrupted prepares, rejected-reply recovery and late pending requests.
- iPhone 17 Pro, iOS 27.0 (24A434), Xcode 27.0 (27A266a): two native UI tests passed. Normal and
  largest accessibility text sizes cover Reply, keyboard focus, repeated Cancel, draft/file
  preservation, file removal and Send fitting fully on screen. Retained screenshots are exported
  directly from the passed `.xcresult`, with no image edits.
- iPad Pro 11-inch (4th generation), iOS 27.0 (24A434): the same two native UI tests passed
  at normal and largest accessibility text sizes, with retained screenshots.
- iOS Simulator build passed. Both native catalogs passed English/Japanese and interpolation
  checks against compiler-extracted shared Swift strings.

English source and Japanese translations accompany the changed native UI. Device hardware, camera,
IME/hardware-keyboard behavior, VoiceOver spoken navigation and the release-specific iOS 26.5 gate
remain untested. The screenshots use the existing DEBUG native showcase with synthetic capability
and file fixtures; visible reminder prose does not prove a schedule was created or executed.

No push, pull request, merge, beta upload or release is included in this local slice.
