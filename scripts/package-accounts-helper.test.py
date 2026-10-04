#!/usr/bin/env python3
"""Synthetic packaging only: never decode a real profile, sign or launch the helper."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).with_name("package-accounts-helper.py")
spec = importlib.util.spec_from_file_location("accounts_packaging", SCRIPT)
packaging = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packaging)
NOW = dt.datetime(2026, 10, 4, tzinfo=dt.timezone.utc)


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="yorozu-accounts-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.resources = self.root / "Resources"; self.resources.mkdir()
        self.binary = self.root / "compiled-helper"
        self.binary.write_bytes(b"\xcf\xfa\xed\xfe" + b"synthetic inert Mach-O fixture")
        self.info = self.root / "Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": packaging.BUNDLE_ID,
            "CFBundleExecutable": packaging.EXECUTABLE, "CFBundlePackageType": "APPL", "LSBackgroundOnly": True}))
        self.profile = self.root / "explicit.provisionprofile"
        self.profile.write_bytes(b"synthetic CMS payload; no real certificate or account")
        self.payload = {"TeamIdentifier": [packaging.TEAM_ID], "AppIdentifierPrefix": [packaging.TEAM_ID],
            "Platform": ["OSX"], "ExpirationDate": NOW.replace(year=2027, tzinfo=None),
            "Entitlements": {"com.apple.application-identifier": packaging.ACCESS_GROUP,
                "com.apple.developer.team-identifier": packaging.TEAM_ID,
                "keychain-access-groups": [packaging.TEAM_ID + ".*"]}}
        self.native = patch.object(packaging.subprocess, "run", side_effect=AssertionError("native execution forbidden"))
        self.native.start(); self.addCleanup(self.native.stop)

    def package(self, **kwargs):
        return packaging.package_helper(self.resources, self.binary, self.info, now=NOW, **kwargs)

    def provisioned(self):
        decoder = Mock(return_value=plistlib.dumps(self.payload))
        result = self.package(profile=self.profile, app_identifier_prefix=packaging.TEAM_ID, decoder=decoder)
        decoder.assert_called_once_with(self.profile.read_bytes())
        return result

    def bundle(self):
        return self.resources / packaging.BUNDLE_NAME

    def test_unprovisioned_bundle_preserves_binary_and_claims_no_access(self):
        decoder = Mock(side_effect=AssertionError("profile decoder must stay dormant"))
        result = self.package(decoder=decoder)
        decoder.assert_not_called()
        self.assertEqual(result["provisioning"], "absent")
        self.assertIs(result["productionReady"], False)
        self.assertEqual(result["osProfileVerification"], "unproven")
        contents = self.bundle() / "Contents"
        self.assertFalse((contents / "embedded.provisionprofile").exists())
        self.assertEqual(plistlib.loads((contents / "Resources/AccountsHelper.entitlements").read_bytes()), {})
        executable = contents / "MacOS" / packaging.EXECUTABLE
        self.assertEqual(executable.read_bytes(), self.binary.read_bytes())
        self.assertEqual(executable.stat().st_mode & 0o777, 0o755)
        self.assertEqual(json.loads((contents / "Resources/accounts-helper.json").read_text()), result)
        self.assertTrue(plistlib.loads((contents / "Info.plist").read_bytes())["LSBackgroundOnly"])

    def test_explicit_profile_authorizes_one_exact_helper_group(self):
        result = self.provisioned()
        contents = self.bundle() / "Contents"
        self.assertEqual(result["provisioning"], "static-input-checks")
        self.assertIs(result["productionReady"], False)
        self.assertEqual(result["osProfileVerification"], "unproven")
        self.assertEqual((contents / "embedded.provisionprofile").read_bytes(), self.profile.read_bytes())
        self.assertEqual((contents / "embedded.provisionprofile").stat().st_mode & 0o777, 0o644)
        entitlements = plistlib.loads((contents / "Resources/AccountsHelper.entitlements").read_bytes())
        self.assertEqual(entitlements, {"com.apple.application-identifier": packaging.ACCESS_GROUP,
            "com.apple.developer.team-identifier": packaging.TEAM_ID,
            "keychain-access-groups": [packaging.ACCESS_GROUP]})
        self.assertNotIn("*", entitlements["keychain-access-groups"][0])

    def test_profile_requires_prefix_and_prefix_requires_profile(self):
        for kwargs in ({"profile": self.profile}, {"app_identifier_prefix": packaging.TEAM_ID}):
            with self.subTest(kwargs=kwargs), self.assertRaises(packaging.PackagingError):
                self.package(**kwargs)
        self.assertFalse(self.bundle().exists())

    def test_wrong_identity_team_group_platform_and_expiration_refused_before_writes(self):
        mutations = [lambda p: p.update(TeamIdentifier=["OTHERTEAM1"]),
            lambda p: p.update(AppIdentifierPrefix=["OTHERTEAM1"]),
            lambda p: p.update(Platform=["iOS"]),
            lambda p: p.update(ExpirationDate=NOW.replace(year=2025, tzinfo=None)),
            lambda p: p["Entitlements"].update({"com.apple.application-identifier": packaging.TEAM_ID + ".*"}),
            lambda p: p["Entitlements"].update({"com.apple.developer.team-identifier": "OTHERTEAM1"}),
            lambda p: p["Entitlements"].update({"keychain-access-groups": ["*"]}),
            lambda p: p["Entitlements"].update({"keychain-access-groups": [packaging.TEAM_ID + ".to.yumi.yorozu"]})]
        for mutate in mutations:
            payload = plistlib.loads(plistlib.dumps(self.payload)); mutate(payload)
            with self.subTest(mutate=mutate), self.assertRaises(packaging.PackagingError):
                self.package(profile=self.profile, app_identifier_prefix=packaging.TEAM_ID,
                             decoder=lambda _: plistlib.dumps(payload))
            self.assertEqual(list(self.resources.iterdir()), [])

    def test_prefix_is_explicit_never_inferred_from_the_team(self):
        decoder = Mock(side_effect=AssertionError("invalid prefix must precede CMS decoding"))
        with self.assertRaises(packaging.PackagingError):
            self.package(profile=self.profile, app_identifier_prefix="OTHERTEAM1", decoder=decoder)
        decoder.assert_not_called()
        self.assertFalse(self.bundle().exists())

    def test_exact_profile_group_is_also_supported(self):
        self.payload["Entitlements"]["keychain-access-groups"] = [packaging.ACCESS_GROUP]
        self.provisioned()

    def test_profile_and_decoded_payload_bounds_are_enforced(self):
        self.profile.write_bytes(b"x" * (packaging.MAX_PROFILE + 1))
        decoder = Mock()
        with self.assertRaises(packaging.PackagingError):
            self.package(profile=self.profile, app_identifier_prefix=packaging.TEAM_ID, decoder=decoder)
        decoder.assert_not_called()
        self.profile.write_bytes(b"synthetic")
        for value in (b"x" * (packaging.MAX_PROFILE + 1), b"not a plist", {}, plistlib.dumps([])):
            with self.subTest(value_type=type(value)), self.assertRaises(packaging.PackagingError):
                self.package(profile=self.profile, app_identifier_prefix=packaging.TEAM_ID, decoder=lambda _: value)
        self.assertFalse(self.bundle().exists())

    def test_symlink_input_and_destination_refused_without_overwrite(self):
        binary = self.root / "binary-link"; binary.symlink_to(self.binary)
        with self.assertRaises(packaging.PackagingError):
            packaging.package_helper(self.resources, binary, self.info)
        profile = self.root / "profile-link"; profile.symlink_to(self.profile)
        with self.assertRaises(packaging.PackagingError):
            self.package(profile=profile, app_identifier_prefix=packaging.TEAM_ID, decoder=lambda _: plistlib.dumps(self.payload))
        self.bundle().symlink_to(self.root / "missing-bundle")
        with self.assertRaises(packaging.PackagingError):
            self.package()

    def test_existing_bundle_is_preserved(self):
        original = self.package()
        with self.assertRaises(packaging.PackagingError):
            self.provisioned()
        self.assertEqual(json.loads((self.bundle() / "Contents/Resources/accounts-helper.json").read_text()), original)

    def test_invalid_binary_and_foreground_bundle_refused(self):
        self.binary.write_bytes(b"not a Mach-O")
        with self.assertRaises(packaging.PackagingError):
            self.package()
        self.binary.write_bytes(b"\xcf\xfa\xed\xfe" + b"inert")
        info = plistlib.loads(self.info.read_bytes()); info["LSBackgroundOnly"] = False
        self.info.write_bytes(plistlib.dumps(info))
        with self.assertRaises(packaging.PackagingError):
            self.package()

    def test_assembly_failure_removes_only_its_own_partial_bundle(self):
        with patch.object(packaging.os, "rename", side_effect=OSError("synthetic failure")):
            with self.assertRaises(OSError):
                self.package()
        self.assertEqual(list(self.resources.iterdir()), [])
        self.assertTrue(self.binary.exists())


if __name__ == "__main__":
    unittest.main()
