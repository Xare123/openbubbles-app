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
from unittest.mock import Mock, patch
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

    def test_owned_adb_listener_uses_supported_loopback_server_syntax(self):
        command = trial.adb_server_command()
        self.assertEqual(command, [trial.SDK/"platform-tools/adb", "-L",
                                   "tcp:localhost:5038", "server", "nodaemon"])
        self.assertNotIn("-a", command)

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

    def command_fixture(self):
        session = trial.Session.__new__(trial.Session)  # No initializer or spawn.
        session.start, session.work, session.hard = 0, 1000, 1030
        session.stop, session.check = Mock(), Mock()
        session.stop.is_set.return_value = False
        owner = dict(pid=51, start=1234, uid=1000, pgid=51)
        process = Mock(returncode=-15)
        process.poll.return_value = None
        process.wait.return_value = -15
        threads = [Mock(), Mock()]
        for thread in threads:
            thread.is_alive.return_value = False
        session.spawn = Mock(return_value=(process, owner, threads, [bytearray(), bytearray()]))
        session.commands = [dict(label="boot", owner=owner)]
        return session, process, owner, threads

    def test_command_timeout_waits_and_drains_without_retrying_mutations(self):
        for label in ("boot", "install"):
            session, process, owner, threads = self.command_fixture()
            with self.subTest(label=label), \
                    patch.object(trial.time, "monotonic", side_effect=[100]+[106]*20), \
                    patch.object(trial, "descendants", return_value=[owner]), \
                    patch.object(trial, "live_owner", return_value=False), \
                    patch.object(trial, "terminate") as terminate, \
                    self.assertRaises(trial.CommandTimeout) as caught:
                session.command(["synthetic-command"], label, seconds=5)
            self.assertEqual(caught.exception.label, label)
            terminate.assert_called_once_with([owner], trial.signal.SIGTERM)
            process.wait.assert_called_once_with(timeout=2)
            for thread in threads:
                thread.join.assert_called_once_with(timeout=1)
            session.check.assert_called_once()
            session.spawn.assert_called_once()
            self.assertEqual(session.commands[0]["interrupted"], "timeout")
            self.assertEqual(session.commands[0]["exit_code"], -15)
            self.assertIn("finished", session.commands[0])

    def test_command_timeout_kill_fallback_also_waits_before_retry_is_possible(self):
        session, process, owner, _ = self.command_fixture()
        process.returncode = -9
        process.wait.side_effect = [trial.subprocess.TimeoutExpired("synthetic-command", 2), -9]
        with patch.object(trial.time, "monotonic", side_effect=[100]+[106]*20), \
                patch.object(trial, "descendants", return_value=[owner]), \
                patch.object(trial, "live_owner", return_value=False), \
                patch.object(trial, "terminate") as terminate, \
                self.assertRaises(trial.CommandTimeout):
            session.command(["synthetic-command"], "boot", seconds=5)
        self.assertEqual([call.args[1] for call in terminate.call_args_list],
                         [trial.signal.SIGTERM, trial.signal.SIGKILL])
        self.assertEqual([call.kwargs["timeout"] for call in process.wait.call_args_list], [2, 1])
        self.assertEqual(session.commands[0]["exit_code"], -9)

    def test_command_cleanup_failure_is_not_a_retryable_timeout(self):
        session, _, owner, _ = self.command_fixture()
        with patch.object(trial.time, "monotonic", side_effect=[100]+[106]*20), \
                patch.object(trial, "descendants", return_value=[owner]), \
                patch.object(trial, "live_owner", return_value=True), \
                patch.object(trial, "terminate"), \
                self.assertRaisesRegex(RuntimeError, "command cleanup incomplete") as caught:
            session.command(["synthetic-command"], "boot", seconds=5)
        self.assertNotIsInstance(caught.exception, trial.CommandTimeout)
        session.spawn.assert_called_once()

    def test_command_output_drain_failure_is_not_a_retryable_timeout(self):
        session, _, owner, threads = self.command_fixture()
        threads[0].is_alive.return_value = True
        with patch.object(trial.time, "monotonic", side_effect=[100]+[106]*20), \
                patch.object(trial, "descendants", return_value=[owner]), \
                patch.object(trial, "live_owner", return_value=False), \
                patch.object(trial, "terminate"), \
                self.assertRaisesRegex(RuntimeError, "output drain incomplete") as caught:
            session.command(["synthetic-command"], "boot", seconds=5)
        self.assertNotIsInstance(caught.exception, trial.CommandTimeout)

    def test_command_watchdog_resource_and_global_deadline_stops_are_not_retryable(self):
        for reason, stopped in (("watchdog stopped work", True),
                                ("resource early stop", False), ("deadline exhausted", False)):
            session, _, owner, _ = self.command_fixture()
            session.stop.is_set.return_value = stopped
            session.check.side_effect = RuntimeError(reason)
            with self.subTest(reason=reason), \
                    patch.object(trial.time, "monotonic", side_effect=[100]+[106]*20), \
                    patch.object(trial, "descendants", return_value=[owner]), \
                    patch.object(trial, "live_owner", return_value=False), \
                    patch.object(trial, "terminate"), \
                    self.assertRaisesRegex(RuntimeError, reason) as caught:
                session.command(["synthetic-command"], "boot", seconds=5)
            self.assertNotIsInstance(caught.exception, trial.CommandTimeout)
            session.spawn.assert_called_once()

    def test_boot_poll_recovers_only_clean_timeout_and_requires_observed_completion(self):
        session = Mock(start=0, work=1470, observations={})
        session.adb.side_effect = [trial.CommandTimeout("boot"), (0, b"\n"), (0, b"1\n")]
        emulator = [Mock()]
        emulator[0].poll.return_value = None
        with patch.object(trial.time, "monotonic", return_value=100), \
                patch.object(trial.time, "sleep") as sleep:
            trial.wait_for_boot(session, emulator)
        self.assertEqual(session.observations, {"boot_poll_timeouts": 1})
        self.assertEqual(session.adb.call_count, 3)
        for call in session.adb.call_args_list:
            self.assertEqual(call.args, (["shell", "getprop", "sys.boot_completed"], "boot"))
            self.assertEqual(call.kwargs, dict(seconds=5, deadline=900, ok=False))
        self.assertEqual(sleep.call_count, 2)

    def test_boot_poll_never_retries_after_phase_or_global_deadline(self):
        for work, expired in ((1470, 901), (120, 121)):
            session = Mock(start=0, work=work, observations={})
            session.adb.side_effect = trial.CommandTimeout("boot")
            emulator = [Mock()]
            emulator[0].poll.return_value = None
            with self.subTest(work=work), \
                    patch.object(trial.time, "monotonic", side_effect=[100, expired]), \
                    patch.object(trial.time, "sleep") as sleep, \
                    self.assertRaisesRegex(RuntimeError, "deadline exhausted"):
                trial.wait_for_boot(session, emulator)
            session.adb.assert_called_once()
            sleep.assert_not_called()

    def test_boot_poll_does_not_retry_guard_failure_or_unrelated_command_timeout(self):
        for error in (RuntimeError("watchdog stopped work"), RuntimeError("command cleanup incomplete"),
                      RuntimeError("output drain incomplete"), trial.CommandTimeout("install")):
            session = Mock(start=0, work=1470, observations={})
            session.adb.side_effect = error
            emulator = [Mock()]
            emulator[0].poll.return_value = None
            with self.subTest(error=str(error)), \
                    patch.object(trial.time, "monotonic", return_value=100), \
                    patch.object(trial.time, "sleep") as sleep, self.assertRaises(RuntimeError):
                trial.wait_for_boot(session, emulator)
            session.adb.assert_called_once()
            sleep.assert_not_called()

    def guest_property_fixture(self):
        return {
            "ro.build.version.sdk": "30",
            "ro.build.fingerprint": "google/test/API30/revision16:userdebug/test-keys",
            "ro.product.cpu.abilist": "x86_64,x86,arm64-v8a,armeabi-v7a,armeabi",
            "ro.product.cpu.abilist64": "x86_64,arm64-v8a",
            "ro.dalvik.vm.native.bridge": "libndk_translation.so",
            "ro.dalvik.vm.isa.arm64": "x86_64",
        }

    def test_command_stderr_is_opt_in_and_returned_only_after_drain(self):
        for selected in (False, True):
            session, process, _, threads = self.command_fixture()
            process.returncode = 20
            process.poll.return_value = 20
            session.spawn.return_value[3][1].extend(b"cmd: Can't find service: package\n")
            with self.subTest(selected=selected), patch.object(trial.time, "monotonic", return_value=100):
                result = session.command(["synthetic-readonly"], "framework-package",
                                         ok=False, with_stderr=selected)
            expected = (20, b"", b"cmd: Can't find service: package\n") if selected else (20, b"")
            self.assertEqual(result, expected)
            for thread in threads:
                thread.join.assert_called_once_with(timeout=1)
            self.assertNotIn("with_stderr", session.spawn.call_args.kwargs)

    def test_framework_probe_accepts_only_observed_ready_services(self):
        self.assertTrue(trial.framework_probe_ready("package", 0, b"", b""))
        for value in (b"0\n", b"1\n", b"null\n"):
            self.assertTrue(trial.framework_probe_ready("settings", 0, value, b""))
        for service in ("package", "settings"):
            self.assertFalse(trial.framework_probe_ready(
                service, 20, b"", ("cmd: Can't find service: " + service + "\n").encode()))

    def test_framework_probe_never_accepts_unknown_error_or_existing_canary(self):
        cases = (("package", 20, b"", b""), ("package", 1, b"", b"failure"),
                 ("package", 0, b"", b"failure"),
                 ("package", 20, b"package:unexpected\n", b"cmd: Can't find service: package\n"),
                 ("package", 0, ("package:" + trial.PKG + "\n").encode(), b""),
                 ("settings", 0, b"", b""), ("settings", 0, b"garbage\n", b""),
                 ("settings", 20, b"", b"cmd: Can't find service: package\n"))
        for case in cases:
            with self.subTest(case=case), self.assertRaises(RuntimeError):
                trial.framework_probe_ready(*case)

    def framework_fixture(self):
        session = Mock(start=0, work=1470, observations={})
        emulator = [Mock()]
        emulator[0].poll.return_value = None
        return session, emulator

    def test_framework_wait_requires_both_readonly_probes(self):
        session, emulator = self.framework_fixture()
        session.adb.side_effect = [(0, b"", b""), (0, b"1\n", b"")]
        with patch.object(trial.time, "monotonic", return_value=100), \
                patch.object(trial, "framework_diagnostics") as diagnostics:
            trial.wait_for_framework(session, emulator)
        self.assertEqual(session.observations, {"framework_ready_seconds":100})
        self.assertEqual([c.args[0] for c in session.adb.call_args_list],
                         [["shell", "pm", "list", "packages", trial.PKG],
                          ["shell", "settings", "get", "global", "device_provisioned"]])
        for call in session.adb.call_args_list:
            self.assertEqual(call.kwargs, dict(seconds=15, deadline=900, ok=False, with_stderr=True))
        diagnostics.assert_not_called()

    def test_framework_wait_retries_known_missing_services_with_one_diagnostic(self):
        session, emulator = self.framework_fixture()
        missing = (20, b"", b"cmd: Can't find service: package\n")
        session.adb.side_effect = [missing, (0, b"1\n", b"")]*2 + [(0, b"", b""), (0, b"1\n", b"")]
        with patch.object(trial.time, "monotonic", return_value=100), \
                patch.object(trial.time, "sleep") as sleep, \
                patch.object(trial, "framework_diagnostics") as diagnostics:
            trial.wait_for_framework(session, emulator)
        diagnostics.assert_called_once_with(session, 900)
        self.assertEqual(sleep.call_count, 2)
        self.assertEqual(session.observations["framework_not_ready_polls"], 2)
        self.assertEqual(session.adb.call_count, 6)

    def test_framework_wait_does_not_treat_missing_settings_as_ready(self):
        session, emulator = self.framework_fixture()
        session.adb.side_effect = [(0, b"", b""), (20, b"", b"cmd: Can't find service: settings\n"),
                                  (0, b"", b""), (0, b"null\n", b"")]
        with patch.object(trial.time, "monotonic", return_value=100), \
                patch.object(trial.time, "sleep"), patch.object(trial, "framework_diagnostics"):
            trial.wait_for_framework(session, emulator)
        self.assertEqual(session.adb.call_count, 4)

    def test_framework_wait_recovers_only_clean_readonly_timeout(self):
        session, emulator = self.framework_fixture()
        session.adb.side_effect = [trial.CommandTimeout("framework-package"), (0, b"1\n", b""),
                                  (0, b"", b""), (0, b"1\n", b"")]
        with patch.object(trial.time, "monotonic", return_value=100), \
                patch.object(trial.time, "sleep"), patch.object(trial, "framework_diagnostics"):
            trial.wait_for_framework(session, emulator)
        self.assertEqual(session.observations["framework_poll_timeouts"], 1)
        self.assertEqual(session.adb.call_count, 4)

    def test_framework_wait_never_recovers_guard_or_unrelated_timeout(self):
        for error in (RuntimeError("watchdog stopped work"), RuntimeError("command cleanup incomplete"),
                      RuntimeError("output drain incomplete"), trial.CommandTimeout("install")):
            session, emulator = self.framework_fixture()
            session.adb.side_effect = error
            with self.subTest(error=str(error)), patch.object(trial.time, "monotonic", return_value=100), \
                    patch.object(trial, "framework_diagnostics") as diagnostics, self.assertRaises(RuntimeError):
                trial.wait_for_framework(session, emulator)
            session.adb.assert_called_once()
            diagnostics.assert_not_called()

    def test_framework_wait_keeps_original_boot_and_global_deadlines(self):
        for work, expired in ((1470, 901), (120, 121)):
            session, emulator = self.framework_fixture()
            session.work = work
            with self.subTest(work=work), patch.object(trial.time, "monotonic", return_value=expired), \
                    self.assertRaisesRegex(RuntimeError, "deadline exhausted"):
                trial.wait_for_framework(session, emulator)
            session.adb.assert_not_called()

    def test_framework_wait_rechecks_deadline_and_emulator_before_accepting_ready(self):
        session, emulator = self.framework_fixture()
        session.adb.side_effect = [(0, b"", b""), (0, b"1\n", b"")]
        with patch.object(trial.time, "monotonic", side_effect=[100, 901]), \
                self.assertRaisesRegex(RuntimeError, "deadline exhausted"):
            trial.wait_for_framework(session, emulator)
        self.assertNotIn("framework_ready_seconds", session.observations)
        session, emulator = self.framework_fixture()
        session.adb.side_effect = [(0, b"", b""), (0, b"1\n", b"")]
        emulator[0].poll.side_effect = [None, 1]
        with patch.object(trial.time, "monotonic", return_value=100), \
                self.assertRaisesRegex(RuntimeError, "emulator exited"):
            trial.wait_for_framework(session, emulator)
        self.assertNotIn("framework_ready_seconds", session.observations)

    def test_framework_diagnostics_are_bounded_readonly_and_do_not_retry(self):
        session, _ = self.framework_fixture()
        session.adb.side_effect = [(0, b""), trial.CommandTimeout("framework-diagnostic-processes"), (0, b"")]
        with patch.object(trial.time, "monotonic", return_value=100):
            trial.framework_diagnostics(session, 900)
        self.assertEqual(session.adb.call_count, 3)
        self.assertTrue(session.observations["framework-diagnostic-processes"]["clean_timeout"])
        for call in session.adb.call_args_list:
            self.assertEqual(call.kwargs, dict(seconds=15, deadline=900, ok=False, limit=trial.MiB))

    def test_guest_properties_use_one_bounded_readonly_snapshot(self):
        expected = self.guest_property_fixture()
        snapshot = "\r\n".join(f"[{key}]: [{value}]" for key, value in expected.items())
        snapshot += "\r\n[other.property]: [ignored value]\r\n"
        session = Mock()
        session.adb.return_value = (0, snapshot.encode())
        self.assertEqual(trial.guest_properties(session), expected)
        session.adb.assert_called_once_with(["shell", "getprop"], "guest-properties",
                                            seconds=30, limit=256*1024)

    def test_guest_properties_accept_real_multiline_unrelated_boot_history(self):
        expected = self.guest_property_fixture()
        # Exact two-line shape captured in GCE37421427606, not an Android mock
        # qualification. The required immutable identity rows remain strict.
        snapshot = "[persist.sys.boot.reason.history]: [reboot,factory_reset,1791267155\nreboot,1791266824]\n"
        snapshot += "[ro.product.cpu.abilist32]: [x86,armeabi-v7a,armeabi]\n"
        snapshot += "\n".join(f"[{key}]: [{value}]" for key, value in expected.items())
        session = Mock()
        session.adb.return_value = (0, snapshot.encode())
        self.assertEqual(trial.guest_properties(session), expected)
        session.adb.assert_called_once()

    def test_guest_properties_reject_malformed_selected_rows_even_after_valid_rows(self):
        expected = self.guest_property_fixture()
        baseline = "\n".join(f"[{key}]: [{value}]" for key, value in expected.items())
        for key, value in expected.items():
            for extra in (f"[{key}]: {value}", f"[{key}]: [{value}] trailing",
                          f"[{key}] [{value}]"):
                session = Mock()
                session.adb.return_value = (0, (baseline+"\n"+extra).encode())
                with self.subTest(key=key, extra=extra), self.assertRaisesRegex(RuntimeError, "malformed"):
                    trial.guest_properties(session)
                session.adb.assert_called_once()

    def test_guest_properties_reject_multiline_required_identity_values(self):
        for key in trial.GUEST_PROPERTY_KEYS:
            expected = self.guest_property_fixture()
            expected[key] += "\ncontinued"
            snapshot = "\n".join(f"[{name}]: [{value}]" for name, value in expected.items())
            session = Mock()
            session.adb.return_value = (0, snapshot.encode())
            with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, "malformed"):
                trial.guest_properties(session)
            session.adb.assert_called_once()

    def test_guest_properties_reject_each_missing_required_identity_key(self):
        for missing in trial.GUEST_PROPERTY_KEYS:
            snapshot = "\n".join(f"[{key}]: [{value}]" for key, value
                                 in self.guest_property_fixture().items() if key != missing)
            session = Mock()
            session.adb.return_value = (0, snapshot.encode())
            with self.subTest(missing=missing), self.assertRaisesRegex(RuntimeError, "incomplete"):
                trial.guest_properties(session)
            session.adb.assert_called_once()

    def test_guest_properties_reject_duplicate_identity_even_if_values_match(self):
        snapshot = "\n".join(f"[{key}]: [{value}]" for key, value in self.guest_property_fixture().items())
        for extra in ("[ro.build.version.sdk]: [30]", "[ro.build.version.sdk]: [31]"):
            session = Mock()
            session.adb.return_value = (0, (snapshot+"\n"+extra).encode())
            with self.subTest(extra=extra), self.assertRaisesRegex(RuntimeError, "duplicate"):
                trial.guest_properties(session)
            session.adb.assert_called_once()

    def test_guest_properties_reject_malformed_failed_or_timed_out_reads_without_retry(self):
        for code, snapshot in ((0, b"not a property"), (0, b"\xff"), (1, b""), (0, b"")):
            session = Mock()
            session.adb.return_value = (code, snapshot)
            with self.subTest(code=code, snapshot=snapshot), \
                    self.assertRaises((RuntimeError, UnicodeDecodeError)):
                trial.guest_properties(session)
            session.adb.assert_called_once()
        session = Mock()
        session.adb.side_effect = trial.CommandTimeout("guest-properties")
        with self.assertRaises(trial.CommandTimeout):
            trial.guest_properties(session)
        session.adb.assert_called_once()

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

    def test_free_space_uses_configured_runtime_filesystem_before_root_exists(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            parent = Path(tmp)
            for root in (parent, parent/"new"/"runtime"):
                with self.subTest(root=root), patch.object(trial, "ROOT", root), \
                        patch.object(trial.os, "statvfs") as statvfs:
                    statvfs.return_value = Mock(f_bavail=23, f_frsize=4096)
                    self.assertEqual(trial.free_bytes(), 23*4096)
                    statvfs.assert_called_once_with(parent)

    def test_free_space_errors_are_not_invented_as_available_capacity(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp, \
                patch.object(trial, "ROOT", Path(tmp)), \
                patch.object(trial.os, "statvfs", side_effect=PermissionError(13, "denied")):
            with self.assertRaises(PermissionError):
                trial.free_bytes()

    def test_initial_watchdog_measurement_failure_retains_a_fatal_receipt(self):
        parent = dict(pid=51, start=1234, uid=1000, pgid=51)
        connection, stop, receipt = Mock(), Mock(), Mock()
        connection.poll.return_value = True
        connection.recv.return_value = "finished"
        with patch.object(trial.os, "setsid"), \
                patch.object(trial, "free_bytes", side_effect=FileNotFoundError(2, "missing", "/absent")), \
                patch.object(trial, "identity", return_value=parent), \
                patch.object(trial.time, "monotonic", return_value=0), \
                patch.object(trial, "descendants", return_value=[]), \
                patch.object(trial, "terminate"), patch.object(trial, "immutable", receipt):
            trial.watchdog(parent, connection, "prepare", 10, 40, stop)
        stop.set.assert_called_once()
        saved = receipt.call_args.args[1]
        self.assertEqual(saved["fatal_error"]["stage"], "initial_free_bytes")
        self.assertEqual(saved["fatal_error"]["errno"], 2)
        self.assertIsNone(saved["peaks"]["free_min"])
        self.assertIsNone(saved["overshoot"])
        self.assertEqual(saved["stop_reason"], "watchdog error: FileNotFoundError")

    def test_listener_classification_accepts_only_native_and_mapped_loopback(self):
        for address in ("127.0.0.1", "127.255.255.254", "::1", "::ffff:7f00:1",
                        "::ffff:127.0.0.1", "::ffff:127.255.255.254"):
            with self.subTest(address=address):
                self.assertTrue(trial.is_loopback_listener(address))
        for address in ("0.0.0.0", "::", "::ffff:0.0.0.0", "10.0.0.1",
                        "::ffff:10.0.0.1", "192.168.1.1", "::ffff:192.168.1.1",
                        "169.254.1.1", "::ffff:169.254.1.1", "8.8.8.8",
                        "::ffff:8.8.8.8", "2001:4860:4860::8888",
                        "::127.0.0.1", "64:ff9b::7f00:1", "::ffff:126.255.255.255"):
            with self.subTest(address=address):
                self.assertFalse(trial.is_loopback_listener(address))

    def test_listener_classification_invalid_address_fails_closed(self):
        for address in ("", "localhost", "127.0.0.1:5038", "not-an-address"):
            with self.subTest(address=address), self.assertRaises(ValueError):
                trial.is_loopback_listener(address)

    def test_mapped_loopback_does_not_trigger_watchdog_stop(self):
        parent = dict(pid=51, start=1234, uid=1000, pgid=51)
        owner = dict(pid=52, start=1235, uid=1000, pgid=52)
        rows = [dict(address="::ffff:7f00:1", port=39639, inode="22914", uid=1000)]
        connection, stop, receipt, terminate = Mock(), Mock(), Mock(), Mock()
        connection.poll.side_effect = [False, True]
        connection.recv.return_value = "finished"
        stop.is_set.return_value = False
        with patch.object(trial.os, "setsid"), \
                patch.object(trial, "free_bytes", return_value=20*trial.GiB), \
                patch.object(trial, "identity", return_value=parent), \
                patch.object(trial, "session_owners", return_value=[owner]), \
                patch.object(trial, "outside_writable_bytes", return_value=0), \
                patch.object(trial, "tree_bytes", return_value=0), \
                patch.object(trial, "owned_listeners", return_value=rows), \
                patch.object(trial.time, "monotonic", return_value=0), \
                patch.object(trial.time, "sleep"), \
                patch.object(trial, "terminate", terminate), \
                patch.object(trial, "immutable", receipt):
            trial.watchdog(parent, connection, "trial", 10, 40, stop)
        saved = receipt.call_args.args[1]
        self.assertIsNone(saved["stop_reason"])
        self.assertIsNone(saved["rejected_owned_tcp_listeners"])
        stop.set.assert_not_called()
        terminate.assert_not_called()

    def test_rejected_owned_listener_is_retained_and_bounded_without_weakening_stop(self):
        parent = dict(pid=51, start=1234, uid=1000, pgid=51)
        owner = dict(pid=52, start=1235, uid=1000, pgid=52)
        rows = [dict(address="0.0.0.0", port=60000+i, inode=str(i), uid=1000)
                for i in range(20)]
        connection, stop, receipt, terminate = Mock(), Mock(), Mock(), Mock()
        connection.poll.side_effect = [False, True]
        connection.recv.return_value = "finished"
        stop.is_set.return_value = False
        with patch.object(trial.os, "setsid"), \
                patch.object(trial, "free_bytes", return_value=20*trial.GiB), \
                patch.object(trial, "identity", return_value=parent), \
                patch.object(trial, "session_owners", return_value=[owner]), \
                patch.object(trial, "outside_writable_bytes", return_value=0), \
                patch.object(trial, "tree_bytes", return_value=0), \
                patch.object(trial, "owned_listeners", return_value=rows), \
                patch.object(trial.time, "monotonic", return_value=0), \
                patch.object(trial.time, "sleep"), \
                patch.object(trial, "terminate", terminate), \
                patch.object(trial, "immutable", receipt):
            trial.watchdog(parent, connection, "trial", 10, 40, stop)
        saved = receipt.call_args.args[1]
        self.assertEqual(saved["stop_reason"], "non-loopback owned TCP listener")
        self.assertEqual(saved["rejected_owned_tcp_listeners"], dict(count=20, rows=rows[:16]))
        stop.set.assert_called_once()
        terminate.assert_called_once_with([owner], trial.signal.SIGTERM)

    def test_closed_watchdog_pipe_and_failed_final_measurement_preserve_failure(self):
        with tempfile.TemporaryDirectory(dir=HERE) as tmp:
            run = Path(tmp)
            trial.immutable(run/"prepare.watchdog.json", {"stop_reason":"watchdog error: FileNotFoundError"})
            session = trial.Session.__new__(trial.Session)  # No initializer or process spawn.
            session.parent, session.owners, session.jobs = {}, [], []
            session.watch, session.send = Mock(), Mock()
            session.watch.pid, session.watch_owner = 52, {}
            session.watch.is_alive.return_value = False
            session.send.send.side_effect = BrokenPipeError(32, "closed")
            session.phase, session.hard, session.start = "prepare", 1000, 0
            session.commands, session.observations = [], {}
            report = dict(result="interrupted_or_failed", error="original preparation failure")
            with patch.object(trial, "RUN", run), \
                    patch.object(trial, "session_owners", return_value=[]), \
                    patch.object(trial, "terminate"), patch.object(trial, "listeners", return_value=[]), \
                    patch.object(trial, "tree_bytes", return_value=0), \
                    patch.object(trial.time, "monotonic", return_value=100), \
                    patch.object(trial, "free_bytes", side_effect=FileNotFoundError(2, "missing", "/absent")):
                session.finish(report)
            saved = json.loads((run/"prepare.result.json").read_text())
            self.assertEqual(saved["error"], "original preparation failure")
            self.assertEqual(saved["watchdog_pipe_failure"]["errno"], 32)
            self.assertEqual(saved["final_resource_error"]["errno"], 2)
            self.assertIsNone(saved["free_bytes"])
            self.assertFalse(saved["cleanup_verified"])
            self.assertEqual(saved["result"], "stopped_by_watchdog_or_cleanup_guard")

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
