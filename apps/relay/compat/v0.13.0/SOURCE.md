# Shipped relay v0.13.0

Versioned source from tag `v0.13.0`, commit `6c09908c94c5638d154ae8a5d0e6d0ee848a0dae`.
Test fixture only: never build or deploy as a service. The compatibility worker
project loads this source only to replay storage written by newer relays.
No SDK is copied. Source files are unmodified, byte for byte.

Same project, licensed under this repository's [MIT license](../../../../LICENSE).

| File | SHA-256 |
| --- | --- |
| `src/worker.ts` | `0a8d177f703226653fb78f37e9a2b2a5a2dbd3ba7f5da2843b4fa2d46037d749` |
| `src/protocol.ts` | `12359e176fa7eaa4b277f5986c0ef82375c87169504d3f8dedf869de3998b6e0` |
| `src/apns.ts` | `ed075a884c7d05c9f3672e47751aefd331ef0d32ad1ca7bfa3075892005cc916` |
| `src/mailbox.ts` | `d1a51e79a3e17c9c487583a07946315d9bbcc760a44152e127190d4b2129ffd4` |

From the repository root, reproduce and verify each file (requires the local Git object):

```sh
for f in worker.ts protocol.ts apns.ts mailbox.ts; do
  git show 6c09908c:apps/relay/src/"$f" > apps/relay/compat/v0.13.0/src/"$f"
  git show 6c09908c:apps/relay/src/"$f" | shasum -a 256
  shasum -a 256 apps/relay/compat/v0.13.0/src/"$f"
done
```

`manifest.json` records these hashes. The Node test always checks vendored bytes
against the manifest and also compares them to Git when the commit exists locally.
CI needs neither history nor network. The test-only Wrangler config preserves the
original compatibility date, bindings, rate limit and migrations; its name differs
and its production routes are removed.
