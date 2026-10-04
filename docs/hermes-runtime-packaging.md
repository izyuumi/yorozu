# Pinned Hermes runtime artifact

`scripts/package-hermes-runtime.py` assembles an offline macOS arm64 runtime from explicitly prepared public inputs. It never downloads, installs, starts Hermes, reads an installed profile or selects an account. The only local signing operation is an explicit ad-hoc signature on the copied, pinned JPEG library after the reviewed load-command edit below; it uses no identity lookup or Keychain. Runtime resources contain no user history, preferences, credentials or provider bootstrap. The native app, host factory, permission boundary and fresh account onboarding remain separate release gates.

The artifact layout is versioned by `packages/harness-plugins/hermes/runtime-layout.json`:

```text
runtime-artifact.json
python/bin/python3.13
python/lib/python3.13/             # standard library + locked site-packages
source/                            # unchanged complete f976 tracked tree
source/.git/                       # newly generated one-commit identity
plugin/adapter.mjs
plugin/manifest.json
plugin/bootstrap.py
plugin/platform/__init__.py
plugin/platform/plugin.yaml
plugin/README.md
```

The trusted factory uses the three manifest paths and grants read access to the immutable `python`, `source` and `plugin` subtrees. The interpreter is a canonical real binary outside `source`; there is no venv, absolute interpreter link, ambient Python lookup or editable import hook. Agent profiles/workspaces are created by the host outside this artifact. Do not put an account token, inference broker bootstrap or user profile into the bundle.

## Prepared inputs and provenance

The source pin is Hermes `0.21.5`, commit `f97608f178d1ffeca59860195ab7da295f7c8e5f`, tree `5849eacde63aaea608ca418821cc84771fce3bec`. Its unchanged `uv.lock` SHA-256 is `5b3798f326209475abca8ef7cbf7c9406f12e687c28c0b540dfe597466f48590`.

The prepared interpreter is CPython `3.13.16`, Darwin arm64. The companion layout pins its actual binary and selected runtime-tree bytes. The original Python download archive receipt is unavailable in the current prepared tools, so this is an explicitly hashed local snapshot; it is not a claim that the original archive has been independently verified. A new Python build or architecture requires a new reviewed pin.

Prepare a fresh task-only environment using the exact source, explicit interpreter, cleared environment, isolated HOME/cache, uv `0.11.7`, `--frozen --offline --no-config --no-default-groups --no-python-downloads`. The current task-owned cache can supply all 63 core distributions. Preserve the command/exit-status receipt and log. A missing locked cache entry is a blocker; the helper has no download or repair fallback. Runtime optional extras need separate pinned preparation and capability checks.

The previous prepared venv contains nine versions absent from the lock and is rejected. Do not repair or copy that venv into a release. The new frozen preparation is independent of it.

The helper checks every installed distribution/version against `uv.lock` and verifies installed files against their `RECORD` hashes. It rejects undeclared executable `.pth` hooks and escaping records/symlinks. It strips the known editable/virtualenv hooks, original checkout URLs, uv cache metadata, bytecode and console scripts, then rewrites dependency records for the packaged layout. Dependency source files and compiled libraries are copied, with one explicitly pinned native exception. Original wheel archive hashes are not independently reverified by this helper. The generated full input snapshot records installed RECORD evidence and must be explicitly reviewed before assembly.

The copied `PIL/.dylibs/libjpeg.62.4.0.dylib` contains the unused build-machine `LC_RPATH` `/Users/runner/work/Pillow/Pillow/build/deps/darwin/lib`. Assembly requires input SHA-256 `cf7c4e5c2d2c007fc51afcb95b649415cfe0bc4d7137ace897a6eff6550fa967`, deletes only that exact RPATH with `install_name_tool -delete_rpath`, and requires intermediate SHA-256 `56a3a10ac81f12a0e6ae7cc5a023924067f4e7c2defd8308b9ed806064ab560d`. This edit invalidates the wheel's ad-hoc signature: an unsigned intermediate correctly failed `codesign --verify`, and `PIL.Image` import exited 137. The helper applies `codesign --force --sign -` only to this copied library and verifies the result before importing it. Both transformations record before/after hashes in `derivation.nativeLoadCommandTransformations`; original wheels, cache, source and preparation are unchanged. This local signature does not satisfy distribution signing.

The shipped source is reconstructed from the exact public Git objects. Generated Git metadata has a detached pinned HEAD, shallow one-commit history, full tracked tree/index and minimal local configuration. It contains no original Git config, remotes, hooks, alternates or credential helpers. Git verification uses a fresh private temporary `GIT_INDEX_FILE`, `read-tree <pin>`, then `diff --quiet HEAD --`. Ordinary Git diff can refresh an index despite `GIT_OPTIONAL_LOCKS=0`; factory/adapter checks must also use a private verification index and never write bundled source.

## Assembly and checks

