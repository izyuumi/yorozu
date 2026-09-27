# iOS connection toast evidence

`ConnectionTests.testAReconnectingLinkIsShownOnlyWhenItLastsAndClearsItself` passed on an iPhone 17 Pro simulator running iOS 26.5 against the real relay and Mac sidecar through the fault proxy. A short disconnect showed no status or toast. A sustained blackhole showed one toast after the connection grace; the empty-list content's vertical position and height stayed within one point of their connected values. The toast dismissed while Settings kept a disconnected status, and healing restored **Connected** without moving list content.

![Single Reconnecting toast over the unchanged thread-list empty state](screens/issue-76-connection-toast.png)

This verifies the empty-list overlay and toast lifetime in one simulator/network profile. Populated-list scrolling, keyboard/safe-area behavior, accessibility, reduced motion, installed clients, and physical-device handoff still need acceptance checks.
