"""Shared settings for the example scripts. Everything comes from environment variables.

  PAIOS_ROOT    path to the folder that contains PAIOS/ (required unless a script gets an explicit path)
  PAIOS_VAULT   older name for PAIOS_ROOT; used when PAIOS_ROOT is not set
  PAIOS_TZ      IANA time zone for dates and timestamps (default: UTC)
"""
import datetime, os, sys
from zoneinfo import ZoneInfo

def tz():
    return ZoneInfo(os.environ.get("PAIOS_TZ", "UTC"))

def now():
    return datetime.datetime.now(tz())

def root_path(*parts):
    v = os.environ.get("PAIOS_ROOT") or os.environ.get("PAIOS_VAULT")
    if not v:
        return None
    return os.path.join(v, "PAIOS", *parts)

vault_path = root_path  # older name, kept for existing callers
