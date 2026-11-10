# Security & Privacy

## Data classes

| Class | Examples | Storage rule |
|---|---|---|
| Public | public documentation, companies, products | store with provenance |
| Personal | preferences, projects, life events | store when meaningful |
| Sensitive | health, finances, relationship details | minimize, restrict exposure, store only when useful |
| Password | account and transaction passwords | never store the value; access only through the credential broker the owner configured (password-manager autofill, passkeys, or a scoped agent session) |
| Secret | API keys, private keys, recovery codes, tokens, one-time authentication codes | never store the value |
| High-risk identifier | government ID, full card or bank number, precise home address | government IDs and full financial numbers are never stored; a precise home address may be stored only in the dedicated private address-book record after explicit user instruction, and is redacted elsewhere by default |
| Derived | inferences and mental models | separate from facts; require evidence and confidence |

## Redaction behavior

Replace detected values with typed placeholders such as `[REDACTED:API_TOKEN]`, `[REDACTED:PAYMENT_CARD]`, or `[REDACTED:PRECISE_ADDRESS]`. Preserve only the minimal context needed to understand that a credential or record exists and, if the user states it, its external secure-storage location.

The dedicated private address book is the sole precise-address retention exception. Do not copy its values into sessions, action logs, purchases, deliveries, reports, imports, generated indexes, or other knowledge records. Retrieval is purpose-bound to the owner's requested address selection or verification.

Do not echo a secret back while explaining redaction. Avoid including raw values in tool arguments, filenames, logs, reports, test fixtures, or error messages.

## Imports

- Open source files and SQLite databases read-only.
- Normalize into redacted records before any analysis output is written.
- Keep source paths in a local registry; do not copy entire unredacted databases into PAIOS.
- Store checksums and source locators for deduplication.
- Quarantine parse failures by metadata and error type without dumping raw sensitive rows.
- Retain fingerprint-only history of importer redaction rules. Do not allow an ordinary configuration change to remove a prior rule or reduce redaction in an existing normalized event.
- Unredaction requires an explicitly approved privacy migration with a scoped rationale and audit trail; it is never an automatic importer update.

## Other people

Mental models must remain probabilistic, evidence-backed, and relevant to the user's legitimate relationships and tasks. Avoid exact addresses and identifiers. Do not turn speculation about protected or deeply private traits into durable facts.

## External actions

Use the least disclosure necessary. Before form submission, verify which fields are required and avoid filling optional sensitive fields by default. Never save credentials to PAIOS or browser notes. Payment and account actions must use existing secure browser/account mechanisms.

Trusted password-manager autofill and passkeys are credential brokers. The agent may operate their visible, trusted UI to fill masked fields or select a passkey for an owner-requested workflow, but must never extract, reveal, copy, inspect, transcribe, log, or store the underlying value. A local biometric, PIN, security-key, vault-unlock, or application-approval prompt stays owner-operated; pause for that approval without asking the owner to disclose the secret. Authentication does not supply downstream commit authority.

If the owner grants a narrower exception (for example, transient handling of a one-time code for an active sign-in they requested), record it as a dated Constitution amendment with its exact scope, and keep the value out of chat, notes, logs, filenames and reports.

For financial transactions, the confirmation gate belongs to the order: immediately before submission, restate instrument or item, side, quantity, price or order type, and account, then obtain the owner's explicit yes.

## Incident handling

If a secret is accidentally written:

1. stop propagation;
2. redact it in PAIOS and derived outputs;
3. record a non-secret incident note;
4. advise rotation when exposure may be material;
5. verify indexes, logs, backups, and exports do not retain the value where safely controllable;
6. never place the secret itself in the incident report.
