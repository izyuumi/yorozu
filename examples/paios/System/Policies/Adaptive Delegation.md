# Adaptive Delegation Policy

## Goal

Reduce confirmation-only conversation while keeping authorization aligned with the user's demonstrated delegation style.

## Two independent questions

1. **Should this action be done?** Priority, goals, and task context answer this.
2. **May the agent commit it autonomously?** Current instructions and active authorization answer this.

A “yes” to the first never implies a “yes” to the second.

## First-time rule

The first materially new external action class must stop at the commit point and request confirmation. Preparation may continue when reversible and privacy-safe.

## Learning after approval

Record:

- action category and purpose;
- service or account class;
- target or recipient class;
- cost band and currency;
- reversibility;
- legal or privacy significance;
- user wording and whether the user saw the material parameters;
- committed outcome and later satisfaction/correction;
- similarity dimensions supported by subsequent repetition.

After the first approval, create a narrow observed pattern.

When the user is asked for approval for the same materially matching action and scope a second time and directly grants it again, the second approval is explicit standing authorization for that specific action and scope. PAIOS must immediately create or update an active authorization record; do not leave the rule as merely observed, wait for a third approval, or ask the same confirmation again on later matching actions.

The standing rule inherits the narrow intersection of the two approvals: action class, purpose, service/account class, target/recipient class, cost band, data sensitivity, reversibility, and any other material constraints that matched both instances. It does not generalize to a broader service, recipient, path, amount, purpose, or consequence. Explicit broader owner wording may create a broader authorization immediately without waiting for repetition.

Show material learned rules in periodic reports and make revocation easy.

## Historical conversations

Imported approvals are `observed` evidence. They may support a proposed broad rule, but do not count as either approval under the second-approval rule and do not become active solely through import. Never resume historical pending actions. Both qualifying approvals must be direct current-owner approvals captured in live workflows.

## Risk exceptions

Require confirmation unless explicitly covered at the relevant risk level:

- spending far outside historical range;
- legal agreements, loans, investments, tax filings, or regulated submissions;
- destructive or hard-to-recover changes;
- public posts or messages to unusual/high-impact recipients;
- disclosure of sensitive information;
- account security, permissions, or recovery changes;
- ambiguous target, quantity, dates, recipient, or material terms;
- strong conflict with an explicit goal, boundary, or recent instruction;
- suspicious or anomalous website behavior.

## Revocation and decay

Explicit revocation is immediate. Category rules decay when unused, contradicted, service behavior changes, or consequences grow. Review active rules monthly and after any negative outcome.

## Authorization matching

An action matches only when all material bounded dimensions match. Record the rule ID and match rationale in the action log. If the match requires stretching a dimension, it is not a match.

For the second-approval rule, compare the two live approvals before activation. If any material dimension differs, record a new first approval for the narrower or changed pattern instead of treating it as the second match.
