# PAIOS: an example personal-ops vault

PAIOS (personal AI operating system) is an example personal-ops vault layout that works well with Yorozu and AI agents. It's a folder of plain Markdown, built for an Obsidian vault, that gives your agents a shared memory, rules for when they may act, and a place to log what they did.

It's optional. Yorozu works without it, and nothing in Yorozu reads this folder. It's here as a starting point you can copy and change.

Every file is either part of the framework (rules, schemas, templates, workflows, scripts) or a small example clearly marked **Example file**. There is no real data in it.

## What you get

- **Rules for agents:** a Constitution (`System/Constitution.md`) and policies for evidence, delegation, privacy, vault boundaries and cleanup.
- **A memory model:** history, knowledge, workspace, execution and learning stay in separate folders, so a plan isn't mistaken for a fact or an old "yes" for a current approval.
- **Schemas and templates** for projects, decisions, preferences, entities, sessions, authorizations, action logs and reports.
- **Workflows** for answering, acting, session handling, conversation ingestion, and daily, weekly and monthly maintenance.
- **Agent conventions:** a file-based handoff between roles (`Handover/`), log notes with a nine-field receipt, and a preflight that tells an agent when the rule files changed.

## How to adopt it

Prefer to let an agent do it? Paste the prompt in [INSTALL_WITH_AGENT.md](INSTALL_WITH_AGENT.md) into your coding agent.

### One command

```bash
curl -fsSL https://raw.githubusercontent.com/izyuumi/yorozu/main/examples/paios/install.sh | bash -s -- "/path/to/your vault"
```

Or from a checkout of this repository:

```bash
bash examples/paios/install.sh "/path/to/your vault"
```

The vault folder must already exist. The script copies this folder into `<vault>/PAIOS`, writes `PAIOS/paios.env` with your vault path and time zone, and runs the self-test. If `<vault>/PAIOS` already exists it refuses and changes nothing; it never overwrites or merges. Without a path, it asks for one when run on a terminal. It needs bash and Python 3.9+, plus curl and tar when not run from a checkout. When it finishes it prints the next steps: load the variables with `source "<vault>/PAIOS/paios.env"`, then steps 3 to 5 below.

Options:

- `--tz <zone>`: your IANA time zone, e.g. `--tz Europe/Berlin`. Default: `PAIOS_TZ` if set, else the system zone, else UTC.
- `--ref <ref>` or `PAIOS_REF`: the branch, tag or commit to fetch when the script is not run from a checkout. Default: `main`.
- `PAIOS_REPO`: `owner/name` of a fork to fetch from. Default: `izyuumi/yorozu`.
- `-h`: show the help.

You can read the script before running it:

```bash
curl -fsSL https://raw.githubusercontent.com/izyuumi/yorozu/main/examples/paios/install.sh -o install.sh
less install.sh
bash install.sh "/path/to/your vault"
```

The script itself comes from `main`. Add `--ref <commit>` to pin the files it installs to that commit.

### No script

This needs Node.js.

```bash
npx degit izyuumi/yorozu/examples/paios "/path/to/your vault/PAIOS"
```

Then delete `install.sh` and `INSTALL_WITH_AGENT.md` from the copy and follow the steps below from step 2.

### By hand

1. Copy this folder into your Obsidian vault and name it `PAIOS`:
   ```bash
   cp -R examples/paios "/path/to/your vault/PAIOS"
   ```
   Then delete `PAIOS/install.sh` and `PAIOS/INSTALL_WITH_AGENT.md`.
2. Set the environment variables your agents and scripts use (see `paios.env.example`):
   ```bash
   export PAIOS_VAULT="/path/to/your vault"   # the folder that contains PAIOS/
   export PAIOS_TZ="UTC"                       # your IANA time zone, e.g. Europe/Berlin
   ```
   Or copy `paios.env.example` to `paios.env`, fill it in and `source` it.
