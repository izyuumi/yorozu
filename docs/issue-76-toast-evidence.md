# iOS connection toast evidence

At `2acff06`, the focused `ConnectionTests.testAReconnectingLinkIsShownOnlyWhenItLastsAndClearsItself` run passed on an iPhone 17 Pro simulator running iOS 26.5 against the real relay and Mac sidecar through the fault proxy. A short disconnect showed no status or toast. A sustained blackhole showed one toast after the connection grace; the empty-list content's vertical position and height stayed within one point of their connected values. The toast dismissed while Settings kept a disconnected status, and healing restored **Connected** without moving list content. The screenshot below records that earlier empty-list run.

![Single Reconnecting toast over the unchanged thread-list empty state](screens/issue-76-connection-toast.png)

PR #143 changed the test to create and settle a thread before measuring the list. On the same simulator and relay fault proxy, its row kept the same vertical position and height through the toast; the focused test passed 1/1 and the full `ConnectionTests` class passed 4/4 with another test's thread already present. The short-drop, single-toast, dismissal, persistent Settings status, and recovery checks also passed. This verifies a stationary populated-list row as well as the earlier empty-list run.

Populated-list scrolling during incoming activity, keyboard/safe-area behavior, accessibility, reduced motion, installed clients, and physical-device handoff still need acceptance checks.
