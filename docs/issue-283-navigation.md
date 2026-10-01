# Issue 283: native destinations and truthful setup checks

This production slice adds native destinations around the existing conversation and Settings
views. It follows [issue 283](https://github.com/izyuumi/yorozu/issues/283), alongside the
[composer](issue-283-composer.md) and [explicit reply](issue-283-replies.md) slices. Conversation
ownership and execution remain the existing architecture. This is not the continuous-chat task
store or PAIOS memory implementation proposed in design v0.0.

## Navigation and preserved work

iPhone and iPad use the platform's native Chat, Schedules and Settings tabs. Chat keeps its
existing thread list, split view, search, archive, message actions, approvals, text editor and
attachments. Settings uses its existing navigation stack inside its destination. Chat replaces
the Settings sheet's Done action; Back remains available within Settings. Opening an archived
conversation returns to Chat. Thread links, notification destinations and incoming shares select
Chat without discarding an existing conversation's composer.

On iPad, Schedules and Settings use native inline navigation titles so accessibility-sized
titles do not collide with the platform's top destination controls. iPhone retains automatic
title presentation. The tabs, fonts and content sizing remain the platform's own.

The Mac uses native Chat and Schedules tabs and keeps Settings in its native window, reachable
from the toolbar, existing sidebar action and app menu. Quick Chat remains a separate window.
The host and multi-host client keep their current thread selections and per-host models.

Changing destinations does not create, send, withdraw or delete a message. Existing per-thread
encrypted text, files and quoted reply targets remain owned by `ChatModel`. Navigation paths are
held outside the tab contents. Hidden chats are not reported as actively read. Returning to Chat
resumes its selected conversation; native lists and Settings retain their navigation and scroll
state. Leaving chat still cancels an unfinished clipboard import under the existing generation
guard, preserving input and any files already imported.

The iPhone software keyboard hides the native tab bar. The native editor now supplies a standard
keyboard toolbar with **Hide keyboard**, which resigns the editor without editing its input.
This provides a touch and accessibility action for returning to navigation. Native interactive
keyboard dismissal and hardware-keyboard shortcuts remain available.

Initial pairing keeps its existing onboarding flow. After pairing, the destinations remain usable
while the Mac is offline. Removing a connection still follows its existing explicit confirmation;
this slice does not bypass it or change its deletion semantics.

## Schedules are explicitly unavailable

The Schedules destination has no fake jobs, empty-success state, creation control or automatic
gateway connection. It says that this version cannot display or manage schedules, that existing
schedules are unchanged, and that chatting remains available independently. Connecting chat does
not enable schedule access. Its Connection section reports the current chat transport and required
compatibility, with a non-mutating action to open Settings.

The actual schedule API, authorization boundary and handshake side effects remain recorded in the
[schedule checkpoint](issue-283-schedule-contract.md). Approval for that investigation is still
pending. No gateway connection, identity, token, pairing, grant, scope or configuration is created
or changed by this navigation slice. A future read-only schedule adapter must still negotiate a
real capability and reconcile durable results before the screen can show schedules.

## What setup checks mean

Chat connection feedback describes the current transport; it does not claim that an assistant
can answer. An incompatible host explicitly needs a Yorozu update. Offline copy explains that
saved chats and drafts remain available and sends wait for reconnection. Existing chat capability
notices and admission errors retain their supported actions.

The Mac's assistant setup appears in General Settings as well as onboarding. It lists all three
existing agent choices with their purposes and existing setup links. CLI authentication success
is **Signed in**, and an optional successful gateway reachability check is **Reachable**. Neither
is **Ready** or proof of a provider response. An omitted assistant result is **Not checked** with
an explicit explanation, rather than a hidden row or an inferred installation failure. No new
gateway probe is added; the runtime still omits the optional gateway check.

Checks coalesce while one is in flight and time out after ten seconds. The host echoes the request
event ID. Only its currently active response can update the model; late replies, results from an
earlier check and replies after disconnect are ignored. A disconnect, transport failure, close or
shutdown invalidates checked state. Re-check remains usable after timeout or failure. An older host
that cannot identify its response gets a clear update instruction, rather than an uncorrelated
readiness claim. A host check failure returns a fixed failure flag, not raw subprocess errors.

Connection keys, relay and compatibility details, sign-in commands and check diagnostics use
disclosure controls. Existing copy, retry, repair, permissions and removal actions remain available.
No system permission, approval policy or security confirmation is changed.

## Verification

The following checks use synthetic conversations and isolated test stores; native UI runs use a
disposable simulator and the repository's real relay/host fault proxy. A generated echo response
is test evidence, not live provider execution or scheduler readiness.

- The shared Swift suite passed 454 tests, including stale/check deduplication, timeout,
  retry, legacy-host, failed-result and disconnect checks preserving draft text and files.
  The separate watch suite passed two tests. The Mac suite passed 16 tests.
- The isolated runtime run passed 222 tests across `serve.test.ts` and `agent-status.test.ts`.
  Three runtime cases first failed under concurrent build/test load; all their parameterized
  cases passed in an isolated rerun, followed by the full successful runtime run. No unrelated
  assertions or timeouts were relaxed.
- The non-web TypeScript packages built successfully. iOS and its watch target built for the
  simulator. English/Japanese catalogs and compiler-extracted localization keys passed checks.
  The repository defines no additional lint script for these packages.
- Eight distinct iPhone native workflows passed across the focused runs: navigation with
  draft/file/reply preservation at normal and largest accessibility sizes; archive-to-chat;
  diagnostics access; explicit reply cancellation at both sizes; keyboard chooser retention;
  and relay interruption/reconnection with exactly one eventual message dispatch. The two
  initial failures were fixed by using the native keyboard dismissal action, respecting retained
  native list scroll position and counting actual harness dispatches rather than nested
  accessibility wrappers.
- Six distinct iPad workflows passed: navigation at both text sizes, reply cancellation at
  both sizes, keyboard chooser retention, and relay interruption/reconnection. Initial failures
  used an iPhone-only TabBar query or observed cancellation before the native UI settled.
  Queries now use the actual native iPad top controls and await cancellation. The two navigation
  cases were rerun after the inline-title adjustment and also assert that titles do not overlap
  destination controls when rendered separately, and that the heading fits below those controls.
  A first version of that added assertion incorrectly required a second title even when native
  inline presentation uses the selected tab as the title. No iPhone-style tabs or text-size caps
  were forced on iPad.

Native runs used Xcode 27.0 and iOS 27.0 (24A434), on disposable iPhone 17 Pro and
iPad Pro 11-inch (4th generation, 8 GB) simulators. Successful result bundles and four
normal/accessibility navigation screenshots are retained locally. Screenshots and logs are in the
isolated task evidence directory; result bundles are in this task's disposable `/tmp` run directories.

Interactive Mac behavior, VoiceOver spoken navigation, physical devices, IME/hardware-keyboard
behavior and the release-specific iOS 26.5 gate remain unverified. No push, PR, merge, beta upload
or release is included in this slice.
