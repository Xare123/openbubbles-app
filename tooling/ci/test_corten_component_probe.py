"""Credential-free orchestration guards, not native or account qualification."""
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from contextlib import ExitStack
from unittest.mock import patch, Mock
SPEC = importlib.util.spec_from_file_location("corten_run", Path(__file__).with_name("run_corten_component_probe.py"))
RUN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUN)

class CortenSafety(unittest.TestCase):
    def test_wrong_source_is_rejected(self):
        with patch.object(RUN, "git", return_value="0"*40):
            with self.assertRaisesRegex(RuntimeError, "reviewed application"):
                RUN.verify_source(Path("unused"))
    def test_dirty_source_is_rejected(self):
        with patch.object(RUN, "git", side_effect=[RUN.SOURCE, " M rust/Cargo.lock"]):
            with self.assertRaisesRegex(RuntimeError, "dirty"):
                RUN.verify_source(Path("unused"))
    def test_wrong_native_is_rejected(self):
        with patch.object(RUN, "git", side_effect=[RUN.SOURCE, "", "0"*40]):
            with self.assertRaisesRegex(RuntimeError, "rustpush"):
                RUN.verify_source(Path("unused"))
    def test_uninitialized_recursive_pin_is_rejected(self):
        with patch.object(RUN, "git", side_effect=[RUN.SOURCE, "", RUN.NATIVE, "-abc rustpush"]):
            with self.assertRaisesRegex(RuntimeError, "six initialized"):
                RUN.verify_source(Path("unused"))
    def test_private_input_bounds(self):
        with self.assertRaisesRegex(RuntimeError, "bound"):
            RUN.decode_private_input(b"x"*1025)
    def test_unknown_transfer_is_rejected_without_native_calls(self):
        with self.assertRaisesRegex(RuntimeError, "identity"):
            RUN.decode_private_input(b"T0FCUwBub3QgdGhlIGlkZW50aXR5")
    def test_artifact_url_is_immutable(self):
        self.assertIn("0a2aa2406542fb09c14a37db17ff14865b8aea29", RUN.FRAMEWORK_URL)
        self.assertEqual(len(RUN.FRAMEWORK_SHA256),64)
    def test_no_auto_generated_hardware(self):
        text = Path(RUN.__file__).read_text()
        self.assertNotIn("uuid.uuid4", text)
        self.assertNotIn("AppleAccount", text)
    def test_thread_patch_is_android_scoped_and_changes_only_two_directives(self):
        original = 'prefix\nprintln!("cargo:rustc-link-lib=pthread");\nmiddle\nprintln!("cargo:rustc-link-lib=pthread");\nsuffix'
        patched = RUN.patch_android_thread_directives(original)
        self.assertEqual(patched.count('CARGO_CFG_TARGET_OS'),2)
        self.assertEqual(patched.count('Ok("android")'),2)
        self.assertTrue(patched.startswith('prefix\n'))
        self.assertTrue(patched.endswith('\nsuffix'))
    def test_changed_vendor_layout_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "unexpected"):
            RUN.patch_android_thread_directives("unknown build script")

class PrivateValidationPhase(unittest.TestCase):
    def phase(self, private=b"private_fixture", validation_exit=0, loader_only=False, test_exit=0):
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            binary = root / "corten-target/debug/corten-mac-validation-probe"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"only_a_test_fixture_not_executable")
            output = root / "out"
            calls = []
            def command(args, *positional):
                calls.append(args)
                if args[:2] == ["cargo", "test"]:
                    return {"exit":test_exit}
                return {"exit": validation_exit if args[-1] == "validate" else 0}
            stack.enter_context(patch.dict(sys.modules, {"resource": types.SimpleNamespace(RLIMIT_CORE=4, setrlimit=lambda *a: None)}))
            stack.enter_context(patch.dict(RUN.os.environ, {"RUNNER_TEMP":str(root)}))
            stack.enter_context(patch.object(RUN, "verify_source", return_value=["pinned"]*6))
            stack.enter_context(patch.object(RUN, "git", return_value=""))
            stack.enter_context(patch.object(RUN.shutil, "copytree"))
            stack.enter_context(patch.object(RUN, "command", side_effect=command))
            stack.enter_context(patch.object(RUN, "fetch_framework"))
            metadata = stack.enter_context(patch.object(RUN, "metadata_input", return_value=private))
            android = stack.enter_context(patch.object(RUN, "prepare_android_dependency", side_effect=AssertionError("Android must not run")))
            error = None
            try:
                RUN.qualify(source, output, private_only=not loader_only, loader_only=loader_only)
            except RuntimeError as caught:
                error = str(caught)
            receipt = json.loads((output / "receipt.json").read_text())
            android.assert_not_called()
            if loader_only or test_exit:
                metadata.assert_not_called()
            return calls, receipt, error

    def test_one_validation_after_affected_native_cases_without_android_replay(self):
        calls, receipt, error = self.phase()
        self.assertIsNone(error)
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0][:2], ["cargo", "test"])
        self.assertIn("nac::tests::", calls[0])
        self.assertEqual(calls[1][:2], ["cargo", "build"])
        self.assertEqual(calls[2][-1], "validate")
        self.assertFalse(receipt["account_access"])
        self.assertEqual(receipt["production_integration"], "UNRUN")
        self.assertEqual(receipt["result"], "genuine_challenge_generated_account_acceptance_unrun")

    def test_missing_input_cannot_pass(self):
        calls, receipt, error = self.phase(private=None)
        self.assertIn("not supplied", error)
        self.assertEqual(len(calls), 2)
        self.assertEqual(receipt["private_hardware"], "UNRUN")
        self.assertEqual(receipt["result"], "failed")

    def test_rejected_validation_is_recorded_and_not_retried(self):
        calls, receipt, error = self.phase(validation_exit=2)
        self.assertIn("did not qualify", error)
        self.assertEqual(len(calls), 3)
        self.assertEqual(receipt["private_hardware"]["exit"], 2)
        self.assertEqual(receipt["result"], "failed")

    def test_loader_only_never_reads_private_input_or_runs_android(self):
        calls, receipt, error = self.phase(loader_only=True)
        self.assertIsNone(error)
        self.assertEqual(len(calls), 3)
        self.assertEqual(calls[0][:2], ["cargo", "test"])
        self.assertIn("nac::tests::", calls[0])
        self.assertEqual(calls[1][:2], ["cargo", "build"])
        self.assertEqual(calls[2][-1], "imports")
        self.assertFalse(receipt["private_input_access"])
        self.assertEqual(receipt["private_hardware"], "UNRUN")
        self.assertEqual(receipt["result"], "loader_component_qualified_private_validation_unrun")

    def test_failed_native_regression_never_reads_private_input(self):
        calls, receipt, error = self.phase(test_exit=1)
        self.assertIn("regressions failed", error)
        self.assertEqual(len(calls), 1)
        self.assertEqual(receipt["private_hardware"], "UNRUN")

if __name__ == "__main__":
    unittest.main()
