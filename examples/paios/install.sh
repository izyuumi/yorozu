#!/bin/bash
# Installs the PAIOS example vault into an existing Obsidian vault as <vault>/PAIOS,
# writes <vault>/PAIOS/paios.env and runs the self-test. Never overwrites or merges.
#
# From a checkout:
#   bash examples/paios/install.sh "/path/to/your vault"
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/izyuumi/yorozu/main/examples/paios/install.sh | bash -s -- "/path/to/your vault"
#
# Exit codes: 0 installed, 1 refused or failed, 2 usage error.
set -euo pipefail
unset CDPATH

# Read at top level: inside a function, a piped bash 5 reports the bash binary here.
script_path="${BASH_SOURCE[0]:-}"
tmp=""
dest=""
created=0

usage() {
  cat <<'U'
Usage: install.sh [--tz <IANA zone>] [--ref <git ref>] [--] [<vault path>]

Copies the PAIOS example into "<vault path>/PAIOS", writes paios.env there and
runs the self-test. Refuses if "<vault path>/PAIOS" already exists.
The vault folder must already exist. Without a path, the script asks for one when run on a terminal.

  --tz <zone>   IANA time zone, e.g. Europe/Berlin
                (default: $PAIOS_TZ, else the system zone, else UTC)
  --ref <ref>   branch, tag or commit to fetch (default: $PAIOS_REF, else main);
                only used when the script is not run from a checkout
  -h, --help    show this help

Environment: PAIOS_TZ, PAIOS_REF, PAIOS_REPO (owner/name of a fork; default izyuumi/yorozu).
U
}

die() { printf 'install.sh: %s\n' "$1" >&2; exit 1; }
usage_error() { printf 'install.sh: %s\n\n' "$1" >&2; usage >&2; exit 2; }

cleanup() {
  if [ -n "$tmp" ]; then rm -rf -- "$tmp" || true; fi
  # Only ever removes the PAIOS folder this run created.
  if [ "$created" = 1 ] && [ -n "$dest" ]; then
    printf 'install.sh: removing %s\n' "$dest" >&2
    rm -rf -- "$dest"
  fi
}
trap cleanup EXIT

valid_tz() {
  [ -n "$1" ] && python3 -c 'import sys,zoneinfo; zoneinfo.ZoneInfo(sys.argv[1])' "$1" 2>/dev/null
}

