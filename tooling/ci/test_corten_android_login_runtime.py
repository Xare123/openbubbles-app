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

    def test_cleanup_checks_actual_owned_group_not_empty_registry(self):
        proc = Mock(pid=401, returncode=0)
        with patch.object(R.signal, 'SIGKILL', 9, create=True), patch.object(R.os, 'killpg', create=True, side_effect=[None, ProcessLookupError(), ProcessLookupError()]):
            self.assertTrue(R.stop_owned(proc))
        with patch.object(R.signal, 'SIGKILL', 9, create=True), patch.object(R.os, 'killpg', create=True, return_value=None):
            self.assertFalse(R.stop_owned(proc))

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
                child.communicate.assert_called_once()
            child.communicate.side_effect = subprocess.TimeoutExpired('test', 1)
            with patch.object(R.subprocess, 'Popen', return_value=child), patch.object(R, 'stop_owned') as stop:
                with self.assertRaises(subprocess.TimeoutExpired):
                    runner.call(None, ['test'])
                stop.assert_called_once_with(child)


if __name__ == '__main__':
    unittest.main()
