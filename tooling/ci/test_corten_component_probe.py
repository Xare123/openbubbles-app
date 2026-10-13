"""Credential-free orchestration guards, not native or account qualification."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
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

if __name__ == "__main__":
    unittest.main()
