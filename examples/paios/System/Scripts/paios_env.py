"""Shared settings for the example scripts. Everything comes from environment variables.

  PAIOS_VAULT   path to the vault that contains PAIOS/ (required unless a script gets an explicit path)
  PAIOS_TZ      IANA time zone for dates and timestamps (default: UTC)
"""
import datetime, os, sys
from zoneinfo import ZoneInfo

def tz():
    return ZoneInfo(os.environ.get("PAIOS_TZ", "UTC"))

def now():
    return datetime.datetime.now(tz())

def vault_path(*parts):
    v = os.environ.get("PAIOS_VAULT")
    if not v:
        return None
    return os.path.join(v, "PAIOS", *parts)
