"""Secret-looking strings that must never sit in a shared file. Used by paios-log.py and handoff.py."""
import re

PATTERNS = [
    ("private key", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("AWS key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("GitHub token", re.compile(r"\b(ghp|gho|ghs|ghu)_[A-Za-z0-9]{30,}\b|\bgithub_pat_[A-Za-z0-9_]{30,}")),
    ("API key", re.compile(r"\bsk-[A-Za-z0-9_-]{20,}")),
    ("Slack token", re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("JWT", re.compile(r"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}")),
    ("bearer token", re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{20,}")),
    ("password value", re.compile(r"(?i)\b(password|passwd|passcode|パスワード)\s*[:=：]\s*\S+")),
    ("PIN value", re.compile(r"(?i)(\bPIN\b|暗証番号)\s*[:=：]?\s*\d{4,}")),
    ("account number", re.compile(r"(口座番号|account\s*(no|number|#))\s*[:=：]?\s*\d[\d -]{5,}", re.I)),
    ("webhook key", re.compile(r"(?i)\b(webhook|sender)[_ -]?(key|secret|token)\s*[:=：]\s*\S{12,}")),
]

def _luhn(digits):
    s, alt = 0, False
    for ch in reversed(digits):
        d = int(ch)
        if alt:
            d *= 2
            if d > 9:
                d -= 9
        s += d
        alt = not alt
    return s % 10 == 0

CARD = re.compile(r"(?<!\d)(?:\d[ -]?){13,19}(?!\d)")

def scan(text):
    """Return a list of (line_no, label) for every secret-looking string."""
    hits = []
    for n, line in enumerate(text.splitlines(), 1):
        for label, rx in PATTERNS:
            if rx.search(line):
                hits.append((n, label))
        for m in CARD.finditer(line):
            digits = re.sub(r"\D", "", m.group())
            if 13 <= len(digits) <= 19 and _luhn(digits):
                hits.append((n, "card number"))
    return hits
