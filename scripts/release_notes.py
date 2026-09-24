#!/usr/bin/env python3
"""Complete release notes from the candidate's exact Git history, using stdlib only."""

import re
import subprocess

CONVENTIONAL = re.compile(r"(?P<type>[^\s():!]+)(?:\((?P<scope>[^()\r\n]+)\))?(?P<breaking>!)?: (?P<description>\S.*)")
STABLE_TAG = re.compile(r"v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")
TRAILER = re.compile(r"(?:[A-Za-z][A-Za-z0-9-]*|BREAKING CHANGE)(?::\s| #)")
SECTIONS = {
    "feat": "Features", "fix": "Bug Fixes", "perf": "Performance", "refactor": "Refactoring",
    "docs": "Documentation", "build": "Build", "ci": "Continuous Integration", "test": "Tests",
    "style": "Style", "chore": "Maintenance", "revert": "Reverts",
}


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def ancestor(base, source):
    result = subprocess.run(["git", "merge-base", "--is-ancestor", base, source], check=False)
    if result.returncode not in (0, 1):
        raise RuntimeError("cannot inspect release ancestry; fetch complete Git history and tags")
    return result.returncode == 0


def stable_base(gh, release_version, source):
    """Choose a published stable ancestor, ignoring drafts, beta builds, and other trains."""
    target = tuple(map(int, release_version.split(".")))
    pages = gh.api("releases?per_page=100", "--paginate", "--slurp")
    candidates = []
    for page in pages:
        for release in page:
            match = STABLE_TAG.fullmatch(release["tag_name"])
            if not match or release["draft"] or release["prerelease"]:
                continue
            train = tuple(map(int, match.groups()))
            if train < target:
                candidates.append((train, release["tag_name"]))
    for _, tag in sorted(candidates, reverse=True):
        sha = gh.tag_sha(tag)
        if not sha:
            raise ValueError(f"published stable release has no tag: {tag}")
        if ancestor(sha, source):
            return sha
    return None


def escape(text):
    # Commit text is data: keep Markdown/HTML and mentions from altering the notes.
    return re.sub(r"([\\`*_{}\[\]()<>#!|])", r"\\\1", text).replace("@", "@\u200b")


def breaking_notes(message):
    lines = message.splitlines()[1:]
    notes = []
    index = 0
    while index < len(lines):
        match = re.match(r"BREAKING(?: CHANGE|-CHANGE): (\S.*)", lines[index])
        index += 1
        if not match:
            continue
        detail = [match[1]]
        while index < len(lines) and not TRAILER.match(lines[index]):
            detail.append(lines[index])
            index += 1
        notes.append(" ".join(" ".join(detail).split()))
    return notes


def render_notes(repo, release_version, source, base=None):
    """Include each actual commit once; merge wrappers don't repeat their PR titles."""
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("invalid GitHub repository")
    for sha in (source, base):
        if sha is not None and not re.fullmatch(r"[a-f0-9]{40}", sha):
            raise ValueError("release notes require full commit SHAs")
    if base and not ancestor(base, source):
        raise ValueError("release notes base must be an ancestor of the candidate")
    revision = f"{base}..{source}" if base else source
    raw = git("log", "--reverse", "--topo-order", "-z", "--format=%H%x00%P%x00%B", revision)
    fields = raw.split("\0")
    if fields[-1] == "":
        fields.pop()
    if len(fields) % 3:
        raise ValueError("invalid Git commit record while generating release notes")
    grouped = {name: [] for name in ["Breaking Changes", *SECTIONS.values(), "Other Changes"]}
    for index in range(0, len(fields), 3):
        sha, parents, message = fields[index:index + 3]
        subject = message.splitlines()[0]
        # GitHub merge commits repeat the PR title in their body. Parse only subjects.
        if len(parents.split()) > 1 and re.match(r"Merge (?:pull request|branch|remote-tracking branch|tag)\b", subject):
            continue
        match = CONVENTIONAL.fullmatch(subject)
        details = breaking_notes(message)
        if match:
            kind = match["type"].lower()
            section = SECTIONS.get(kind, "Other Changes")
            label = escape(match["description"])
            if match["scope"]:
                label = f"**{escape(match['scope'])}:** {label}"
            if kind not in SECTIONS:
                label = f"{escape(match['type'])}: {label}"
            if match["breaking"] or details:
                section = "Breaking Changes"
        else:
            section, label = "Other Changes", escape(subject)
        if details:
            label += " — **Breaking:** " + escape("; ".join(details))
        grouped[section].append(f"- {label} ([{sha[:7]}](https://github.com/{repo}/commit/{sha}))")
    lines = [f"## Changes in {release_version}"]
    for section, entries in grouped.items():
        if entries:
            lines += ["", f"### {section}", "", *entries]
    if not any(grouped.values()):
        lines += ["", "No source changes since the previous stable release."]
    compare = f"compare/{base}...{source}" if base else f"commits/{source}"
    lines += ["", f"**Full history:** https://github.com/{repo}/{compare}"]
    return "\n".join(lines) + "\n"


def generate_release_notes(gh, release_version, source):
    return render_notes(gh.repo, release_version, source, stable_base(gh, release_version, source))
