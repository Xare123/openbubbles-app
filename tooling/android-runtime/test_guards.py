"""Pure guard tests: no Session, SDK execution, network, boot, or process spawn."""
import hashlib
import importlib.util
import contextlib
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("trial_guards", HERE / "trial.py")
trial = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trial)


class Guards(unittest.TestCase):
    def test_exact_gce_prepare_and_trial_requests_are_admitted(self):
        for phase in ("prepare", "trial"):
            request = f"OB-GCE-APK-802E92-37370562658-{phase.upper()}-T"
            parsed = trial.parse_request([phase, "--request-id", request])
            self.assertEqual(parsed.phase, phase)
            self.assertEqual(parsed.request_id, request)
            with self.assertRaises(RuntimeError):
                trial.parse_request([phase, "--request-id", request.removesuffix("-T")])

    def test_cli_rejects_abbreviated_flag_and_invalid_phase(self):
        request = "OB-GCE-APK-802E92-37370562658-TRIAL-T"
        for argv in (["trial", "--request", request], ["replay", "--request-id", request]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                trial.parse_request(argv)

    def test_ownership_rejects_reused_pid_and_changed_uid_or_group(self):
        original = dict(pid=51, start=1234, uid=1000, pgid=51)
        self.assertTrue(trial.same_owner(original, dict(original, state="S")))
        for key in original:
            with self.subTest(key=key):
                self.assertFalse(trial.same_owner(original, dict(original, **{key:9999})))
        self.assertFalse(trial.same_owner(original, None))

    def test_deadline_clips_to_phase_then_global(self):
        self.assertEqual(trial.clip(100, 30, 110, 200), 10)
        self.assertEqual(trial.clip(100, 30, 200, 103), 3)
        self.assertEqual(trial.clip(100, 2, 200, 300), 2)
        self.assertAlmostEqual(trial.clip(99.9, 30, 100), .1)

    def test_expired_deadline_never_returns_a_retry_interval(self):
        for now in (100, 101):
            with self.assertRaisesRegex(RuntimeError, "deadline"):
                trial.clip(now, 30, 100)

    def test_early_resource_stops_leave_cleanup_reserve(self):
        G, M = trial.GiB, trial.MiB
        self.assertEqual(trial.resource_reasons(20*G, G, M), [])
        self.assertEqual(trial.resource_reasons(6.5*G, G, M), ["free-space"])
        self.assertEqual(trial.resource_reasons(20*G, 7*G, M), ["AVD/TMP allocation"])
        self.assertEqual(trial.resource_reasons(20*G, G, 224*M), ["logs/evidence"])
        self.assertEqual(trial.resource_reasons(6.4*G, 7.5*G, 240*M, False), [])

    def test_actual_hard_threshold_overshoot_is_reportable(self):
        G, M = trial.GiB, trial.MiB
        self.assertEqual(len(trial.resource_reasons(5.9*G, 8.1*G, 257*M, False)), 3)

    def entry(self, name, size=3, mode=stat.S_IFREG | 0o644):
        item = zipfile.ZipInfo(name)
        item.file_size = size
        item.external_attr = mode << 16
        return item

    def test_zip_rejects_traversal_absolute_and_wrong_root(self):
        for path in ("../bad", "/x86_64/a", "x86_64/../bad", "x86_64\\bad", "arm64/a"):
            with self.subTest(path=path), self.assertRaises(RuntimeError):
                trial.zip_plan([self.entry(path)], 3)

    def test_zip_rejects_links_special_modes_and_encryption(self):
        for mode in (stat.S_IFLNK|0o777, stat.S_IFIFO|0o644, stat.S_IFREG|0o4755):
            with self.subTest(mode=mode), self.assertRaises(RuntimeError):
                trial.zip_plan([self.entry("x86_64/a", mode=mode)], 3)
        encrypted = self.entry("x86_64/a")
        encrypted.flag_bits = 1
        with self.assertRaises(RuntimeError):
            trial.zip_plan([encrypted], 3)

    def test_zip_rejects_duplicates_and_wrong_expansion(self):
        a = self.entry("x86_64/a")
        with self.assertRaisesRegex(RuntimeError, "duplicate"):
            trial.zip_plan([a, a], 6)
        for size in (2, 4):
            with self.subTest(size=size), self.assertRaisesRegex(RuntimeError, "expansion"):
                trial.zip_plan([a], size)
        trial.zip_plan([a, self.entry("x86_64/bin", 2, stat.S_IFREG|0o755)], 5)

    def test_file_gate_rejects_size_hash_and_symlink(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            root = Path(tmp)
            p = root/"artifact"
            p.write_bytes(b"qualified")
            expected = hashlib.sha256(b"qualified").hexdigest()
            self.assertEqual(trial.check_file(p, 9, "sha256", expected), expected)
            with self.assertRaisesRegex(RuntimeError, "size"):
                trial.check_file(p, 8, "sha256", expected)
            with self.assertRaisesRegex(RuntimeError, "hash"):
                trial.check_file(p, 9, "sha256", "0"*64)
            link = root/"link"
            link.symlink_to(p)
            with self.assertRaisesRegex(RuntimeError, "symlink"):
                trial.check_file(link, 9, "sha256", expected)

    def test_attempt_receipt_survives_interruption_and_replay(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            p = Path(tmp)/"trial.attempt.json"
            trial.immutable(p, {"request":"T", "state":"started"})
            before = p.read_bytes()
            with self.assertRaises(FileExistsError):
                trial.immutable(p, {"state":"retry"})
            self.assertEqual(p.read_bytes(), before)
            # A failed final receipt remains distinct; neither may be overwritten.
            result = Path(tmp)/"trial.result.json"
            trial.immutable(result, {"result":"failed"})
            with self.assertRaises(FileExistsError):
                trial.immutable(result, {"result":"success"})
            self.assertEqual(json.loads(result.read_text())["result"], "failed")
            self.assertEqual(p.read_bytes(), before)

    def test_startup_requires_info_completion_without_debug_marker(self):
        self.assertEqual(trial.startup_log_assessment(b"[INFO] Startup tasks completed"), (True, False))
        self.assertEqual(trial.startup_log_assessment(b"[DEBUG] MethodChannelService initialized"), (False, False))

    def test_caught_migration_and_startup_task_errors_reject_clean_startup(self):
        for error in (b"Failed to perform database migrations!", b"Failed to complete startup tasks!"):
            with self.subTest(error=error):
                later, errors = trial.startup_log_assessment(b"[INFO] Startup tasks completed\n[ERROR] " + error)
                self.assertTrue(later)
                self.assertTrue(errors)
                self.assertFalse(later and not errors)

    def test_watchdog_error_retains_stage_errno_path_and_traceback(self):
        try:
            raise PermissionError(13, "Permission denied", "/proc/123/fdinfo/4")
        except PermissionError as exc:
            detail = trial.watchdog_error_detail("outside_writable_bytes", exc)
        self.assertEqual(detail["stage"], "outside_writable_bytes")
        self.assertEqual(detail["type"], "PermissionError")
        self.assertEqual(detail["errno"], 13)
        self.assertEqual(detail["filename"], "/proc/123/fdinfo/4")
        self.assertIn("Permission denied", detail["error"])
        self.assertIn("test_watchdog_error_retains_stage_errno_path_and_traceback", detail["traceback"])
        self.assertIn("PermissionError", detail["traceback"])

    def test_watchdog_error_bounds_and_redacts_all_text_fields(self):
        url = "https://fake-user:fake-password@example.test/file?sig=fake-signature"
        exc = PermissionError(13, url + "\nAuthorization: Bearer fake-token\n" + "x"*20000, url)
        detail = trial.watchdog_error_detail("s"*1000, exc)
        for field, limit in {"stage":128, "filename":2048, "error":1000, "traceback":8192}.items():
            self.assertLessEqual(len(detail[field]), limit)
        for secret in ("fake-user", "fake-password", "fake-signature", "fake-token"):
            self.assertNotIn(secret, json.dumps(detail))
        self.assertEqual(detail["errno"], 13)

    def test_network_failure_retains_nested_errno_without_sensitive_urls(self):
        reason = PermissionError(1, "Operation not permitted")
        error = trial.urllib.error.URLError(reason)
        detail = trial.failure_diagnostics(error, "prepare")
        self.assertEqual(detail["failure_detail"]["stage"], "main_prepare")
        self.assertEqual(detail["failure_detail"]["type"], "URLError")
        self.assertEqual(detail["reason_detail"]["type"], "PermissionError")
        self.assertEqual(detail["reason_detail"]["errno"], 1)
        sensitive = trial.urllib.error.URLError(
            RuntimeError("https://fake-user:fake-password@example.test/file?sig=fake-signature"))
        safe = json.dumps(trial.failure_diagnostics(sensitive, "prepare"))
        for secret in ("fake-user", "fake-password", "fake-signature"):
            self.assertNotIn(secret, safe)

    def test_redaction_removes_signed_queries_and_auth_values(self):
        line = "https://a:b@host.example/path?sig=private Authorization: secret-value"
        safe = trial.redact(line)
        self.assertNotIn("private", safe)
        self.assertNotIn("a:b", safe)
        self.assertNotIn("secret-value", safe)
        self.assertIn("host.example/path", safe)


if __name__ == "__main__":
    unittest.main(verbosity=2)
