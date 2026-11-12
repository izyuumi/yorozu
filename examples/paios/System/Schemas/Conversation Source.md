# Conversation Source Schema

```yaml
id: source-01J...
type: conversation_source
schema_version: 1
status: active
title: Local Codex history
runtime: codex
format: sqlite
path_redacted: "~/Library/.../history.db"
read_only: true
timezone: UTC
coverage_start:
coverage_end:
last_imported_at:
cursor:
mapping_version: 1
notes: ""
created: 2026-01-01T12:00:00+00:00
updated: 2026-01-01T12:00:00+00:00
```

Store source paths only when operationally necessary and avoid exposing usernames or sensitive mount names in shared reports. Do not store database credentials.

Normalized events use:

```json
{"event_id":"event-...","source":"codex","conversation_id":"...","message_id":"...","role":"user","timestamp":"2026-01-01T12:00:00+00:00","sequence":0,"text":"...","content_type":"text","source_locator":{"kind":"sqlite","record":"..."},"content_hash":"...","redactions":[],"import_version":"0.1.0"}
```
