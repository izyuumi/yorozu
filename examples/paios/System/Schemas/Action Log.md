# Action Log Schema

```yaml
id: action-01J...
type: action_log
schema_version: 1
status: verified
title: Example completed action
execution_item_id: task-...
action_class: purchase
service: example.com
account_class: personal
commit_point: "Submitted order"
authority_type: active_authorization
authorization_id: authorization-...
committed_at: 2026-01-01T12:00:00+00:00
verified_at: 2026-01-01T12:01:00+00:00
cost:
currency:
external_reference_redacted:
source_refs: []
created: 2026-01-01T12:00:00+00:00
updated: 2026-01-01T12:01:00+00:00
```

## Body sections

- `## Requested outcome`
- `## Material parameters`
- `## Authorization and match rationale`
- `## Steps and commit point`
- `## Verification evidence`
- `## Result and side effects`
- `## Recovery or cancellation path`
- `## Learning`

Do not store secrets, full payment details, precise addresses, or sensitive confirmation data.