# Prints the first valid candidate; fails if there is none.
system_tz() {
  local env_tz="${TZ:-}" file_tz="" link link_tz="" z
  env_tz="${env_tz#:}"
  if [ -r /etc/timezone ]; then IFS= read -r file_tz </etc/timezone || true; fi
  link="$(readlink /etc/localtime 2>/dev/null || true)"
  case "$link" in *zoneinfo/*) link_tz="${link##*zoneinfo/}" ;; esac
  for z in "$env_tz" "$file_tz" "$link_tz"; do
    if valid_tz "$z"; then printf '%s' "$z"; return 0; fi
  done
  return 1
}

refuse() {
  printf 'install.sh: Refusing: %s already exists. The installer never overwrites or merges. Move it aside or pick another vault.\n' "$dest" >&2
  exit 1
}

main() {
  local tz_arg="" ref_arg="" vault="" have_vault=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --tz|--ref)
        [ $# -ge 2 ] || usage_error "$1 needs a value"
        if [ "$1" = --tz ]; then tz_arg="$2"; else ref_arg="$2"; fi
        shift 2 ;;
      --tz=*) tz_arg="${1#--tz=}"; shift ;;
      --ref=*) ref_arg="${1#--ref=}"; shift ;;
      -f|--force) usage_error "--force is not supported: the installer never overwrites an existing PAIOS folder" ;;
      --) shift; break ;;
      -*) usage_error "unknown option: $1" ;;
      *) [ "$have_vault" = 0 ] || usage_error "more than one vault path given"
         vault="$1"; have_vault=1; shift ;;
    esac
  done
  if [ $# -gt 0 ]; then
    { [ "$have_vault" = 0 ] && [ $# -eq 1 ]; } || usage_error "more than one vault path given"
    vault="$1"; have_vault=1
  fi

  # Piped through `curl | bash`, stdin is this script, so ask on the terminal instead.
  if [ "$have_vault" = 0 ]; then
    if [ -t 2 ] && { : </dev/tty; } 2>/dev/null; then
      printf 'Vault path (the folder that will contain PAIOS/): ' >&2
      IFS= read -r vault </dev/tty || vault=""
      case "$vault" in \~) vault="$HOME" ;; \~/*) vault="$HOME/${vault#\~/}" ;; esac
    else
      usage_error "no vault path given"
    fi
  fi
  [ -n "$vault" ] || usage_error "no vault path given"

  command -v python3 >/dev/null 2>&1 || die "Python 3.9 or newer is required; python3 was not found"
  python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
    || die "Python 3.9 or newer is required; found $(python3 -V 2>&1)"

  [ -d "$vault" ] || die "not a folder: $vault (create it or open it in Obsidian first)"
  vault="$(cd -- "$vault" && pwd -P)"

  # Refuse before downloading anything; the mkdir further down is what claims the folder.
  dest="$vault/PAIOS"
  if [ -e "$dest" ] || [ -L "$dest" ]; then refuse; fi

  local tz
  if [ -n "$tz_arg" ]; then
    valid_tz "$tz_arg" || usage_error "--tz: not an IANA time zone: $tz_arg"
    tz="$tz_arg"
  elif [ -n "${PAIOS_TZ:-}" ]; then
    valid_tz "$PAIOS_TZ" || usage_error "PAIOS_TZ: not an IANA time zone: $PAIOS_TZ"
    tz="$PAIOS_TZ"
  elif ! tz="$(system_tz)"; then
    echo "Note: could not detect the system time zone; using UTC. To change it, edit PAIOS_TZ in $dest/paios.env."
    tz="UTC"
  fi

  # Source: this script's own folder when run from a checkout, else a download.
  local src="" here
  if [ -f "$script_path" ] && [ "$(basename -- "$script_path")" = install.sh ]; then
    here="$(cd -- "$(dirname -- "$script_path")" && pwd -P)"
    if [ -f "$here/AGENTS.md" ] && [ -f "$here/System/Scripts/selftest.sh" ]; then src="$here"; fi
  fi
  if [ -n "$src" ]; then
    [ -z "$ref_arg" ] || echo "Note: --ref is ignored when installing from a checkout."
  else
    local ref="${ref_arg:-${PAIOS_REF:-main}}" repo="${PAIOS_REPO:-izyuumi/yorozu}"
    local ref_re='^[A-Za-z0-9._/-]+$' repo_re='^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
    { [[ "$ref" =~ $ref_re ]] && [[ "$ref" != *..* ]]; } || usage_error "not a valid git ref: $ref"
    [[ "$repo" =~ $repo_re ]] || usage_error "PAIOS_REPO must be owner/name: $repo"
    command -v curl >/dev/null 2>&1 || die "curl is required to download PAIOS"
    command -v tar >/dev/null 2>&1 || die "tar is required to unpack the download"
    tmp="$(mktemp -d)"
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 --retry 2 --connect-timeout 20 \
      -o "$tmp/src.tar.gz" "https://codeload.github.com/$repo/tar.gz/$ref" \
      || die "could not download $repo at $ref"
    mkdir "$tmp/x"
    # GNU tar needs --wildcards for the pattern; bsdtar (macOS) matches it as is and rejects the flag.
    case "$(tar --version 2>/dev/null || true)" in
      *'GNU tar'*)
        tar -xzf "$tmp/src.tar.gz" -C "$tmp/x" --no-same-owner --wildcards '*/examples/paios/*' \
          || die "could not extract examples/paios from $repo at $ref" ;;
      *)
        tar -xzf "$tmp/src.tar.gz" -C "$tmp/x" --no-same-owner '*/examples/paios/*' \
          || die "could not extract examples/paios from $repo at $ref" ;;
    esac
    set -- "$tmp"/x/*/examples/paios
    { [ $# -eq 1 ] && [ -f "$1/AGENTS.md" ] && [ -f "$1/System/Scripts/selftest.sh" ]; } \
      || die "$repo at $ref has no examples/paios folder"
    src="$1"
    echo "Fetched $repo@$ref"
  fi

  # Claim the folder with a plain mkdir, so two runs can't both win and nothing existing is touched.
  mkdir "$dest" 2>/dev/null || {
    if [ -e "$dest" ] || [ -L "$dest" ]; then refuse; fi
    die "could not create $dest (check that the vault folder is writable)"
  }
  created=1

  cp -R "$src/." "$dest/"
  rm -f "$dest/install.sh" "$dest/paios.env" "$dest/INSTALL_WITH_AGENT.md"
  # Junk a checkout may hold.
  find "$dest" -name __pycache__ -type d -prune -exec rm -rf {} +
  find "$dest" \( -name '*.pyc' -o -name .DS_Store \) -type f -exec rm -f {} +
  rm -rf "$dest/System/Scripts/vault-preflight/state"

  python3 - "$dest/paios.env.example" "$dest/paios.env" "$vault" "$tz" <<'PY'
import sys
example, out, vault, tz = sys.argv[1:5]
quote = lambda s: "'" + s.replace("'", "'\\''") + "'"
values = {"PAIOS_VAULT": vault, "PAIOS_TZ": tz}
with open(example, encoding="utf-8") as f:
    lines = f.read().splitlines()
for i, line in enumerate(lines):
    name = line.strip()
    if name.startswith("export "):
        name = name[len("export "):]
    key = name.split("=", 1)[0].strip()
    if key in values:
        lines[i] = "export " + key + "=" + quote(values.pop(key))
lines += ["export " + key + "=" + quote(value) for key, value in values.items()]
with open(out, "w", encoding="utf-8", errors="surrogateescape") as f:
    f.write("\n".join(lines) + "\n")
PY
  # Read back from a child process, so the values must be exported.
  # shellcheck disable=SC1091,SC2016
  ( set +u; unset PAIOS_VAULT PAIOS_TZ; . "$dest/paios.env"
    "$BASH" -c '[ "$PAIOS_VAULT" = "$1" ] && [ "$PAIOS_TZ" = "$2" ]' _ "$vault" "$tz" ) \
    || die "the written paios.env does not export the expected vault path and time zone"

  # The self-test works on its own temporary copy and changes nothing in $dest.
  local out rc=0
  out="$(PAIOS_TZ="$tz" "$BASH" "$dest/System/Scripts/selftest.sh" </dev/null 2>&1)" || rc=$?
  printf '%s\n' "$out"
  case "$out" in *'SELFTEST PASS'*) ;; *) rc=1 ;; esac
  [ "$rc" -eq 0 ] || die "self-test failed"
  created=0

  printf '\nInstalled PAIOS into %s\nTime zone: %s\n\nNext steps:\n' "$dest" "$tz"
  printf '  1. source %q\n' "$dest/paios.env"
  printf '     (exports PAIOS_VAULT and PAIOS_TZ; add the line to your shell profile or the agent'"'"'s environment)\n'
  printf '  2. Tell your agent to start with %s\n' "$dest/AGENTS.md"
  printf '     (or give it System/Prompts/Agent Master Prompt.md as the system prompt)\n'
  printf '  3. Read System/Constitution.md and change what doesn'"'"'t fit.\n'
  printf '  4. Replace or delete the example files (Runtime/Now.md, Projects/Example Project.md, Execution/Queue.md, and so on).\n'
}

# Called last, so a download cut off halfway runs nothing.
main "$@"
