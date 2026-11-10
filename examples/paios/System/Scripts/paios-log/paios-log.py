#!/usr/bin/env python3
"""Write a PAIOS log note: "<Logs>/YYYY-MM-DD <Agent> <topic>.md" with a run receipt.

  paios-log.py --bot "coder" --topic "example task" --receipt receipt.json [--body-file notes.md] [--logs-dir DIR] [--dry-run]

receipt.json holds the nine receipt fields: request, context_used, tools_used, checks, retries,
user_corrections, result, rollback, lesson. Every field is required ("none" is a fine value).
Refuses secret-looking text and never overwrites: an existing note gets " (2)", " (3)" and so on.
Logs folder: --logs-dir, else $PAIOS_LOGS, else $PAIOS_VAULT/PAIOS/Execution/Logs. Dates use $PAIOS_TZ (default UTC).
Exit 0 written (or dry run ok), 1 refused, 2 usage error.
"""
import argparse, json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
from secrets_scan import scan
from paios_env import now, vault_path

FIELDS = ["request", "context_used", "tools_used", "checks", "retries", "user_corrections", "result", "rollback", "lesson"]
LOGS = os.environ.get("PAIOS_LOGS") or vault_path("Execution", "Logs")

def render(bot, topic, receipt, body, date):
    lines = ["---", f"date: {date}", f"bot: {bot}", "type: execution-log", "---", f"# {date} {bot} {topic}", ""]
    if body.strip():
        lines += [body.strip(), ""]
    lines += ["## Receipt", ""]
    lines += [f"- {k}: {str(receipt[k]).strip()}" for k in FIELDS]
    return "\n".join(lines) + "\n"

def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--bot", required=True, help="agent or role name, e.g. coder")
    p.add_argument("--topic", required=True)
    p.add_argument("--receipt", required=True)
    p.add_argument("--body-file")
    p.add_argument("--logs-dir", default=LOGS)
    p.add_argument("--date", help="YYYY-MM-DD, default today in $PAIOS_TZ")
    p.add_argument("--dry-run", action="store_true")
    a = p.parse_args(argv)
    if not a.logs_dir:
        print("usage: set --logs-dir, PAIOS_LOGS or PAIOS_VAULT"); return 2
    if re.search(r"[/\\:]", a.topic) or re.search(r"[/\\:]", a.bot):
        print("REFUSED: bot and topic may not contain / \\ or :"); return 1
    receipt = json.load(open(a.receipt, encoding="utf-8"))
    missing = [k for k in FIELDS if not str(receipt.get(k, "")).strip()]
    if missing:
        print("REFUSED: receipt is missing " + ", ".join(missing)); return 1
    body = open(a.body_file, encoding="utf-8").read() if a.body_file else ""
    date = a.date or now().strftime("%Y-%m-%d")
    text = render(a.bot, a.topic, receipt, body, date)
    hits = scan(text)
    if hits:
        print("REFUSED: secret-looking content: " + ", ".join(f"line {n} {l}" for n, l in hits)); return 1
    base = os.path.join(a.logs_dir, f"{date} {a.bot} {a.topic}")
    path, i = base + ".md", 2
    while os.path.exists(path):
        path, i = f"{base} ({i}).md", i + 1
    if a.dry_run:
        print(f"DRY RUN would write {path}"); print(text); return 0
    if not os.path.isdir(a.logs_dir):
        print(f"REFUSED: no such Logs folder: {a.logs_dir} (run vault-preflight)"); return 1
    tmp = path + ".tmp"
    open(tmp, "w", encoding="utf-8").write(text)
    os.rename(tmp, path)
    print(path)
    return 0

if __name__ == "__main__":
    sys.exit(main())
