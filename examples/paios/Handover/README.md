# Handover: roles and handoff rules

A file-based way for several agents (or several roles of one agent) to pass work to each other. One owner per noun: if two roles could do it, the table decides.

## Roles

These are example roles. Rename or add your own, and list the slugs in `HANDOFF_ROLES`.

| Role | Slug | Owns | Does not do |
|---|---|---|---|
| Chief of staff | chief-of-staff | the master task list, routing, daily brief, chasing stalled work | specialist work, code |
| Coder | coder | repositories, pull requests, builds and tests | product decisions, releases without a go-ahead |
| Product owner | product-owner | roadmap, specs, release decisions | writing code (goes to coder) |

## Layout

```
Handover/
  README.md                      this file
  inbox/<slug>/                  work waiting for that role
    YYYYMMDD-HHMM-<from>-<slug>.md
  done/<slug>/                   the same file, moved after the work closes (never deleted)
  transfers/<from>-to-<to>.md    lane handovers between roles
```

Set `HANDOFF_ROOT` if you keep this folder outside your PAIOS folder.

## The five-line header

Every handoff file starts with these five lines, in this order:

```
from: <slug of the sender>
to: <slug of the receiver>
ask: <one sentence>
done_when: <a check the receiver can run>
reply_to: <run state file path, or a role slug>
```

`System/Scripts/handoff/handoff.py` writes and checks it:

```bash
handoff.py new   --from chief-of-staff --to coder --slug example-task --ask "..." --done-when "..." --reply-to chief-of-staff --body-file notes.md
handoff.py claim Handover/inbox/coder/<file>.md --by coder
handoff.py done  Handover/inbox/coder/<file>.md --by coder --result "<link or outcome>"
handoff.py check
```

## Rules

- Never delete a handoff file; close it with `done`, which moves it to `done/<slug>/`.
- Never edit another role's open inbox file; write a new handoff instead.
- Never put passwords, PINs, API or webhook keys, account or card numbers, or mailbox contents in a handoff. Point to where the thing lives. `handoff.py` refuses secret-looking text.
