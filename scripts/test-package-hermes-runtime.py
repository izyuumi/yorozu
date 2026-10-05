"""Inert packaging boundary checks; no model, gateway, installer or profile."""
import base64
import csv
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("hermes_packager", Path(__file__).with_name("package-hermes-runtime.py"))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackagingBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="yorozu-packaging-test-")
        self.root = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def dependencies(self):
        source, venv = self.root / "source", self.root / "venv"
        source.mkdir()
        site = venv / "lib/python3.13/site-packages"
        site.mkdir(parents=True)
        packages = (("hermes-agent", "0.21.5"), ("packaging", "26.0"), ("example-dependency", "1.2.3"))
        (source / "uv.lock").write_text("\n".join(f'[[package]]\nname = "{name}"\nversion = "{version}"\n' for name, version in packages))
        for name, version in packages:
            metadata = site / f"{name.replace('-', '_')}-{version}.dist-info"
            metadata.mkdir()
            contents = f"Name: {name}\nVersion: {version}\n".encode()
            (metadata / "METADATA").write_bytes(contents)
            value = base64.urlsafe_b64encode(hashlib.sha256(contents).digest()).decode().rstrip("=")
            with (metadata / "RECORD").open("w", newline="") as stream:
                csv.writer(stream).writerows([(metadata.name + "/METADATA", "sha256=" + value, str(len(contents))), (metadata.name + "/RECORD", "", "")])
        return source, venv, site

    def test_lock_versions_and_record_bytes_are_both_mandatory(self):
        source, venv, site = self.dependencies()
        self.assertEqual(len(packager.dependency_inventory(source, venv)[1]), 3)
        record = site / "example_dependency-1.2.3.dist-info/METADATA"
        record.write_bytes(record.read_bytes() + b"tampered\n")
        with self.assertRaisesRegex(ValueError, "RECORD"):
            packager.dependency_inventory(source, venv)

    def test_unlocked_prepared_package_cannot_be_silently_bundled(self):
        source, venv, site = self.dependencies()
        metadata = site / "example_dependency-1.2.3.dist-info/METADATA"
        metadata.write_text("Name: example-dependency\nVersion: 9.9.9\n")
        with self.assertRaisesRegex(ValueError, "frozen lock"):
            packager.dependency_inventory(source, venv)

    def test_unknown_executable_startup_hooks_are_rejected(self):
        source, venv, site = self.dependencies()
        (site / "ambient.pth").write_text("import unwanted_installer\n")
        with self.assertRaisesRegex(ValueError, "startup hook"):
            packager.dependency_inventory(source, venv)

    def test_unowned_modules_are_rejected(self):
        source, venv, site = self.dependencies()
        (site / "unowned.py").write_text("inert = True\n")
        with self.assertRaisesRegex(ValueError, "Unowned"):
            packager.dependency_inventory(source, venv)

    def test_customization_hooks_are_rejected_even_when_record_owned(self):
        for name in ("sitecustomize.py", "usercustomize.py", "sitecustomize/__init__.py"):
            with self.subTest(name=name):
                source, venv, site = self.root / "unused", self.root / "unused", self.root / "hook-site"
                path = site / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("inert = True\n")
                with self.assertRaisesRegex(ValueError, "customization hook"):
                    packager.validate_site_ownership(site, {path.resolve()})
                path.unlink()
                if path.parent != site:
                    path.parent.rmdir()

    def test_record_cannot_read_an_outside_file(self):
        source, venv, site = self.dependencies()
        outside = self.root / "outside-fixture"
        outside.write_text("owned fixture only")
        with (site / "example_dependency-1.2.3.dist-info/RECORD").open("a", newline="") as stream:
            csv.writer(stream).writerow((str(outside), "", ""))
        with self.assertRaisesRegex(ValueError, "escapes"):
            packager.dependency_inventory(source, venv)

    def test_absolute_and_escaping_symlinks_are_not_relocated(self):
        tree = self.root / "tree"
        tree.mkdir()
        outside = self.root / "outside-fixture"
        outside.write_text("owned fixture only")
        link = tree / "link"
        link.symlink_to("../outside-fixture")
        with self.assertRaisesRegex(ValueError, "symlink"):
            packager.inventory(tree)
        link.unlink()
        link.symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "symlink"):
            packager.inventory(tree)

    def test_dyld_loads_must_resolve_inside_artifact_or_apple_system(self):
        library = self.root / "python/lib/libfixture.dylib"
        library.parent.mkdir(parents=True)
        library.write_text("owned library fixture")
        loader = self.root / "python/lib/package/module.so"
        executable = self.root / "python/bin/python3.13"
        loader.parent.mkdir()
        executable.parent.mkdir()
        self.assertEqual(packager.resolve_dependency("@loader_path/../libfixture.dylib", loader, executable, [], self.root), "python/lib/libfixture.dylib")
        self.assertEqual(packager.resolve_dependency("@rpath/libfixture.dylib", loader, executable, ["@executable_path/../lib"], self.root), "python/lib/libfixture.dylib")
        self.assertEqual(packager.resolve_dependency("/usr/lib/libSystem.B.dylib", loader, executable, [], self.root), "system")
        for value in ("/opt/homebrew/lib/libfixture.dylib", "/usr/lib/../../opt/homebrew/lib/libfixture.dylib", "@loader_path/../../../../external.dylib", "@rpath/missing.dylib"):
            with self.assertRaisesRegex(ValueError, "escapes"):
                packager.resolve_dependency(value, loader, executable, [], self.root)
        packager.validate_rpaths(["@loader_path", "@executable_path/../lib"], loader, executable, self.root)
        with self.assertRaisesRegex(ValueError, "RPATH"):
            packager.validate_rpaths(["/opt/homebrew/lib"], loader, executable, self.root)

    def test_input_copy_excludes_ambient_site_packages_and_nonruntime_scripts(self):
        source = self.root / "python"
        for relative in ("bin/python3.13", "bin/pip", "lib/python3.13/os.py", "lib/python3.13/site-packages/ambient.py", "lib/python3.13/__pycache__/os.pyc"):
            path = source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("owned fixture")
        rows = packager.python_inventory(source)
        self.assertEqual({row["path"] for row in rows}, {"bin/python3.13", "lib/python3.13/os.py"})

    def test_rewritten_records_exclude_removed_editable_and_console_entries(self):
        site = self.root / "site"
        metadata = site / "example-1.0.dist-info"
        metadata.mkdir(parents=True)
        (metadata / "METADATA").write_text("Name: example\nVersion: 1.0\n")
        with (metadata / "RECORD.input").open("w", newline="") as stream:
            csv.writer(stream).writerows([("example-1.0.dist-info/METADATA", "", ""), ("../../../bin/example", "", ""), ("removed.pth", "", ""), ("example-1.0.dist-info/RECORD", "", "")])
        packager.rewrite_records(site)
        self.assertFalse((metadata / "RECORD.input").exists())
        with (metadata / "RECORD").open(newline="") as stream:
            rows = list(csv.reader(stream))
        self.assertEqual([row[0] for row in rows], ["example-1.0.dist-info/METADATA", "example-1.0.dist-info/RECORD"])
        self.assertTrue(rows[0][1].startswith("sha256="))

    def test_native_derivation_rejects_unreviewed_bytes_without_execution(self):
        path = self.root / packager.JPEG_DERIVATION["path"]
        path.parent.mkdir(parents=True)
        path.write_text("owned deliberately unreviewed fixture")
        with mock.patch.object(packager.subprocess, "run") as execute:
            with self.assertRaisesRegex(ValueError, "reviewed native input"):
                packager.curate_native_loads(self.root)
        execute.assert_not_called()

    def test_changed_native_output_stops_before_any_signature(self):
        commands = b"Load command 1\n          cmd LC_RPATH\n      cmdsize 80\n         path /Users/runner/work/Pillow/Pillow/build/deps/darwin/lib (offset 12)\n"
        with mock.patch.object(packager, "digest", side_effect=[packager.JPEG_DERIVATION["inputSha256"], "0" * 64]), \
             mock.patch.object(packager.subprocess, "check_output", return_value=commands), \
             mock.patch.object(packager.subprocess, "run") as execute:
            with self.assertRaisesRegex(ValueError, "load-command output"):
                packager.curate_native_loads(self.root)
        self.assertEqual(execute.call_count, 1)
        self.assertEqual(execute.call_args.args[0][:2], ["/usr/bin/install_name_tool", "-delete_rpath"])

    def test_failed_reseal_keeps_prior_manifest_bytes(self):
        native = self.root / "python/bin/python3.13"
        native.parent.mkdir(parents=True)
        native.write_bytes(b"\xcf\xfa\xed\xfe" + b"owned initial fixture")
        rows = packager.inventory(self.root)
        manifest = self.root / packager.MANIFEST
        manifest.write_text(json.dumps({"schemaVersion": 1, "kind": "yorozu-hermes-runtime",
            "upstream": {"sourceSha": packager.SOURCE_SHA}, "files": rows,
            "inventorySha256": packager.tree_digest(rows), "machODependencies": [{"path": "python/bin/python3.13"}],
            "hashStage": "assembled-before-signing"}))
        before = manifest.read_bytes()
        native.write_bytes(b"\xcf\xfa\xed\xfe" + b"owned changed fixture")
        with mock.patch.object(packager, "verify_source"), \
             mock.patch.object(packager, "audit_macho", side_effect=ValueError("native audit failed")):
            with self.assertRaisesRegex(ValueError, "native audit failed"):
                packager.verify_artifact(self.root, reseal=True)
        self.assertEqual(manifest.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
