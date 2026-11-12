#!/usr/bin/env python3
"""vault-preflight (agent side). Feed it the preflight.sh JSON on stdin (or --offline).

  preflight.sh | compare.py --bot <agent name>
  compare.py --offline --bot <agent name>

Prints one line for the agent and remembers hashes per agent in
$PAIOS_PREFLIGHT_STATE (default: ./state next to this script) so the agent
re-reads the PAIOS rule files only when they changed.
Exit 0 ok, 1 check failed, 3 offline.
"""
import argparse, json, os, sys
ap = argparse.ArgumentParser(); ap.add_argument("--bot", required=True); ap.add_argument("--offline", action="store_true")
ap.add_argument("--state-dir", default=os.environ.get("PAIOS_PREFLIGHT_STATE") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "state"))
a = ap.parse_args()
if a.offline:
    print("VAULT OFFLINE: the vault host is not reachable. Stop vault work and tell the owner in one line."); sys.exit(3)
try:
    cur = json.loads(sys.stdin.read())
except Exception:
    print("VAULT CHECK FAILED: preflight output was not JSON"); sys.exit(1)
if not cur.get("ok"):
    print("VAULT CHECK FAILED: " + str(cur.get("error"))); sys.exit(1)
os.makedirs(a.state_dir, exist_ok=True)
sp = os.path.join(a.state_dir, a.bot + ".json")
old = json.load(open(sp)) if os.path.exists(sp) else {"files": {}}
changed = [k for k, v in cur["files"].items() if v and (old["files"].get(k) or {}).get("sha256_16") != v["sha256_16"]]
json.dump(cur, open(sp, "w"), ensure_ascii=False, indent=1)
if changed:
    print("VAULT OK %s. RE-READ (changed since last run): %s" % (cur["now"], ", ".join(changed)))
else:
    print("VAULT OK %s. Rule files unchanged; no re-read needed." % cur["now"])
