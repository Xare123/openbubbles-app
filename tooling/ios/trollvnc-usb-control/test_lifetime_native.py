"""Execute the manager's real lifetime header on the bounded Mac build host."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == "darwin", "real Darwin dispatch/process APIs required")
class NativeLifetimeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="ob-usb-lifetime-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.exe = Path(cls.temp.name) / "lifetime-tests"
        source = Path(__file__).with_name("test_lifetime_native.c")
        subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-fblocks", str(source),
                        "-o", str(cls.exe)], check=True, timeout=30, capture_output=True)

    def run_case(self, name, expected):
        result = subprocess.run([str(self.exe), name], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), expected)

    def test_actual_owner_exit_closes_watch(self):
        self.run_case("owner-exit", "owner-exit-passed")

    def test_actual_timer_closes_watch(self):
        self.run_case("deadline", "deadline-passed")

    def test_cancel_does_not_invoke_stop(self):
        self.run_case("cancel", "cancel-passed")

    def test_duplicate_does_not_renew_timer(self):
        self.run_case("duplicate", "deadline-passed")

    def test_invalid_owners_and_limits_are_rejected(self):
        for name in ("reject-pid", "reject-path", "reject-zero", "reject-limit"):
            with self.subTest(name=name):
                self.run_case(name, "rejected-before-watch-passed")


if __name__ == "__main__":
    unittest.main()
