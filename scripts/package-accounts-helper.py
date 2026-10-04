#!/usr/bin/env python3
"""Package the fixed host-only helper; construction never signs or launches code."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import plistlib
import shutil
import stat
import subprocess
import tempfile

BUNDLE_ID = "to.yumi.yorozu.accounts"
TEAM_ID = "AN5KM8QGEF"
ACCESS_GROUP = f"{TEAM_ID}.{BUNDLE_ID}"
BUNDLE_NAME = "YorozuAccounts.app"
EXECUTABLE = "yorozu-accounts"
MAX_PROFILE = 4 * 1024 * 1024
MAX_BINARY = 128 * 1024 * 1024


class PackagingError(ValueError):
    pass


def read_regular(path, maximum):
    """Capture explicit input once; no link traversal or unbounded allocation."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
                raise PackagingError("invalid-input")
            value = stream.read(maximum + 1)
            if len(value) > maximum:
                raise PackagingError("invalid-input")
            return value
    except OSError:
        raise PackagingError("invalid-input") from None


def decode_profile(profile_bytes):
    """Future authorized build path only. Tests inject a decoder and never run security."""
    with tempfile.TemporaryDirectory(prefix="yorozu-accounts-profile-") as temporary:
        captured = Path(temporary) / "explicit.provisionprofile"
        captured.write_bytes(profile_bytes)
        captured.chmod(0o600)
        with tempfile.TemporaryFile() as output:
            try:
                subprocess.run(["/usr/bin/security", "cms", "-D", "-i", str(captured)],
                               stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.DEVNULL,
                               check=True, timeout=10)
            except (OSError, subprocess.SubprocessError):
                raise PackagingError("invalid-profile") from None
            output.seek(0)
            value = output.read(MAX_PROFILE + 1)
            if len(value) > MAX_PROFILE:
                raise PackagingError("invalid-profile")
            return value


def profile_entitlements(payload, prefix, now):
    if prefix != TEAM_ID:
        raise PackagingError("invalid-profile")
    if not isinstance(payload, bytes) or len(payload) > MAX_PROFILE:
        raise PackagingError("invalid-profile")
    try:
        profile = plistlib.loads(payload)
    except Exception:
        raise PackagingError("invalid-profile") from None
    if not isinstance(profile, dict):
        raise PackagingError("invalid-profile")
    entitlements = profile.get("Entitlements")
    expiration = profile.get("ExpirationDate")
    if not isinstance(entitlements, dict) or not isinstance(expiration, dt.datetime):
        raise PackagingError("invalid-profile")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=dt.timezone.utc)
    groups = entitlements.get("keychain-access-groups")
    if (profile.get("TeamIdentifier") != [TEAM_ID] or profile.get("AppIdentifierPrefix") != [prefix]
            or profile.get("Platform") != ["OSX"] or expiration <= now
            or entitlements.get("com.apple.application-identifier") != ACCESS_GROUP
            or entitlements.get("com.apple.developer.team-identifier") != TEAM_ID
            or not isinstance(groups, list) or not groups
            or any(not isinstance(group, str) for group in groups)
            or not any(group in (ACCESS_GROUP, f"{prefix}.*") for group in groups)):
        raise PackagingError("invalid-profile")
    # This plist view prepares intended claims only; DER/OS authorization remains unproven.
    # Profile allowlists may contain wildcards. Claimed entitlements are always exact.
    return {"com.apple.application-identifier": ACCESS_GROUP,
            "com.apple.developer.team-identifier": TEAM_ID,
            "keychain-access-groups": [ACCESS_GROUP]}


def package_helper(resources, binary, info_plist, *, profile=None, app_identifier_prefix=None,
                   decoder=decode_profile, now=None):
    resources, binary, info_plist = Path(resources), Path(binary), Path(info_plist)
    destination = resources / BUNDLE_NAME
    if resources.is_symlink() or not resources.is_dir() or destination.exists() or destination.is_symlink():
        raise PackagingError("invalid-destination")
    if (profile is None) != (app_identifier_prefix is None):
        raise PackagingError("missing-profile-input")
    if app_identifier_prefix is not None and app_identifier_prefix != TEAM_ID:
        raise PackagingError("invalid-profile")
    binary_bytes = read_regular(binary, MAX_BINARY)
    if len(binary_bytes) < 4 or binary_bytes[:4] not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
        raise PackagingError("invalid-binary")
    try:
        info = plistlib.loads(read_regular(info_plist, 64 * 1024))
    except Exception:
        raise PackagingError("invalid-info") from None
    if (not isinstance(info, dict) or info.get("CFBundleIdentifier") != BUNDLE_ID
            or info.get("CFBundleExecutable") != EXECUTABLE or info.get("CFBundlePackageType") != "APPL"
            or info.get("LSBackgroundOnly") is not True):
        raise PackagingError("invalid-info")
    entitlements, profile_bytes = {}, None
    if profile is not None:
        profile_bytes = read_regular(profile, MAX_PROFILE)
        entitlements = profile_entitlements(decoder(profile_bytes), app_identifier_prefix,
                                          now or dt.datetime.now(dt.timezone.utc))
    manifest = {"schemaVersion": 1, "kind": "yorozu-accounts-helper", "bundleIdentifier": BUNDLE_ID,
                "executable": f"Contents/MacOS/{EXECUTABLE}", "productionReady": False,
                "osProfileVerification": "unproven",
                "provisioning": "static-input-checks" if profile_bytes is not None else "absent"}
    stage = Path(tempfile.mkdtemp(prefix=f".{BUNDLE_NAME}-", dir=resources))
    try:
        stage.chmod(0o755)
        contents = stage / "Contents"
        (contents / "MacOS").mkdir(parents=True, mode=0o755)
        (contents / "Resources").mkdir(mode=0o755)
        (contents / "Info.plist").write_bytes(plistlib.dumps(info, sort_keys=True))
        executable = contents / "MacOS" / EXECUTABLE
        executable.write_bytes(binary_bytes); executable.chmod(0o755)
        (contents / "Resources" / "AccountsHelper.entitlements").write_bytes(plistlib.dumps(entitlements, sort_keys=True))
        (contents / "Resources" / "accounts-helper.json").write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        if profile_bytes is not None:
            (contents / "embedded.provisionprofile").write_bytes(profile_bytes)
        for path in contents.rglob("*"):
            if path.is_file() and path != executable:
                path.chmod(0o644)
        os.rename(stage, destination)
    except BaseException:
        shutil.rmtree(stage)
        raise
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--resources", required=True)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--info-plist", required=True)
    parser.add_argument("--profile")
    parser.add_argument("--app-identifier-prefix")
    args = parser.parse_args()
    try:
        manifest = package_helper(args.resources, args.binary, args.info_plist,
                                  profile=args.profile, app_identifier_prefix=args.app_identifier_prefix)
    except PackagingError as error:
        parser.exit(1, f"account helper packaging refused: {error}\n")
    except OSError:
        parser.exit(1, "account helper packaging refused: invalid-output\n")
    print(json.dumps(manifest, sort_keys=True))


if __name__ == "__main__":
    main()
