"""Source contracts only; the separate hosted run executes a real emulator."""
from pathlib import Path
import unittest
import run_corten_android_cleanup as cleanup
import run_corten_android_login_runtime as runtime


class CleanupTests(unittest.TestCase):
    def test_pass_requires_boot_and_three_distinct_stopped_owned_groups(self):
        rows = [{"pid": number, "exited": True} for number in (101, 102, 103)]
        self.assertTrue(cleanup.qualified(True, rows))
        for booted, values in ((False, rows), (True, []), (True, rows[:2]),
                               (True, rows + rows[:1]), (True, [rows[0]] * 3),
                               (True, rows[:2] + [{"pid": 103, "exited": False}])):
            self.assertFalse(cleanup.qualified(booted, values))

    def test_no_truthy_status_or_invalid_process_identity_passes(self):
        for value in (0, 1, True, "103", None):
            rows = [{"pid": 101, "exited": True}, {"pid": 102, "exited": True},
                    {"pid": value, "exited": True}]
            self.assertFalse(cleanup.qualified(True, rows))
        self.assertFalse(cleanup.qualified(True, [
            {"pid": i, "exited": "true"} for i in (101, 102, 103)]))

    def test_actual_runtime_start_and_cleanup_are_shared(self):
        source = Path(cleanup.__file__).read_text()
        self.assertIn('runtime.boot_owned_runtime(runner, "on", True)', source)
        self.assertIn('runner.cleanup()', source)
        app_source = Path(runtime.__file__).read_text()
        self.assertIn('boot_owned_runtime(runner, args.accel, args.disable_vulkan)', app_source)

    def test_hosted_job_has_no_build_or_personal_input(self):
        workflow = Path(__file__).resolve().parents[2] / '.github/workflows/gce-runner-pilot.yml'
        source = workflow.read_text()
        job = source.split('  corten-android-cleanup:', 1)[1].split('  corten-android-login:', 1)[0]
        self.assertIn('run_corten_android_cleanup.py', job)
        for forbidden in ('secrets.', 'gcloud', 'flutter build', 'cargo build',
                          '--hold-seconds', 'private_auth_input', 'submodules: recursive'):
            self.assertNotIn(forbidden, job)
        create = source.split('  create-runner:', 1)[1].split('    runs-on:', 1)[0]
        self.assertIn("inputs.validation_mode != 'corten-android-cleanup-only'", create)


if __name__ == '__main__':
    unittest.main(verbosity=2)