3. Point your agent at it. Give it `System/Prompts/Agent Master Prompt.md` as its system prompt, or tell it to start with `AGENTS.md`.
4. Read `System/Constitution.md` and change what doesn't fit you. Add your own amendments as dated, numbered sub-principles.
5. Replace the example files (`Runtime/Now.md`, `Projects/Example Project.md`, `Execution/Queue.md`, and so on) with your own, or delete them.
6. Optional: import past conversations with an importer of your choice. `System/Prompts/Bootstrap Directive.md` describes a safe import (read-only, dry run first, redact before writing, never replay old actions). This example ships no importer.
7. Optional: if you run several agents, rename the roles in `Handover/README.md` and set `HANDOFF_ROLES`.

## Folder map

| Folder | What goes there |
|---|---|
| `System/` | Stable rules and operating design: Constitution, architecture, policies, workflows, schemas, templates, prompts, SOPs, scripts. |
| `Runtime/` | Small, current bookkeeping: what needs attention now, source coverage, last maintenance, migrations. |
| `Knowledge/` | Evidence-backed beliefs: current state, entities, preferences, inferences, decisions, goals, timelines. |
| `World/` | External people, organizations, places and products. |
| `Projects/` | Multi-session objectives, one record each. |
| `Workspace/` | Unfinished thinking: drafts, research, plans. Not treated as true. |
| `Execution/` | The task queue, pending approvals, authorizations, purchases, and action logs. |
| `Sessions/` | Session journals and normalized conversation imports. |
| `Learning/` | Corrections, predictions and drift: how the models improved. |
| `Reports/` | Daily, weekly and monthly reports. |
| `History/` | Append-only records that don't belong to one entity. |
| `Indexes/` | Rebuildable navigation aids; never the only copy of anything. |
| `Archive/` | Retired material. Archive instead of deleting. |
| `Attachments/` | Non-secret binary files. |
| `Handover/` | Work passed between agents or roles. |

`System/Directory Structure.md` has the placement rules and naming conventions.

## Scripts

The scripts under `System/Scripts/` are standard-library Python 3.9+ or bash, take paths from environment variables, and make no network requests. `install.sh` takes the vault path as an argument and, when not run from a checkout, downloads this repository's tarball from GitHub.

| Script | What it does |
|---|---|
| `System/Scripts/paios-log/paios-log.py` | Writes `Execution/Logs/YYYY-MM-DD <agent> <topic>.md` with the nine receipt fields. Refuses secret-looking text; never overwrites. |
| `System/Scripts/paios-log/log-receipt-check.sh` | Checks that every log note has a full receipt. Prints `CHECK PASS` or `CHECK FAIL`. |
| `System/Scripts/vault-preflight/preflight.sh` + `compare.py` | Tells an agent whether the vault is reachable and which rule files changed since it last read them. |
| `System/Scripts/handoff/handoff.py` | Writes, claims, closes and checks handoff files in `Handover/`. |
| `System/Scripts/selftest.sh` | Runs all of the above against a temporary copy and prints `SELFTEST PASS`. |
| `install.sh` | Copies this folder into `<vault>/PAIOS`, writes `paios.env` and runs the self-test. Refuses if `PAIOS` already exists. The installer leaves itself and `INSTALL_WITH_AGENT.md` out of the copy. |

| Variable | Used by | Default |
|---|---|---|
| `PAIOS_VAULT` | all scripts | none; the folder that contains `PAIOS/` |
| `PAIOS_TZ` | dates and timestamps | `UTC` |
| `PAIOS_LOGS` | paios-log | `$PAIOS_VAULT/PAIOS/Execution/Logs` |
| `HANDOFF_ROOT` | handoff | `$PAIOS_VAULT/PAIOS/Handover` |
| `HANDOFF_ROLES` | handoff | `chief-of-staff,coder,product-owner` |
| `PAIOS_PREFLIGHT_STATE` | vault-preflight | `state/` next to `compare.py` |
| `PAIOS_REF` | `install.sh`, when not run from a checkout: the ref to fetch | `main` |
| `PAIOS_REPO` | `install.sh`: the `owner/name` to fetch | `izyuumi/yorozu` |

## Privacy

Keep your own copy private. The rules tell agents never to store secrets and to redact high-risk identifiers, but your vault will still hold personal context. Don't commit a filled-in vault to a public repository.

## License

Same as the rest of this repository (MIT, see the root `LICENSE`).
