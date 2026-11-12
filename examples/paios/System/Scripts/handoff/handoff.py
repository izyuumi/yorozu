#!/usr/bin/env python3
"""Handoff files between agents in $HANDOFF_ROOT (see PAIOS/Handover/README.md).

  handoff.py new   --from chief-of-staff --to coder --slug example-task --ask "..." --done-when "..." --reply-to <path|slug> [--body-file F | stdin]
  handoff.py claim <file> --by <slug>
  handoff.py done  <file> --by <slug> --result "..."
  handoff.py check [file ...]       (no files: every file under inbox/ and done/, plus a secret scan of transfers/)

Settings (environment):
  HANDOFF_ROOT   handoff folder (default: $PAIOS_ROOT/PAIOS/Handover; $PAIOS_VAULT is the older name for PAIOS_ROOT)
  HANDOFF_ROLES  comma-separated role slugs (default: chief-of-staff,coder,product-owner)
  PAIOS_TZ       time zone for file names and stamps (default: UTC)

Exit 0 ok, 1 a check failed, 2 usage error. Never prints file bodies, only paths and line numbers.
"""
import argparse, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from secrets_scan import scan
from paios_env import now, vault_path

ROOT = os.environ.get("HANDOFF_ROOT") or vault_path("Handover")
SLUGS = [s.strip() for s in os.environ.get("HANDOFF_ROLES", "chief-of-staff,coder,product-owner").split(",") if s.strip()]
FIELDS = ["from", "to", "ask", "done_when", "reply_to"]
NAME = re.compile(r"^(\d{8})-(\d{4})-([a-z0-9-]+?)-([a-z0-9][a-z0-9-]*)\.md$")

def header_errors(text):
    lines = text.splitlines()
    errs = []
    if len(lines) < 5:
        return ["header: fewer than 5 lines"], {}
    vals = {}
    for i, f in enumerate(FIELDS):
        m = re.match(rf"^{f}:\s*(.*\S)\s*$", lines[i])
        if not m:
            errs.append(f"header line {i+1}: expected '{f}: <value>'")
        else:
            vals[f] = m.group(1)
    for f in ("from", "to"):
        if f in vals and vals[f] not in SLUGS:
            errs.append(f"header {f}: '{vals[f]}' is not a role slug")
    return errs, vals

def file_errors(path):
    text = open(path, encoding="utf-8").read()
    errs, vals = header_errors(text)
    name = os.path.basename(path)
    m = NAME.match(name)
    if not m:
        errs.append("name: expected YYYYMMDD-HHMM-<from>-<slug>.md")
    elif vals.get("from") and not name[14:].startswith(vals["from"] + "-"):
        errs.append(f"name: <from> part does not match header from '{vals['from']}'")
    folder = os.path.basename(os.path.dirname(path))
    if vals.get("to") and folder in SLUGS and folder != vals["to"]:
        errs.append(f"folder: file is in '{folder}/' but header to is '{vals['to']}'")
    errs += [f"secret-looking {label} on line {n}" for n, label in scan(text)]
    return errs

def cmd_new(a):
    for f in ("from_", "to"):
        if getattr(a, f) not in SLUGS:
            sys.exit(f"not a role slug: {getattr(a, f)}")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", a.slug):
        sys.exit("slug must be lowercase letters, digits and hyphens")
    body = open(a.body_file, encoding="utf-8").read() if a.body_file else ("" if sys.stdin.isatty() else sys.stdin.read())
    head = [f"from: {a.from_}", f"to: {a.to}", f"ask: {a.ask}", f"done_when: {a.done_when}", f"reply_to: {a.reply_to}"]
    text = "\n".join(head) + "\n\n" + body.strip() + "\n"
    hits = scan(text)
    if hits:
        print("REFUSED: secret-looking content: " + ", ".join(f"line {n} {l}" for n, l in hits))
        return 1
    d = os.path.join(ROOT, "inbox", a.to)
    os.makedirs(d, exist_ok=True)
    name = f"{now():%Y%m%d-%H%M}-{a.from_}-{a.slug}.md"
    path = os.path.join(d, name)
    if os.path.exists(path):
        sys.exit(f"exists already: {path}")
    tmp = path + ".tmp"
    open(tmp, "w", encoding="utf-8").write(text)
    os.rename(tmp, path)
    print(path)
    print(f"Tell the receiver: handoff for you: {path}")
    return 0

def _owned(path, by):
    errs = file_errors(path)
    if errs:
        print("\n".join(f"FAIL {path}: {e}" for e in errs)); return None
    to = open(path, encoding="utf-8").read().splitlines()[1].split(":", 1)[1].strip()
    if to != by:
        print(f"FAIL {path}: addressed to {to}, not {by}"); return None
    return to

def cmd_claim(a):
    if _owned(a.file, a.by) is None:
        return 1
    with open(a.file, "a", encoding="utf-8") as fh:
        fh.write(f"\nclaimed: {now():%Y-%m-%d %H:%M} by {a.by}\n")
    print(f"claimed {a.file}")
    return 0

def cmd_done(a):
    to = _owned(a.file, a.by)
    if to is None:
        return 1
    if scan(a.result):
        print("REFUSED: secret-looking content in --result"); return 1
    with open(a.file, "a", encoding="utf-8") as fh:
        fh.write(f"\ndone: {now():%Y-%m-%d %H:%M} by {a.by}\nresult: {a.result}\n")
    d = os.path.join(ROOT, "done", to)
    os.makedirs(d, exist_ok=True)
    dest = os.path.join(d, os.path.basename(a.file))
    if os.path.exists(dest):
        sys.exit(f"exists already: {dest}")
    os.rename(a.file, dest)
    print(dest)
    return 0

def cmd_check(a):
    files = a.files
    if not files:
        files = []
        for sub in ("inbox", "done"):
            for dp, _, fs in os.walk(os.path.join(ROOT, sub)):
                files += [os.path.join(dp, f) for f in fs if f.endswith(".md")]
    bad = 0
    for p in sorted(files):
        errs = file_errors(p)
        for e in errs:
            print(f"FAIL {p}: {e}")
        bad += bool(errs)
    if not a.files:
        for dp, _, fs in os.walk(os.path.join(ROOT, "transfers")):
            for f in fs:
                p = os.path.join(dp, f)
                for n, l in scan(open(p, encoding="utf-8", errors="replace").read()):
                    print(f"FAIL {p}: secret-looking {l} on line {n}"); bad += 1
    print(f"{len(files)} handoff files checked")
    print("CHECK PASS" if bad == 0 else "CHECK FAIL")
    return 0 if bad == 0 else 1

def main(argv=None):
    if not ROOT:
        print("usage: set HANDOFF_ROOT or PAIOS_ROOT"); return 2
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    s = p.add_subparsers(dest="cmd", required=True)
    n = s.add_parser("new")
    n.add_argument("--from", dest="from_", required=True)
    for f in ("to", "slug", "ask", "done-when", "reply-to"):
        n.add_argument(f"--{f}", required=True)
    n.add_argument("--body-file")
    c = s.add_parser("claim"); c.add_argument("file"); c.add_argument("--by", required=True)
    d = s.add_parser("done"); d.add_argument("file"); d.add_argument("--by", required=True); d.add_argument("--result", required=True)
    k = s.add_parser("check"); k.add_argument("files", nargs="*")
    a = p.parse_args(argv)
    return {"new": cmd_new, "claim": cmd_claim, "done": cmd_done, "check": cmd_check}[a.cmd](a)

if __name__ == "__main__":
    sys.exit(main())
