# Slow phone link profile

Run on macOS after `pnpm install --frozen-lockfile` and `pnpm -r build`:

```sh
env -u SDKROOT swift test --package-path packages/shared-swift \
  --filter slowLinkProfileMeasuresAcceptanceCatchupAndLargeAnswer
```

The test starts the real relay and Mac sidecar. Its phone proxy adds **100 ms one-way delay** and serializes each direction at **64 KiB/s**. It sends a message on an existing thread, receives a 96 KiB streamed answer, then disconnects the phone while the host finishes another turn and measures recovery from the `heal` call through redial and catch-up. The provider is local and deterministic; no external model or message content enters the metrics.

| Output field | Boundary measured |
| --- | --- |
| `acceptanceMs` | `ChatModel.send` until that message ID leaves the outbox after host receipt. |
| `catchupMs` | Before link repair and client reconnect through the recovered final answer in `ChatModel`. |
| `queuedOperationBytes` | Encoded pending operation bytes immediately after the measured send. |
| `responseBytes` | Observed UTF-8 bytes of the deterministic final answer. |
| `largeAnswerWireBytes` | Host-to-phone encrypted bytes forwarded between sending the large-answer request and observing its final answer; includes accompanying control frames. |
| `phoneToHostBytes`, `hostToPhoneBytes` | Encrypted frame bytes forwarded by the proxy across the whole scenario. |
| `peakQueuedBytes` | Peak scheduled proxy bytes plus both WebSocket `bufferedAmount` values, across phone links. |

The gate requires acceptance in **150–3,000 ms**, catch-up within **10,000 ms**, at most **768 KiB** for the large answer, **1 MiB** of host-to-phone traffic across the scenario, and at most **512 KiB** of proxy queue. The lower acceptance bound catches a bypassed delay profile. Two local macOS runs measured acceptance **249–257 ms**, catch-up **3,858–3,896 ms**, host-to-phone **603,076–604,919 bytes**, large-answer wire traffic **392,422 bytes**, and peak queue **290,567–290,568 bytes**. These limits leave room for runner scheduling while detecting the measured regression.

Before live partials were paced, the host had finished the 96 KiB answer but the phone still lacked it after 20 seconds; the proxy had forwarded **1,220,830 bytes** and peaked at **2,153,782 queued bytes**. Full-text partial snapshots had piled up behind the slow link. The sidecar now paces relay snapshots beyond 16 KiB by estimated transfer cost, preserves unpaced local-socket updates, retains latest state for reconnect, and sends the full durable final answer.

This profile keeps the Swift client process running during disconnection. `ConnectionTests.testALostReceiptSurvivesARelaunchAndSettlesOnce` separately covers app termination before host completion on the simulator. Physical device handoffs and an installed TestFlight candidate remain separate release checks. Stale admission and duplicate execution are asserted by runtime fault tests; this profile measures network latency and bytes, not their incidence in production. Actionable-card priority, huge tool-result fairness, and cursor-gap behavior have separate tests and are not claimed by this profile.
