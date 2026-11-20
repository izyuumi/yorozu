# 0007. Local Network explainer

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

iOS shows a system Local Network prompt the first time an app touches the LAN. Direct LAN paths and Bonjour ([0006](0006-direct-path-and-connection-race.md)) need that permission, so the app explains it first, once (#532).

## Decision

- The explainer appears once, after the first session that opens with a pairing. Devices paired before the explainer existed see it after their next connect.
- At scan time (#532 step 5) it also appears while pairing, once the relay couldn't be reached, if the code's hints name LAN addresses and Local Network was neither explained nor denied.
- It stays up if the session drops. A swipe away counts as Not Now.
- Not Now means it doesn't come back; Settings › Host can still turn Local Network on.
- iOS keeps the Local Network switch on the app's own Settings page, so the app opens that page.

## Consequences

- No Local Network prompt appears before the owner has a reason to allow it.

## Where in the code

- `apps/ios/Sources/Client/ConnectionRoute.swift` — `ConnectionRoute.explainerDue`, `ConnectionRoute.pairingExplainerDue`
- `apps/ios/Sources/Client/AppModel.swift` — `explainLocalNetwork()`
- `apps/ios/Sources/YorozuIOS/LocalNetworkExplainer.swift` — `LocalNetworkExplainer`
- `apps/ios/Sources/YorozuIOS/Root.swift` — `onChange(of: model.showLocalNetworkExplainer)`
- `apps/ios/Sources/YorozuIOS/Settings.swift` — `openLocalNetworkSettings()`
