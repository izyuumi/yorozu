# Hermes release provenance gate

`package-hermes-runtime.py verify` checks **self-consistency** and executes an
inert import probe. It is **not** a trusted-input gate. Never run it on an intake
artifact until the following inert gate succeeds:

```sh
python3 scripts/hermes-release-provenance.py \
  --artifact "$YOROZU_HERMES_RUNTIME_ARTIFACT" \
  --reviewed-repo "$SOURCE_REPO" --reviewed-revision "$REVIEWED_SOURCE_SHA"
```

The reviewed revision must be the caller's already authenticated/reviewed exact
commit, not a value read from the artifact. This helper does not independently
approve a revision or verify its signature. It reads the pin, layout, archive
receipt and six adapter files through `git show` at that exact revision (not the
working tree). It checks:

* Exact upstream object equality to committed `runtime-input-pin.json`.
* Exact path mapping and approved non-plugin inventory digest from committed
  `runtime-layout.json`. Regenerating an artifact's own inventory is insufficient.
* All six plugin bytes/modes and absence of extra plugin files against reviewed
  source. An old adapter revision claim cannot authorize different bytes.
* Original public-archive receipt bound by its committed SHA-256, with matching
  source, lock, Python tree/binary and dependency identities.
* Actual inventory equality, contained relative symlinks and RECORD ownership;
  no `sitecustomize`/`usercustomize` modules/packages or retained startup hooks.

This helper performs no artifact execution. The ordinary verifier and import
probe may run **after** this gate. A `productionReady` flag is not authority.

## Nested signing

1. Run the inert gate on the unsigned artifact **before** copying/packaging or
   invoking any artifact executable. Preserve its `runtime-artifact.json` to a
   task-owned path **outside** the runtime as `unsigned-manifest.json`.
2. Copy the verified runtime, sign existing native code using the release lane's
   existing controlled signing process, and use the ordinary packager's
   `reseal-after-nested-signing` operation.
3. Run the same inert gate on the copied/resealed runtime, adding
   `--unsigned-manifest /job-owned/path/unsigned-manifest.json`.
4. Outer bundle signing comes afterward. Keep the unsigned manifest and both
   verification receipts with the release evidence.

The supplied unsigned manifest is **not** blindly trusted: its upstream,
non-plugin inventory, adapter bytes and native allowlist are rechecked against
committed source. Only hashes of the committed list of existing Mach-O files may
change, never modes, links, layout, adapter, Python source or dependency metadata.
The manifest's native list cannot reclassify a Python module as native. This is a
controlled-signing transition check, not cryptographic proof that arbitrary
changed native instructions were caused only by codesign; the release lane must
retain its own code-signature identity verification and restrict who can modify
the tree during signing. Do not accept an externally supplied already-signed
artifact solely using an attacker-supplied signing claim.

## Approved payload and regeneration

The current non-plugin inventory is
`c9d9dc362979e79072ebd51db5fae97828ca31d7e1566df2b243b605e8511a6b`.
It comes from the existing task-owned, relocated **assembled-before-signing**
runtime. The original evidence remains read-only. A candidate with new reviewed
adapter files can retain this payload; final adapter source must be committed
before regenerating its manifest. No final artifact was sealed by this change.
The Git object pack/index are part of the payload; rebuilding Git metadata by a
different implementation can change this digest and requires explicit review,
not automatic repinning.

Parent integration owns `build-mac.sh`, workflow and intake changes. Wire this
helper before the old `verify` invocation and after controlled signing/reseal;
include helper/test files in any staged source overlay. Run both inert test suites:

```sh
python3 scripts/test-package-hermes-runtime.py
python3 scripts/test-hermes-release-provenance.py
python3 scripts/test-hermes-public-archive-provenance.py
```

## Original public archive provenance established 2026-10-06

Machine-readable committed evidence: `docs/hermes-public-archive-provenance.json`,
hash-bound from the layout. All acquisition was unauthenticated public official
build inputs; no profiles/accounts or external review services.

Python: official `astral-sh/python-build-standalone` release **20261003**,
`cpython-3.13.16+20261003-aarch64-apple-darwin-install_only_stripped.tar.gz`,
SHA-256 `9e01f63bbb08576cd9c8bc2d0564d098cb30c8453a0cd4bcf6aef458f6d2a147`,
25,246,115 bytes. The digest matched the official GitHub release asset digest
**before extraction**. Of the 899 selected runtime rows, 898 exactly match the
prepared pin, including the interpreter binary
`b898474cdfda938c1dd25af22d1b066d4808ba8b7e2d14e20033781d7787f87f`.
The sole difference is `_sysconfigdata__darwin_darwin.py`: verified as exactly one
literal dictionary assignment, with a deterministic relocation/compiler-name/
whitespace/escaping transformation and `PYTHON_BUILD_STANDALONE=1`. The verifier
compares every literal, without executing that module. The full prepared tree
remains `9666d8c2f6e7adad510d58a11cf25a2e9e5f0d1aeb2cf0a7fc044ea897419599`.
The unstripped 20261003 and 20261001 assets were also hash-verified but **do not
match** this snapshot; they are not accepted substitutes.

Dependencies: **62** original wheels from official `files.pythonhosted.org`, all
matching their URLs and SHA-256 values in exact Hermes `uv.lock`; archive RECORDs
were independently verified and relevant installed bytes compared. **61** match
without payload changes. Pillow's only difference is the previously pinned JPEG
RPATH deletion/ad-hoc signature: this was independently reproduced from the newly
downloaded wheel in a fresh task-owned directory and exactly matched the existing
artifact's `cfda9dd08a972b06cf035d2b839486fcd4397bff90fbb4c555c9e4a75adedb95`.
No distribution signing was performed. Hermes itself is Git source, **not a
published input wheel**; its editable-install metadata is explicitly generated,
with each retained metadata file recorded in the evidence. Installed RECORD,
INSTALLER and other installer-generated metadata are not mislabeled wheel bytes.
The old input-pin evidence strings are retained as historical preparation facts;
the separate committed receipt supplies the previously missing verification.

Local public archives and raw receipts are at the task sibling directory
`../hermes-public-provenance/` (relative to the fix-provenance worktree):
`python-stripped-20261003.tar.gz`, `python-release-20261003.json`,
`python-receipt.json`, `wheels/*.whl`, `wheels/wheel-receipts.json`, and
`jpeg-receipt.json`. Individual wheel paths/digests are enumerated in the committed
receipt. Helpers allow reacquisition/comparison without installations:

```sh
python3 scripts/hermes-public-archive-provenance.py \
  --source /task-owned/upstream-hermes \
  --venv /task-owned/relocated-artifact/python --output /new/task-owned/wheels
python3 scripts/hermes-python-archive-provenance.py \
  --archive /task-owned/python-stripped-20261003.tar.gz \
  --prepared-python /task-owned/tools/mise/installs/python/3.13.16 \
  --pin packages/harness-plugins/hermes/runtime-input-pin.json
```

The mutable upstream checkout's `.venv` has drifted (it includes packages absent
from the frozen lock), so it was **not** accepted as current input. Wheel
comparison uses the explicitly supplied read-only relocated runtime instead.
Public content provenance is now established, but this does not approve a remote
artifact origin, final source review, native QA, release dispatch or distribution.
`productionReady` remains false.
