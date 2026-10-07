# Topic visibility — queued 17:18 correction reviewed against current native UI

Authority: owner message 1791361132273 clarified that only per-message labels/IDs in the **main timeline** should be suppressed. Inspect-only sub-chats should expose human-readable topics. That message did not approve an exact side-panel/navigation proposal. A later, separate **18:04** owner decision approved the native sidebar/alongside-inspector layout; **18:10** approved the Swift-native stack. Those later records remain controlling.

## Current implementation already satisfies the correction

Reviewed `Sources/ProjectXApp/ProjectX.swift` rather than duplicating UI work or updating the superseded browser prototype:

- `MessageCard` renders author and original message body, not a per-message topic label/ID.
- `MainChat` uses those cards and retains the main composer.
- `InspectionPane` prominently renders `topic.label` with headline styling and an “Inspect only” status.
- Sidebar rows render human-readable `topic.label` and open the corresponding inspector.
- The inspector has no text-entry field or send action.

No native source/layout changes were necessary. Existing worker-memory implementation/evidence was not duplicated. This review does not claim the original 17:18 message approved the later layout.

## Focused checks actually run

Added `tests/ui_contract_topic_visibility.py`, run explicitly as a source-contract check:

```sh
python3 tests/ui_contract_topic_visibility.py
# 3 checks passed
python3 -m unittest discover -s tests -q
# 60 preserved Python prototype regressions passed
```

Checked Swift source SHA-256: `fae602f607b0f794d34f061eb0b254ced103b84bb30111673d508b0c463bc2a9`.

The three checks cover uncluttered main cards, human-readable inspector/sidebar titles, and inspect-only sub-chats with the composer remaining in main. They are deliberately separate from the historical Python runtime suite and do **not** count as rendered SwiftUI/UI automation tests. Source refactoring may require updating them.

No app was launched, no visual acceptance claimed, and no native build/live Gateway run was performed by this review. The active native QA worker and its newer canonical status were left untouched. No global configuration, Gateway guard bypass, commit or publishing.
