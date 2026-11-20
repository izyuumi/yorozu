# 0036. PAIOS example: installer safety, env names and checks

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

`examples/paios` is a plain folder of Markdown plus scripts that an owner installs into an existing folder, often with `curl | bash`. The installer must never damage what is there, and older installs must keep working.

## Decision

- Installer (`install.sh`):
  - Installs into an existing folder as `<folder>/PAIOS`, writes `<folder>/PAIOS/paios.env` and runs the self-test. It never overwrites or merges. Exit codes: 0 installed, 1 refused or failed, 2 usage error.
  - Runs from a checkout or as a one-liner piped from the raw GitHub URL to `bash -s -- "<folder>"`.
  - `BASH_SOURCE[0]` is read at top level: inside a function, a piped bash 5 reports the bash binary.
  - Piped through `curl | bash`, stdin is the script, so the folder prompt asks on the terminal.
  - It refuses before downloading anything. A plain `mkdir` claims the folder, so two runs can't both win and nothing existing is touched. Clean-up only ever removes the PAIOS folder this run created.
  - GNU tar needs `--wildcards` for the extraction pattern; bsdtar (macOS) matches it as is and rejects the flag.
  - `paios.env` values are exported, because they are read back from a child process.
  - The self-test works on its own temporary copy and changes nothing in the destination.
  - `main "$@"` is called last, so a download cut off halfway runs nothing.
- Env names: the scripts read `PAIOS_ROOT` (the folder that contains `PAIOS/`), else its older name `PAIOS_VAULT`, which an older install exports alone. The self-test points exactly one of them at its copy: `PAIOS_VAULT` when that is the only one the caller set, else `PAIOS_ROOT`. `paios_env.py` keeps `vault_path` for existing callers.
- `vault-preflight` runs on the machine that holds the PAIOS folder and is read-only. It prints one JSON line: folder reachable, local time, and sha256 and mtime of the PAIOS rule files, so an agent re-reads them only when changed. Time zone: `PAIOS_TZ`, default UTC.
- Log receipts (`log-receipt-check.sh`): read-only. Every PAIOS log note for an agent, dated on or after `<since>`, must carry a receipt with all nine fields. Logs dir: `--dir`, else `$PAIOS_LOGS`, else `$PAIOS_ROOT/PAIOS/Execution/Logs`. Without `--bot` it checks every dated note. Exit 0 all pass, 1 a note is missing fields, 2 no Logs dir.
  - paios-log forbids editing a note, so a numbered addendum `<name> (N).md` with a full receipt fixes it, as does a later note with a full receipt that names this one as `[[<name>]]` or `[[<name>|...]]`. The double-bracket form is this check's own plain-text marker and needs no particular editor; it stays so existing notes still count. The rest of PAIOS uses ordinary Markdown links.
- Secret scanning: `secrets_scan.py`'s patterns are a starter list meant to be extended with other languages (the Japanese labels are one example) and the field names or identifier formats the owner's own sources use.
- CI: every installer run uses `/bin/bash`, so macOS exercises the system bash 3.2. Each step appends the temp dirs it makes to `$RUNNER_TEMP/paios-tmpdirs` for the clean-up step. One step checks that `PAIOS_VAULT` alone still works.

## Consequences

- A failed or repeated install leaves the target folder as it was.

## Where in the code

- `examples/paios/install.sh` — `script_path`, `cleanup()`, `main()`
- `examples/paios/System/Scripts/selftest.sh`
- `examples/paios/System/Scripts/vault-preflight/preflight.sh`
- `examples/paios/System/Scripts/paios_env.py` — `vault_path`
- `examples/paios/System/Scripts/paios-log/log-receipt-check.sh`
- `examples/paios/System/Scripts/secrets_scan.py` — `PATTERNS`
- `.github/workflows/paios-example.yml` — `install` job
