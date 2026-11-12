# Authorization Schema

```yaml
id: authorization-01J...
type: authorization
schema_version: 1
status: proposed
title: Routine electronics purchases
subject_id: user
action_class: purchase
purposes: [replacement, requested_item]
services: []
target_classes: [consumer_electronics]
recipient_classes: [self]
cost:
  currency: USD
  typical_max: 500
reversibility: ordinary_return
data_sensitivity_max: personal
legal_significance: low
confidence: 0.72
origin: historical_observation
evidence_refs: []
last_used:
review_after: 2026-02-01
created: 2026-01-01T12:00:00+00:00
updated: 2026-01-01T12:00:00+00:00
```

## Status

- `observed`: evidence exists but no proposed generalization is ready.
- `proposed`: a rule is ready for efficient user review.
- `active`: may authorize matching actions.
- `suspended`: temporarily unusable pending review.
- `revoked`: explicitly or operationally invalidated.
- `expired`: review/decay threshold passed.

A passed `review_after` flags the rule for review; it does not by itself expire an `active` rule. Only explicit revocation, a decay rule, or owner action changes status.

## Required body sections

- `## Plain-language rule`
- `## Included examples`
- `## Exclusions and confirmation triggers`
- `## Evidence and outcomes`
- `## Similarity dimensions`
- `## Activation, changes, and revocation history`

Imported history never creates `active` status by itself. An authorization cannot store credentials or payment details.
