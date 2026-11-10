# Purchase Schema

```yaml
id: purchase-01J...
type: purchase
schema_version: 1
status: ordered
title: Example item
product_entity_id: entity-...
seller_entity_id: entity-...
action_log_id: action-...
order_date: 2026-07-31
quantity: 1
total_cost: 0
currency: USD
delivery_status: pending
return_deadline:
warranty_end:
external_reference_redacted:
created: 2026-07-31T12:00:00+00:00
updated: 2026-07-31T12:00:00+00:00
```

Body sections: reason, compared alternatives, selection rationale, non-secret receipt metadata, delivery, return/warranty, satisfaction, and preference evidence. Never store full payment details or a precise delivery address.