Use an explicitly selected signed adapter revision. The tested artifact exports `e37d29563db366f20ff2b72a1189828f1d057287`, which includes the lazy-install/scanner refusal settings and private verification-index fix. Its six plugin files are also identical at root revision `32ba394e818e6d1fef8186b9b25fa348065fca1f`. Supply the reviewed full 40-character SHA. The helper exports only those runtime files from that commit, so uncommitted changes are not silently adopted.

```sh
python3 scripts/package-hermes-runtime.py inspect \
  --source <exact-public-checkout> --venv <fresh-frozen-venv> \
  --python-root <prepared-cpython-root> > <reviewed-input-pin.json>

python3 scripts/package-hermes-runtime.py assemble \
  --source <exact-public-checkout> --venv <fresh-frozen-venv> \
  --python-root <prepared-cpython-root> \
  --plugin-source <reviewed-yorozu-checkout> --plugin-revision <full-signed-sha> \
  --destination <new-candidate-runtime-directory> --pin <reviewed-input-pin.json>

python3 scripts/package-hermes-runtime.py verify --artifact <candidate-runtime-directory>
```

Invoke these build commands with an explicit prepared Python binary and isolated build environment. An existing destination or destination overlapping inputs is rejected. Any failure retains its incomplete owned output for inspection; it does not mark the artifact accepted. `runtime-input-pin.json` in this change records the successful task-local frozen preparation. Input RECORD hashes can depend on the preparation path; another preparation requires comparing and explicitly approving its new snapshot, rather than silently replacing this pin.

Assembly audits every Mach-O file with `otool`/`lipo`: arm64 must be present, every RPATH must remain internal or Apple system, and each actual library load must resolve to an owned artifact file or Apple system library. It runs only isolated interpreter, SSL/SQLite, Pillow and dependency imports, and checks the complete base dependency closure. It verifies `sys.prefix`, `sys.base_prefix` and certifi resolve inside the artifact. No Hermes Gateway, agent loop, model, tool, schedule or account is started.

Physically move the artifact, then run `verify` again. This catches original-checkout, interpreter, native-library and index-cache dependencies that a check at the assembly path can miss. Verification hashes every file and checks the pinned source using a fresh private Git index.

`runtime-artifact.json` schema 1 includes `kind: "yorozu-hermes-runtime"`, `productionReady: false`, the input pins, signed adapter source SHA, relative paths, explicit layout derivation, inert probe results, native-library resolutions and the complete file inventory. Each row is `{path,sha256,mode}` or `{path,link}`; modes are decimal 420/493. `inventorySha256` hashes UTF-8 compact JSON of the array, sorted object keys, no ASCII escaping, preserving array order. There are currently 20,049 rows and approximately 3.7 MiB of metadata; a loader should bound input at 8 MiB and reject excessive counts, unsafe/duplicate paths, links escaping the artifact and mismatched hashes.

## Bundle integration and signing order

Parent integration owns `build-mac.sh` and `stage-internal-alpha.py`; this change does not edit them. Include this helper, the two runtime pin/layout files and all runtime plugin files in the reviewed staging overlay. Place the complete runtime artifact under a stable app Resources directory; the factory must resolve it from the bundle and verify its version/pins/inventory. The iOS app remains the existing client and does not embed Python.

Copy/assemble the runtime before the existing nested native-code signing loop. Sign its native interpreter and libraries with the release's existing identity and appropriate entitlements; validate that the signed interpreter still starts. Before signing the outer app, run:

```sh
python3 scripts/package-hermes-runtime.py reseal-after-nested-signing \
  --artifact <bundled-runtime-directory>
```

Resealing allows hash changes only to previously recorded Mach-O files, preserves paths/modes and rejects source/layout edits. The caller owns controlled signing and signature/identity verification; this helper cannot classify arbitrary Mach-O edits as signature-only changes. It reruns all load/import checks and commits the updated manifest only after they pass, recording final native hashes and `hashStage: "after-nested-signing-before-outer-bundle-signing"`. This command does not sign or attest an identity. Installed dependency RECORD evidence describes the pre-signing preparation; the final manifest is authoritative after Apple's native signatures change bytes. Sign/verify the outer app after resealing, then record final app/DMG hashes and notarization through the existing internal lane. Never change the manifest after the outer signature.

The tested candidate contains 63 frozen distributions and 56 arm64 Mach-O files. It passed assembly and physical relocation to an owned `Resources/agent-runtimes/hermes` layout, including immutable Git index verification, strict RPATH/load audits and `PIL.Image` import. A separate fresh-profile, credential-free import of `tui_gateway.entry` passed using the packaged adapter's safety configuration; it did not call Gateway `main`, select a provider, start a model or attest an OS sandbox. The candidate remains `productionReady: false`. No app signing, notarization, installation, TestFlight upload or device validation has run in this task. Live subscription onboarding is unproven. Native lazy installation must remain disabled through both `security.allow_lazy_installs: false` and `HERMES_DISABLE_LAZY_INSTALLS=1`. Terminal execution is unavailable while the curated Tirith helper is missing: fail-closed refusal is required, not a claim of terminal readiness. Optional browser/provider/tool extras need explicit support checks. The denied OpenClaw build remains stopped and is unrelated to this artifact.
