#!/usr/bin/env python3
"""Inert fixtures for the pinned sealed OpenClaw runtime intake boundary. No downloads."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("intake", Path(__file__).with_name("intake-openclaw-runtime.py"))
intake = importlib.util.module_from_spec(spec)
spec.loader.exec_module(intake)
packager = intake.packager


def digest(data):
    return hashlib.sha256(data).hexdigest()


class IntakeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="yorozu-openclaw-intake-test-")
        self.root = Path(self.tmp.name).resolve()
        self.source = self.root / "source"
        self.plugin = self.source / "packages/harness-plugins/openclaw"
        (self.plugin / "memory-plugin").mkdir(parents=True)
        self.plugin_files = {"adapter.mjs": b"fixture adapter", "memory-plugin/index.mjs": b"fixture plugin"}
        for name, data in self.plugin_files.items():
            (self.plugin / name).write_bytes(data)
        self.node = b"fixture node, never executed"
        self.pins = {**packager.PIN, "nodeSha256": digest(self.node)}
        self.patch = mock.patch.dict(packager.PIN, self.pins)
        self.patch.start()
        self.artifact = self.root / "artifact"
        self.artifact.mkdir()
        self.write("node", self.node, 0o755)
        for name, data in self.plugin_files.items():
            self.write("plugin/" + name, data)
        self.write("source/dist/entry.mjs", b"fixture source")
        (self.artifact / "source/link.mjs").symlink_to("dist/entry.mjs")
        rows = self.rows()
        self.manifest = {"schemaVersion": 1, "kind": "yorozu-openclaw-runtime", "hashStage": "assembled-before-signing",
                         "productionReady": False, "pins": self.pins,
                         "dependencyEvidence": {"kind": "pnpm-frozen-lockfile-install-v1", "lockfileMatchEstablished": True,
                                                "archiveProvenanceVerified": True},
                         "files": rows, "inventorySha256": digest(packager.encoded(rows))}
        self.write_manifest()
        self.archive = self.root / "runtime.tar.gz"
        packager.archive(self.artifact, self.archive)
        self.pin = self.make_pin()

    def tearDown(self):
        self.patch.stop()
        self.tmp.cleanup()

    def write(self, name, data, mode=0o644):
        path = self.artifact / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        path.chmod(mode)

    def rows(self):
        return [row for row in packager.inventory(self.artifact) if row["path"] != intake.MANIFEST]

    def write_manifest(self):
        data = packager.encoded(self.manifest) + b"\n"
        self.write(intake.MANIFEST, data)
        return data

    def make_pin(self, **overrides):
        archive_sha = intake.sha(self.archive)
        pin = {"schemaVersion": 1, "kind": "yorozu-openclaw-release-input", "repository": intake.REPOSITORY,
               "tag": "runtime-input-0.6.0-" + archive_sha[:16], "asset": "yorozu-openclaw-runtime-" + archive_sha[:16] + ".tar.gz",
               "archiveSha256": archive_sha, "archiveBytes": self.archive.stat().st_size,
               "manifestSha256": intake.sha(self.artifact / intake.MANIFEST), "inventorySha256": self.manifest["inventorySha256"],
               "sourceCommit": packager.PIN["sourceSha"], **overrides}
        path = self.root / "pin.json"
        path.write_text(json.dumps(pin))
        return path

    def run_intake(self, destination="out"):
        return intake.extract(self.archive, intake.load_pin(self.pin), self.root / destination, self.source)

    def test_exact_archive_extracts_without_execution_and_writes_receipt(self):
        root = self.run_intake()
        self.assertEqual(root, self.root / "out/openclaw")
        self.assertEqual((root / "node").read_bytes(), self.node)
        self.assertEqual((root / "source/link.mjs").readlink().as_posix(), "dist/entry.mjs")
        self.assertEqual(packager.inventory(root)[0]["path"], "node")
        receipt = json.loads((self.root / "out/intake-receipt.json").read_text())
        self.assertEqual(receipt["inventorySha256"], self.manifest["inventorySha256"])
        self.assertEqual(receipt["sourceCommit"], packager.PIN["sourceSha"])
        self.assertFalse(receipt["gatewayExecuted"])
        with self.assertRaisesRegex(ValueError, "fresh task-owned"):
            self.run_intake()

    def test_archive_tampering_is_rejected_before_extraction(self):
        data = bytearray(self.archive.read_bytes())
        data[-1] ^= 0x01
        self.archive.write_bytes(data)
        with self.assertRaisesRegex(ValueError, "hash differs"):
            self.run_intake()
        self.assertFalse((self.root / "out").exists())

    def test_reviewed_adapter_substitution_is_rejected_even_with_regenerated_manifest(self):
        self.write("plugin/adapter.mjs", b"substituted adapter")
        self.manifest["files"] = self.rows()
        self.manifest["inventorySha256"] = digest(packager.encoded(self.manifest["files"]))
        self.write_manifest()
        packager.archive(self.artifact, self.archive)
        self.pin = self.make_pin()
        with self.assertRaisesRegex(ValueError, "differs from reviewed source"):
            self.run_intake()

    def test_extra_plugin_file_is_rejected(self):
        self.write("plugin/extra.mjs", b"not reviewed")
        self.manifest["files"] = self.rows()
        self.manifest["inventorySha256"] = digest(packager.encoded(self.manifest["files"]))
        self.write_manifest()
        packager.archive(self.artifact, self.archive)
        self.pin = self.make_pin()
        with self.assertRaisesRegex(ValueError, "Unexpected plugin payload"):
            self.run_intake()

    def test_unreviewed_empty_directory_is_rejected(self):
        (self.artifact / "plugin/unreviewed").mkdir(mode=0o755)
        packager.archive(self.artifact, self.archive)
        self.pin = self.make_pin()
        with self.assertRaisesRegex(ValueError, "Unexpected runtime directories"):
            self.run_intake()

    def test_unpinned_node_is_rejected(self):
        self.patch.stop()
        self.patch = mock.patch.dict(packager.PIN, {**self.pins, "nodeSha256": "0" * 64})
        self.patch.start()
        with self.assertRaisesRegex(ValueError, "pins differ"):
            self.run_intake()

    def test_manifest_identity_and_evidence_are_required(self):
        for key, value, reason in [("kind", "yorozu-hermes-runtime", "identity"), ("productionReady", True, "identity"),
                                   ("dependencyEvidence", {"kind": "reused-local-bytes-inventory-only"}, "evidence")]:
            with self.subTest(key=key):
                saved = self.manifest[key]
                self.manifest[key] = value
                self.write_manifest()
                packager.archive(self.artifact, self.archive)
                self.pin = self.make_pin()
                with self.assertRaisesRegex(ValueError, reason):
                    self.run_intake(destination="out-" + key)
                self.manifest[key] = saved

    def tar_with(self, *entries):
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as tar:
            info = tarfile.TarInfo("node")
            info.size, info.mode = len(self.node), 0o755
            tar.addfile(info, io.BytesIO(self.node))
            for name, kind, linkname in entries:
                info = tarfile.TarInfo(name)
                info.type, info.linkname, info.mode = kind, linkname, 0o777 if kind == tarfile.SYMTYPE else 0o644
                tar.addfile(info)
        self.archive.write_bytes(buffer.getvalue())
        self.pin = self.make_pin()

    def test_traversal_links_hardlinks_and_devices_are_rejected_by_their_own_check(self):
        outside = self.root / "outside"
        outside.mkdir()
        cases = {"traversal": ([("../escape", tarfile.REGTYPE, "")], "unsafe relative path"),
                 "absolute-link": ([("source/link", tarfile.SYMTYPE, "/etc/passwd")], "Invalid runtime symlink"),
                 "escaping-link": ([("source/link", tarfile.SYMTYPE, "../../outside")], "escapes artifact"),
                 "link-parent": ([("a", tarfile.SYMTYPE, "source"), ("a/b", tarfile.SYMTYPE, "x")], "symlink parent"),
                 "hardlink": ([("source/hard", tarfile.LNKTYPE, "node")], "Hardlinks"),
                 "device": ([("source/dev", tarfile.CHRTYPE, "")], "special runtime entries")}
        for kind, (entries, reason) in cases.items():
            with self.subTest(kind=kind):
                self.tar_with(*entries)
                with self.assertRaisesRegex(ValueError, reason):
                    self.run_intake(destination="out-" + kind)
                links = [p for p in (self.root / ("out-" + kind)).rglob("*") if p.is_symlink()]
                self.assertEqual(links, [])
        self.assertEqual(list(outside.iterdir()), [])

    def test_pin_requires_content_addressed_tag_and_reviewed_source(self):
        for overrides, reason in [({"tag": "runtime-input-0.6.0-latest"}, "content-addressed"),
                                  ({"asset": "yorozu-openclaw-runtime.tar.gz"}, "asset name"),
                                  ({"repository": "someone/else"}, "release repository"),
                                  ({"sourceCommit": "0" * 40}, "reviewed native source"),
                                  ({"kind": "yorozu-hermes-release-input"}, "Invalid release input pin")]:
            with self.subTest(reason=reason):
                with self.assertRaisesRegex(ValueError, reason):
                    intake.load_pin(self.make_pin(**overrides))


if __name__ == "__main__":
    unittest.main()
