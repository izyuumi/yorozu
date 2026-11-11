# PAIOS: a shared second-brain folder for you and your AI agents

PAIOS (personal AI operating system) is the central second-brain memory you share with your AI agents: plain Markdown files in a folder, anywhere you like. It gives your agents one shared memory, rules for when they may act, and a place to log what they did. It works well with Yorozu and with any agent that can read and write files.

It needs no particular app: use any editor and any sync tool, or none. Using Obsidian? See [docs/obsidian.md](docs/obsidian.md).

It's optional. Yorozu works without it, and nothing in Yorozu reads this folder. It's here as a starting point you can copy and change.

Every file is either part of the framework (rules, schemas, templates, workflows, scripts) or a small example clearly marked **Example file**. There is no real data in it.

## What you get

- **Rules for agents:** a Constitution (`System/Constitution.md`) and policies for evidence, delegation, privacy, the boundary of your PAIOS folder and cleanup.
- **A memory model:** history, knowledge, workspace, execution and learning stay in separate folders, so a plan isn't mistaken for a fact or an old "yes" for a current approval.
- **Schemas and templates** for projects, decisions, preferences, entities, sessions, authorizations, action logs and reports.
- **Workflows** for answering, acting, session handling, conversation ingestion, and daily, weekly and monthly maintenance.
- **Agent conventions:** a file-based handoff between roles (`Handover/`), log notes with a nine-field receipt, and a preflight that tells an agent when the rule files changed.

## How to adopt it

