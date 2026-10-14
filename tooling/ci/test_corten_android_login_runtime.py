"""Credential-free orchestration contracts, not Android execution evidence."""
import argparse
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import run_corten_android_login_runtime as R


class RuntimeTests(unittest.TestCase):
    def test_network_runs_in_guest_with_normal_positional_mode(self):
        cmd = R.adb_command(Path('/sdk'), 'shell', '/data/local/tmp/ob-network', 'network')
        self.assertEqual(cmd[-3:], ['shell', '/data/local/tmp/ob-network', 'network'])

    def test_isolated_adb_and_explicit_acceleration(self):
        cmd = R.adb_command(Path('/sdk'), 'shell', 'getprop')
        self.assertIn('127.0.0.1', cmd)
        self.assertIn('5039', cmd)
        self.assertIn('emulator-5558', cmd)
        for mode in ('on', 'off'):
            cmd = R.emulator_command(Path('/sdk'), 'owned', mode)
            self.assertEqual(cmd[cmd.index('-accel') + 1], mode)
            self.assertNotIn('-dns-server', cmd)
        with self.assertRaises(RuntimeError):
            R.emulator_command(Path('/sdk'), 'owned', 'auto')

    def test_network_success_requires_actual_certificate_and_completion(self):
        raw = b'{"step":"public_network","certificate_bytes":900}\n{"step":"complete"}\n'
        self.assertEqual(R.network_result(0, raw)['status'], 'PASS')
        for code, output in ((1, raw), (0, raw.splitlines()[0]), (0, b'host works'),
                             (0, raw.replace(b'900', b'0'))):
            self.assertEqual(R.network_result(code, output)['status'], 'FAIL')

    def test_vulkan_fallback_is_explicit_and_keeps_normal_dns(self):
        regular = R.emulator_command(Path('/sdk'), 'owned', 'on')
        fallback = R.emulator_command(Path('/sdk'), 'owned', 'on', True)
        self.assertNotIn('-Vulkan', regular)
        self.assertEqual(fallback[-2:], ['-feature', '-Vulkan'])
        self.assertNotIn('-dns-server', fallback)

    def test_guest_crash_stream_starts_before_launch_and_disconnection_is_distinct(self):
        source = Path(R.__file__).read_text()
        self.assertLess(source.index('runner.spawn("guest-startup-live"'),
                        source.index('runner.adb("launch"'))
        self.assertIn('host emulator exited during app launch; not an app-only failure', source)
        self.assertIn('Android connection lost during app launch; app status unknown', source)
        self.assertIn('processes_before_cleanup', source)

    def test_software_renderer_uses_standard_flutter_debug_launch_extras(self):
        source = Path(R.__file__).read_text()
        self.assertIn('"--ez", "enable-software-rendering", "true"', source)
        self.assertIn('"--ez", "enable-impeller", "false"', source)
        self.assertIn('if args.flutter_software_rendering else []', source)

    def test_live_process_alone_does_not_qualify_app(self):
        result = R.app_result(b'', b'', b'', b'', True, True)
        self.assertEqual(result['status'], 'FAIL')

    def test_focus_uses_full_service_and_private_hold_stops_log_capture(self):
        source = Path(R.__file__).read_text()
        self.assertIn('runner.adb("windows", "shell", "dumpsys", "window")', source)
        self.assertIn('0 <= args.hold_seconds <= 1800', source)
        self.assertLess(source.index('require(stop_owned(log_stream)'),
                        source.index('(out / "session-ready.json")'))

    def test_app_requires_open_database_native_libraries_and_no_startup_failure(self):
        maps = b'libflutter.so librust_lib_bluebubbles.so libobjectbox-jni.so objectbox/data.mdb'
        db = b'app_flutter/objectbox/data.mdb:16384:32'
        self.assertEqual(R.app_result(maps, b'', db, b'', True, True)['status'], 'PASS')
        cases = ((maps, b'', db, b'dlopen failed', True, True),
                 (maps, b'', db, b'', False, True),
                 (maps, b'', db, b'', True, False),
                 (maps.replace(b'libobjectbox-jni.so', b''), b'', db, b'', True, True),
                 (maps.replace(b'objectbox/data.mdb', b''), b'', db, b'', True, True))
        for args in cases:
            self.assertEqual(R.app_result(*args)['status'], 'FAIL')

    def test_only_canary_activity_is_accepted(self):
        activity = R.PACKAGE + '/.MainActivity'
        self.assertEqual(R.resolve_activity(('extra\n' + activity).encode()), activity)
        for invalid in (b'com.other/.MainActivity', (activity + ';bad').encode()):
            with self.assertRaises(RuntimeError):
                R.resolve_activity(invalid)

    def _cleanup_case(self, *, term_delay=None, kill_delay=None, gone=False,
                      parent_exit_at=0, parent_missing=False):
        proc = Mock(pid=401, returncode=None, _ob_owned_pgid=401)
        now, gone_at, signals = [0.0], [0.0 if gone else None], []

        def poll():
            if now[0] >= parent_exit_at:
                proc.returncode = 0
            return proc.returncode

        def signal_group(group, sig):
            self.assertEqual(group, 401)
            if gone_at[0] is not None and now[0] >= gone_at[0]:
                raise ProcessLookupError()
            if sig:
                signals.append((sig, now[0]))
                delay = term_delay if sig == R.signal.SIGTERM else kill_delay
                if delay is not None:
                    gone_at[0] = now[0] + delay

        proc.poll.side_effect = poll
        with patch.object(R.signal, 'SIGKILL', 9, create=True), \
             patch.object(R.os, 'getpgrp', return_value=999, create=True), \
             patch.object(R.os, 'getpgid', return_value=401,
                          side_effect=ProcessLookupError() if parent_missing else None, create=True), \
             patch.object(R.os, 'killpg', side_effect=signal_group, create=True) as kill, \
             patch.object(R.time, 'monotonic', side_effect=lambda: now[0]), \
             patch.object(R.time, 'sleep', side_effect=lambda delay: now.__setitem__(0, now[0] + delay)):
            result = R.stop_owned(proc)
            if result:
                calls = kill.call_count
                self.assertTrue(R.stop_owned(proc))
                self.assertEqual(kill.call_count, calls)  # Never signal a reused group on repeat.
        return result, signals, now[0], proc

    def test_cleanup_waits_for_descendants_after_parent_already_exited(self):
        result, signals, elapsed, proc = self._cleanup_case(term_delay=20, parent_missing=True)
        self.assertTrue(result)
        self.assertEqual([sig for sig, _ in signals], [R.signal.SIGTERM])
        self.assertGreaterEqual(elapsed, 20)
        self.assertLessEqual(elapsed, R.TERM_GRACE_SECONDS)
        self.assertIsNotNone(proc.returncode)

    def test_cleanup_reaps_parent_but_waits_for_delayed_group_exit(self):
        result, signals, elapsed, _ = self._cleanup_case(term_delay=20, parent_exit_at=1)
        self.assertTrue(result)
        self.assertEqual(len(signals), 1)
        self.assertGreaterEqual(elapsed, 20)

    def test_cleanup_escalates_only_after_grace_and_waits_after_kill(self):
        result, signals, elapsed, _ = self._cleanup_case(kill_delay=2)
        self.assertTrue(result)
        self.assertEqual([sig for sig, _ in signals], [R.signal.SIGTERM, 9])
        self.assertEqual(signals[1][1], R.TERM_GRACE_SECONDS)
        self.assertGreaterEqual(elapsed, R.TERM_GRACE_SECONDS + 2)

    def test_cleanup_surviving_group_stays_failure_with_bounded_wait(self):
        result, signals, elapsed, _ = self._cleanup_case()
        self.assertFalse(result)
        self.assertEqual(len(signals), 2)
        self.assertEqual(elapsed, R.TERM_GRACE_SECONDS + R.KILL_GRACE_SECONDS)

    def test_cleanup_already_gone_is_idempotent_without_signalling(self):
        result, signals, elapsed, _ = self._cleanup_case(gone=True, parent_missing=True)
        self.assertTrue(result)
        self.assertEqual(signals, [])
        self.assertEqual(elapsed, 0)

    def test_cleanup_refuses_unowned_invalid_or_current_group(self):
        with patch.object(R.os, 'getpgrp', return_value=999, create=True), \
             patch.object(R.os, 'killpg', create=True) as kill:
            for group in (None, 0, 1, -401, True, '401', 999, R.os.getpid()):
                proc = Mock(pid=group, returncode=0, _ob_owned_pgid=group)
                self.assertFalse(R.stop_owned(proc))
            self.assertFalse(R.stop_owned(Mock(pid=401, returncode=0)))
            kill.assert_not_called()

    def test_cleanup_refuses_changed_group_or_inaccessible_group(self):
        with patch.object(R.os, 'getpgrp', return_value=999, create=True), \
             patch.object(R.os, 'getpgid', return_value=402, create=True), \
             patch.object(R.os, 'killpg', create=True) as kill:
            self.assertFalse(R.stop_owned(Mock(pid=401, returncode=0, _ob_owned_pgid=401)))
            kill.assert_not_called()
        with patch.object(R.os, 'getpgrp', return_value=999, create=True), \
             patch.object(R.os, 'getpgid', return_value=401, create=True), \
             patch.object(R.os, 'killpg', side_effect=PermissionError(), create=True) as kill:
            self.assertFalse(R.stop_owned(Mock(pid=401, returncode=0, _ob_owned_pgid=401)))
            self.assertEqual([call.args[1] for call in kill.call_args_list], [0])

    def test_non_linux_execution_is_refused_before_creating_output(self):
        with patch.object(R.sys, 'platform', 'win32'):
            with self.assertRaisesRegex(RuntimeError, 'Linux runner'):
                R.qualify(argparse.Namespace())

    def test_command_has_single_input_source_and_timeout_cleans_owned_child(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root)
            runner = R.Runner(path, path, path)
            child = Mock(returncode=0)
            with patch.object(R.subprocess, 'Popen', return_value=child) as spawn:
                runner.call(None, ['test'], data=b'no\n')
                self.assertEqual(spawn.call_args.kwargs['stdin'], subprocess.PIPE)
                self.assertTrue(spawn.call_args.kwargs['start_new_session'])
                self.assertEqual(child._ob_owned_pgid, child.pid)
                child.communicate.assert_called_once()
            child.communicate.side_effect = subprocess.TimeoutExpired('test', 1)
            with patch.object(R.subprocess, 'Popen', return_value=child), patch.object(R, 'stop_owned') as stop:
                with self.assertRaises(subprocess.TimeoutExpired):
                    runner.call(None, ['test'])
                stop.assert_called_once_with(child)


if __name__ == '__main__':
    unittest.main()
