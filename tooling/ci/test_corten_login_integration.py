"""Bounded orchestration checks, not app or Apple execution evidence."""
from contextlib import ExitStack
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import run_corten_login_integration as run


class IntegrationSafety(unittest.TestCase):
    def test_additive_pins_preserve_existing_coordinates(self):
        before = b'[[package]]\nname="a"\nversion="1.0.0"\nsource="registry+x"\nchecksum="a"\n'
        after = before + b'[[package]]\nname="b"\nversion="2.0.0"\nsource="registry+x"\nchecksum="b"\n'
        self.assertEqual(run.unchanged_registry_pins(before, after),
                         [("b", "2.0.0", "registry+x", "b")])
        with self.assertRaisesRegex(RuntimeError, "pins changed"):
            run.unchanged_registry_pins(before, before.replace(b'1.0.0', b'1.0.1'))

    def test_restore_after_test_failure_preserves_exact_original_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, templates = root/"source", root/"templates"
            templates.mkdir()
            originals = {}
            for name in run.TRACKED:
                path = source/name
                path.parent.mkdir(parents=True, exist_ok=True)
                originals[name] = ("original:" + name + "\r\n").encode()
                path.write_bytes(originals[name])
            for name in run.ADDED.values():
                (templates/name).write_text("// fixture only\n")
            with patch.object(run, "OVERLAY", templates), patch.object(run, "command", return_value={"exit":0}):
                with self.assertRaisesRegex(RuntimeError, "injected"):
                    with run.overlay(source, root, {}):
                        (source/"rust/Cargo.lock").write_bytes(b"changed")
                        raise RuntimeError("injected qualification failure")
            self.assertEqual({name:(source/name).read_bytes() for name in run.TRACKED}, originals)
            self.assertTrue(all(not (source/name).exists() for name in run.ADDED))

    def test_existing_module_is_never_overwritten_or_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            for name in run.TRACKED:
                path = source/name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(b"baseline")
            name = next(iter(run.ADDED))
            (source/name).write_bytes(b"unique existing work")
            with self.assertRaisesRegex(RuntimeError, "Refuse to replace"):
                with run.overlay(source, source, {}):
                    self.fail("existing module admitted")
            self.assertEqual((source/name).read_bytes(), b"unique existing work")

    def test_owned_input_cleanup_retains_every_unowned_file(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            generated = source/"tooling"/"isolated-prototype"
            generated.mkdir(parents=True)
            (generated/"partial").write_bytes(b"partial copy")
            fixture = source/"generated.crt"
            fixture.write_bytes(b"fixture")
            protected = source/"existing.crt"
            protected.write_bytes(b"unique work")
            run.remove_owned_inputs(source, [generated], [fixture])
            self.assertEqual(protected.read_bytes(), b"unique work")
            self.assertFalse(generated.exists())
            self.assertFalse(fixture.exists())

    def test_owned_cleanup_rejects_the_checkout_root_and_outside_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory)
            for target in [source, source.parent/"unowned"]:
                with self.assertRaisesRegex(RuntimeError, "escaped"):
                    run.remove_owned_inputs(source, [target], [])

    def test_exact_patch_applies_to_baseline_files_including_native_submodule(self):
        source = Path(os.environ.get("OB_INTEGRATION_BASELINE", "candidate")).resolve()
        if not (source/"rust/Cargo.toml").is_file():
            self.skipTest("exact-source checkout not supplied")
        self.assertEqual(run.git(source, "rev-parse", "HEAD"), run.SOURCE)
        self.assertEqual(run.git(source/"rustpush", "rev-parse", "HEAD"), run.NATIVE)
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            for name in run.TRACKED:
                native = name.startswith("rustpush/")
                repository = source/"rustpush" if native else source
                rel = name.removeprefix("rustpush/") if native else name
                blob = subprocess.check_output(["git", "-C", str(repository), "show", "HEAD:"+rel])
                path = fixture/name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(blob)
            result = subprocess.run(["git", "apply", "--check", str(run.OVERLAY/"application.patch")],
                                    cwd=fixture, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_workflow_integration_does_not_fall_through_to_apk_or_exchange(self):
        workflow = (run.TOOLS.parent/".github/workflows/gce-runner-pilot.yml").read_text()
        build = workflow.split("  benchmark-build:", 1)[1].split("    needs:", 1)[0]
        self.assertIn("!= 'corten-login-integration-only'", build)
        integration = workflow.split("      - name: Qualify actual-app provider integration", 1)[1].split("      - name:", 1)[0]
        self.assertIn("== 'corten-login-integration-only'", integration)
        self.assertNotIn("private-only", integration)
        self.assertNotIn("run_corten_component_probe.py", integration)
        old_component = workflow.split("      - name: Qualify Linux engine,", 1)[1].split("      - name:", 1)[0]
        self.assertNotIn("corten-login-integration-only", old_component)

    def test_runner_has_no_account_or_framework_fetch(self):
        script = Path(run.__file__).read_text()
        self.assertNotIn("metadata_input()", script)
        self.assertNotIn("fetch_framework(", script)
        self.assertNotIn("AppleAccount", script)
        self.assertIn('"apple_requests":False', script)

    def test_every_android_integration_prerequisite_admits_the_mode(self):
        workflow = (run.TOOLS.parent/".github/workflows/gce-runner-pilot.yml").read_text()
        job = workflow.split("  corten-validator:", 1)[1].split("\n  apk-runtime:", 1)[0]
        for name in ["Set up exact Rust compiler and Android standard library",
                     "Set up Java for native SDK manager",
                     "Set up Android command-line tools only",
                     "Install one Android native compiler, no emulator or APK"]:
            step = job.split("      - name: " + name, 1)[1].split("      - name:", 1)[0]
            self.assertIn("corten-login-integration-only", step, name)


if __name__ == "__main__":
    unittest.main()
