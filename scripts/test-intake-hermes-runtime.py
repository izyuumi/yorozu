#!/usr/bin/env python3
"""Inert hostile-archive fixtures for the pinned runtime intake boundary."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import subprocess
import unittest

spec = importlib.util.spec_from_file_location("intake", Path(__file__).with_name("intake-hermes-runtime.py"))
intake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(intake)


def encoded(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


class IntakeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="yorozu-intake-test-")
        self.root = Path(self.tmp.name)
        self.source = self.root / "source"
        self.plugin = self.source / "packages/harness-plugins/hermes"
        self.plugin.mkdir(parents=True)
        (self.source / "docs").mkdir()
        self.upstream = {"fixture": "reviewed input"}
        (self.plugin / "runtime-input-pin.json").write_bytes(encoded(self.upstream))
        (self.source / "docs/hermes-public-archive-provenance.json").write_text('{"fixture":"no real archive attestation"}')
        self.members = {}
        for name in intake.PLUGIN_FILES:
            data = ("fixture:" + name).encode()
            path = self.plugin / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            self.members["plugin/" + name] = data
        self.counter = 0

    def tearDown(self):
        self.tmp.cleanup()

    def prepare(self, extra=None, mutate=None, links=None):
        self.counter += 1
        rows = [{"path": name, "sha256": digest(data), "mode": 0o644} for name, data in sorted(self.members.items())]
        rows.extend({"path": name, "link": target} for name, target in sorted((links or {}).items()))
        inventory = digest(encoded(rows))
        manifest = {"schemaVersion": 1, "kind": "yorozu-hermes-runtime", "hashStage": "assembled-before-signing",
                    "upstream": self.upstream, "files": rows, "inventorySha256": inventory}
        if mutate:
            mutate(manifest)
        data = encoded(manifest)
        archive = self.root / f"{self.counter}.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for name, value in {"runtime-artifact.json": data, **self.members}.items():
                info = tarfile.TarInfo("hermes/" + name)
                info.mode, info.size = 0o644, len(value)
                tar.addfile(info, io.BytesIO(value))
            for name, target in (links or {}).items():
                info = tarfile.TarInfo("hermes/" + name)
                info.type, info.mode, info.linkname = tarfile.SYMTYPE, 0o777, target
                tar.addfile(info)
            if extra:
                info, value = extra
                tar.addfile(info, io.BytesIO(value) if value is not None else None)
        pin = {"schemaVersion": 1, "kind": "yorozu-hermes-release-input", "repository": intake.REPOSITORY,
               "archiveSha256": intake.sha(archive), "archiveBytes": archive.stat().st_size,
               "manifestSha256": digest(data), "inventorySha256": inventory,
               "inputPinSha256": intake.sha(self.plugin / "runtime-input-pin.json"),
               "archiveProvenanceSha256": intake.sha(self.source / "docs/hermes-public-archive-provenance.json"),
               "originalArchivesVerified": True}
        pin.update(tag="runtime-input-0.6.0-" + pin["archiveSha256"][:16], asset="yorozu-hermes-runtime-" + pin["archiveSha256"][:16] + ".tar.gz")
        return archive, pin

    def extract(self, archive, pin):
        return intake.extract(archive, pin, self.root / f"out-{self.counter}", self.source)

    def test_exact_source_equivalent_archive_extracts_without_execution(self):
        archive, pin = self.prepare()
        root = self.extract(archive, pin)
        self.assertEqual((root / "plugin/adapter.mjs").read_bytes(), self.members["plugin/adapter.mjs"])
        receipt = json.loads((root.parent / "intake-receipt.json").read_text())
        self.assertFalse(receipt["gatewayExecuted"])
        self.assertTrue(receipt["pluginBytesMatchReviewedSource"])

    def test_packed_detached_git_inventory_reconstructs_empty_refs(self):
        repo = self.root / "fixture-repo"
        subprocess.run(["git", "init", "-q", str(repo)], check=True)
        def git(*args):
            return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()
        git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
            "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "fixture")
        commit = git("rev-parse", "HEAD")
        git("checkout", "--detach", "-q", commit)
        git("pack-refs", "--all")
        git("repack", "-ad")
        for path in (repo / ".git").rglob("*"):
            if path.is_file():
                self.members["source/.git/" + str(path.relative_to(repo / ".git"))] = path.read_bytes()
        archive, pin = self.prepare()
        root = self.extract(archive, pin)
        self.assertTrue((root / "source/.git/refs").is_dir())
        self.assertEqual(subprocess.check_output(["git", "-C", str(root / "source"),
                                                "rev-parse", "HEAD"], text=True).strip(), commit)
        for name, content in self.members.items():
            self.assertEqual((root / name).read_bytes(), content)

    def test_git_structural_symlinks_are_rejected_after_inventory_validation(self):
        # Each link is contained, resolves, and is declared in the pinned inventory.
        # Rejection must come from the structural guard, not a hash mismatch.
        cases = [
            ("source/.git/refs", "../../target", "source/.git/HEAD", "Git refs structural"),
            ("source/.git", "../target", "source/README", "Git structural parent"),
            ("source", "target", "target/.git/HEAD", "Git structural parent"),
        ]
        for name, target, member, reason in cases:
            with self.subTest(path=name):
                original = dict(self.members)
                try:
                    self.members.update({"target/keep": b"unchanged", member: b"fixture"})
                    archive, pin = self.prepare(links={name: target})
                    with self.assertRaisesRegex(ValueError, reason):
                        self.extract(archive, pin)
                    output = self.root / f"out-{self.counter}"
                    self.assertFalse((output / "intake-receipt.json").exists())
                    self.assertEqual((output / "hermes/target/keep").read_bytes(), b"unchanged")
                    self.assertFalse((output / "hermes/target/refs").exists())
                    self.assertFalse((output / "hermes/target/.git/refs").exists())
                finally:
                    self.members = original

    def test_contained_links_accept_canonical_aliased_and_dotdot_destinations(self):
        self.members["target/keep"] = b"unchanged"
        alias = self.root / "alias"
        alias.symlink_to(self.root.resolve(), target_is_directory=True)
        (self.root / "child").mkdir()
        for parent in (self.root.resolve(), alias, self.root / "child/.."):
            with self.subTest(parent=str(parent)):
                archive, pin = self.prepare(links={"contained": "target/keep"})
                destination = parent / f"valid-{self.counter}"
                root = intake.extract(archive, pin, destination, self.source)
                self.assertEqual(root, destination.resolve() / "hermes")
                self.assertEqual((root / "contained").read_bytes(), b"unchanged")

    def test_symlink_destination_itself_is_never_accepted(self):
        for existing in (False, True):
            with self.subTest(existing=existing):
                archive, pin = self.prepare()
                target = self.root / f"target-{self.counter}"
                if existing:
                    target.mkdir()
                destination = self.root / f"linked-{self.counter}"
                destination.symlink_to(target, target_is_directory=True)
                with self.assertRaisesRegex(ValueError, "fresh task-owned"):
                    intake.extract(archive, pin, destination, self.source)
                self.assertEqual(target.exists(), existing)
                self.assertFalse((target / "hermes").exists())

    def test_archive_tampering_is_rejected_before_extraction(self):
        archive, pin = self.prepare()
        value = bytearray(archive.read_bytes())
        value[-1] ^= 1
        archive.write_bytes(value)
        with self.assertRaisesRegex(ValueError, "hash differs"):
            self.extract(archive, pin)
        self.assertFalse((self.root / f"out-{self.counter}").exists())

    def test_reviewed_adapter_substitution_is_rejected_even_with_regenerated_manifest(self):
        self.members["plugin/adapter.mjs"] = b"substituted code"
        archive, pin = self.prepare()
        with self.assertRaisesRegex(ValueError, "adapter differs"):
            self.extract(archive, pin)

    def test_upstream_substitution_is_rejected(self):
        archive, pin = self.prepare(mutate=lambda m: m.update(upstream={"fixture": "other"}))
        with self.assertRaisesRegex(ValueError, "upstream differs"):
            self.extract(archive, pin)

    def test_unexpected_regular_member_is_rejected(self):
        info = tarfile.TarInfo("hermes/sitecustomize.py")
        info.mode, info.size = 0o644, 1
        archive, pin = self.prepare(extra=(info, b"x"))
        with self.assertRaisesRegex(ValueError, "content differs"):
            self.extract(archive, pin)

    def test_traversal_hardlinks_and_devices_are_rejected(self):
        for name, kind, link in [("../escaped", tarfile.REGTYPE, ""), ("hermes/hard", tarfile.LNKTYPE, "hermes/plugin/adapter.mjs"),
                                 ("hermes/device", tarfile.CHRTYPE, ""), ("hermes/link", tarfile.SYMTYPE, "../../escape")]:
            info = tarfile.TarInfo(name)
            info.type, info.mode, info.linkname = kind, 0o777 if kind == tarfile.SYMTYPE else 0o644, link
            archive, pin = self.prepare(extra=(info, b"" if kind == tarfile.REGTYPE else None))
            with self.assertRaises(ValueError):
                self.extract(archive, pin)
        self.assertFalse((self.root / "escaped").exists())

    def test_duplicate_member_is_rejected(self):
        info = tarfile.TarInfo("hermes/plugin/adapter.mjs")
        info.mode, info.size = 0o644, 1
        archive, pin = self.prepare(extra=(info, b"x"))
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.extract(archive, pin)

    def test_pin_requires_original_archive_attestation_and_committed_receipt(self):
        _, pin = self.prepare()
        path = self.root / "pin.json"
        path.write_text(json.dumps(pin))
        self.assertEqual(intake.load_pin(path, self.source), pin)
        pin["originalArchivesVerified"] = False
        path.write_text(json.dumps(pin))
        with self.assertRaisesRegex(ValueError, "not attested"):
            intake.load_pin(path, self.source)
        pin["originalArchivesVerified"] = True
        path.write_text(json.dumps(pin))
        (self.source / "docs/hermes-public-archive-provenance.json").write_text("changed")
        with self.assertRaisesRegex(ValueError, "provenance changed"):
            intake.load_pin(path, self.source)


if __name__ == "__main__":
    unittest.main()