Prefer to let an agent do it? Paste the prompt in [INSTALL_WITH_AGENT.md](INSTALL_WITH_AGENT.md) into your coding agent. That file lives in the Yorozu repository ([view on GitHub](https://github.com/izyuumi/yorozu/blob/main/examples/paios/INSTALL_WITH_AGENT.md)) and is not copied into the install.

Already using an agent? PAIOS can start from what it already knows: after installing, paste the prompt in [IMPORT_HISTORY.md](IMPORT_HISTORY.md) into it.

### One command

`<folder>` is the folder to create `PAIOS/` in. Any folder works: your home folder, a notes folder, a synced folder.

```bash
curl -fsSL https://raw.githubusercontent.com/izyuumi/yorozu/main/examples/paios/install.sh | bash -s -- "/path/to/your folder"
```

Or from a checkout of this repository:

```bash
bash examples/paios/install.sh "/path/to/your folder"
```

The folder must already exist; the script does not create it. The script copies this folder into `<folder>/PAIOS`, writes `PAIOS/paios.env` with your folder path and time zone, and runs the self-test. If `<folder>/PAIOS` already exists it refuses and changes nothing; it never overwrites or merges. Without a path, it asks for one when run on a terminal (`~` means your home folder). Agents may read that parent folder; see `System/Policies/Vault Boundary.md`. It needs bash and Python 3.9+, plus curl and tar when not run from a checkout. When it finishes it prints the next steps: load the variables with `source "<folder>/PAIOS/paios.env"`, then steps 3 to 6 below.

Options:

- `--tz <zone>`: your IANA time zone, e.g. `--tz Europe/Berlin`. Default: `PAIOS_TZ` if set, else the system zone, else UTC.
- `--ref <ref>` or `PAIOS_REF`: the branch, tag or commit to fetch when the script is not run from a checkout. Default: `main`.
- `PAIOS_REPO`: `owner/name` of a fork to fetch from. Default: `izyuumi/yorozu`.
- `-h`: show the help.

You can read the script before running it:

```bash
curl -fsSL https://raw.githubusercontent.com/izyuumi/yorozu/main/examples/paios/install.sh -o install.sh
less install.sh
bash install.sh "/path/to/your folder"
```

The script itself comes from `main`. Add `--ref <commit>` to pin the files it installs to that commit.

### No script

This needs Node.js.

```bash
npx degit izyuumi/yorozu/examples/paios "/path/to/your folder/PAIOS"
```

Then delete `install.sh` and `INSTALL_WITH_AGENT.md` from the copy and follow the steps below from step 2.

### By hand

1. Copy this folder into a folder of your choice and name it `PAIOS`:
   ```bash
   cp -R examples/paios "/path/to/your folder/PAIOS"
   ```
   Then delete `PAIOS/install.sh` and `PAIOS/INSTALL_WITH_AGENT.md`.
2. Set the environment variables your agents and scripts use (see `paios.env.example`):
   ```bash
   export PAIOS_ROOT="/path/to/your folder"   # the folder that contains PAIOS/
   export PAIOS_VAULT="$PAIOS_ROOT"            # older name for PAIOS_ROOT; older scripts still read it
   export PAIOS_TZ="UTC"                       # your IANA time zone, e.g. Europe/Berlin
   ```
   Or copy `paios.env.example` to `paios.env`, fill it in and `source` it.
3. Point your agent at it. Give it `System/Prompts/Agent Master Prompt.md` as its system prompt, or tell it to start with `AGENTS.md`.
4. Read `System/Constitution.md` and change what doesn't fit you. Add your own amendments as dated, numbered sub-principles.
5. Replace the example files (`Runtime/Now.md`, `Projects/Example Project.md`, `Execution/Queue.md`, and so on) with your own, or delete them.
6. Optional: let your agent fill PAIOS from the history it can already read (its memory files, instruction files and past sessions) with the prompt in [IMPORT_HISTORY.md](IMPORT_HISTORY.md). It asks first, shows you a review list, and writes only what you approve.
7. Optional: import whole conversation databases with a separate importer of your choice. `System/Prompts/Bootstrap Directive.md` describes a safe import (read-only, dry run first, redact before writing, never replay old actions). This example ships no importer; step 6 needs none.
8. Optional: if you run several agents, rename the roles in `Handover/README.md` and set `HANDOFF_ROLES`.

## Folder map

| Folder | What goes there |
|---|---|
| `System/` | Stable rules and operating design: Constitution, architecture, policies, workflows, schemas, templates, prompts, SOPs, scripts. |
| `docs/` | Optional guides. |
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

The scripts under `System/Scripts/` are standard-library Python 3.9+ or bash, take paths from environment variables, and make no network requests. `install.sh` takes the folder path as an argument and, when not run from a checkout, downloads this repository's tarball from GitHub.

| Script | What it does |
|---|---|
| `System/Scripts/paios-log/paios-log.py` | Writes `Execution/Logs/YYYY-MM-DD <agent> <topic>.md` with the nine receipt fields. Refuses secret-looking text; never overwrites. |
| `System/Scripts/paios-log/log-receipt-check.sh` | Checks that every log note has a full receipt. Prints `CHECK PASS` or `CHECK FAIL`. |
| `System/Scripts/vault-preflight/preflight.sh` + `compare.py` | Tells an agent whether the PAIOS folder is reachable and which rule files changed since it last read them. |
| `System/Scripts/handoff/handoff.py` | Writes, claims, closes and checks handoff files in `Handover/`. |
| `System/Scripts/selftest.sh` | Runs all of the above against a temporary copy and prints `SELFTEST PASS`. |
| `install.sh` | Copies this folder into `<folder>/PAIOS`, writes `paios.env` and runs the self-test. Refuses if `PAIOS` already exists. The installer leaves itself and `INSTALL_WITH_AGENT.md` out of the copy. |

| Variable | Used by | Default |
|---|---|---|
| `PAIOS_ROOT` | all scripts | none; the folder that contains `PAIOS/` |
| `PAIOS_VAULT` | all scripts | older name for `PAIOS_ROOT`, read only when `PAIOS_ROOT` is not set; existing installs keep working |
| `PAIOS_TZ` | dates and timestamps | `UTC` |
| `PAIOS_LOGS` | paios-log | `$PAIOS_ROOT/PAIOS/Execution/Logs` (`$PAIOS_VAULT` still valid) |
| `HANDOFF_ROOT` | handoff | `$PAIOS_ROOT/PAIOS/Handover` (`$PAIOS_VAULT` still valid) |
| `HANDOFF_ROLES` | handoff | `chief-of-staff,coder,product-owner` |
| `PAIOS_PREFLIGHT_STATE` | vault-preflight | `state/` next to `compare.py` |
| `PAIOS_REF` | `install.sh`, when not run from a checkout: the ref to fetch | `main` |
| `PAIOS_REPO` | `install.sh`: the `owner/name` to fetch | `izyuumi/yorozu` |

## Privacy

Keep your own copy private. The rules tell agents never to store secrets and to redact high-risk identifiers, but your PAIOS folder will still hold personal context. Don't commit a filled-in copy to a public repository.

## License

Same as the rest of this repository (MIT, see the root `LICENSE`).
