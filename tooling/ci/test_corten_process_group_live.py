"""Real Linux cleanup checks. No emulator, application, network or credentials.

Load the exact production cleanup function's AST, not its APK-build imports.
This deliberately tests only the stdlib process-group boundary.
"""
import ast
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
import unittest


def production_cleanup():
    source = Path(__file__).with_name('run_corten_android_login_runtime.py')
    raw = source.read_bytes()
    tree = ast.parse(raw, filename=str(source))
    functions = [node for node in tree.body
                 if isinstance(node, ast.FunctionDef) and node.name == 'stop_owned']
    if len(functions) != 1:
        raise RuntimeError('exact production cleanup function missing')
    constants = {}
    required = {'TERM_GRACE_SECONDS', 'KILL_GRACE_SECONDS', 'GROUP_POLL_SECONDS'}
    for node in tree.body:
        if not isinstance(node, ast.Assign) or len(node.targets) != 1:
            continue
        target = node.targets[0]
        names = [target.id] if isinstance(target, ast.Name) else (
            [item.id for item in target.elts] if isinstance(target, ast.Tuple) else [])
        if not required.intersection(names):
            continue
        value = ast.literal_eval(node.value)
        constants.update(zip(names, [value] if len(names) == 1 else value))
    if constants.keys() != required:
        raise RuntimeError('production cleanup bounds missing or changed shape')
    namespace = {'os': os, 'signal': signal, 'time': time, **constants}
    exec(compile(ast.Module(body=functions, type_ignores=[]), str(source), 'exec'), namespace)
    return namespace['stop_owned'], hashlib.sha256(raw).hexdigest()


@unittest.skipUnless(sys.platform == 'linux', 'requires actual Linux process groups')
class LiveProcessGroups(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cleanup, digest = production_cleanup()
        cls.cleanup = staticmethod(cls.cleanup)
        print(json.dumps({'runtime_sha256': digest, 'account_access': False,
                          'emulator_started': False}), flush=True)

    def spawn_owned(self, handler, marked=True):
        script = ('import os, signal, sys, time\n' + handler +
                  '\nprint("READY", flush=True)\ntime.sleep(120)\n')
        child = subprocess.Popen([sys.executable, '-u', '-c', script],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
        self.addCleanup(self.reap_fixture, child)
        if marked:
            child._ob_owned_pgid = child.pid
        ready, _, _ = select.select([child.stdout], [], [], 5)
        self.assertTrue(ready, 'fixture readiness timeout')
        self.assertEqual(child.stdout.readline(), b'READY\n')
        self.assertEqual(os.getpgid(child.pid), child.pid)
        return child

    def reap_fixture(self, child):
        # Emergency cleanup uses only this test's start_new_session child.
        # It is independent of the function under test, and never scans PIDs.
        if getattr(child, '_ob_group_reaped', False) is not True:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        child.wait(timeout=5)
        for stream in (child.stdout, child.stderr):
            stream.close()
        self.assert_group_absent(child)

    def assert_group_absent(self, child):
        self.assertIsNotNone(child.poll())
        with self.assertRaises(ProcessLookupError):
            os.killpg(child.pid, 0)

    def test_normal_term_and_idempotence(self):
        child = self.spawn_owned('')
        self.assertTrue(self.cleanup(child))
        self.assert_group_absent(child)
        self.assertTrue(self.cleanup(child))

    def test_allows_real_twenty_second_grace(self):
        child = self.spawn_owned('def delayed(*_):\n    time.sleep(20)\n    sys.exit(0)\n'
                                 'signal.signal(signal.SIGTERM, delayed)')
        start = time.monotonic()
        self.assertTrue(self.cleanup(child))
        elapsed = time.monotonic() - start
        self.assertGreaterEqual(elapsed, 20)
        self.assertLess(elapsed, 25)
        self.assertEqual(child.returncode, 0, 'must finish gracefully, not through SIGKILL')
        self.assert_group_absent(child)
        print(json.dumps({'case': 'term-grace', 'seconds': round(elapsed, 3)}), flush=True)

    def test_real_kill_escalation_after_grace(self):
        child = self.spawn_owned('signal.signal(signal.SIGTERM, signal.SIG_IGN)')
        start = time.monotonic()
        self.assertTrue(self.cleanup(child))
        elapsed = time.monotonic() - start
        self.assertGreaterEqual(elapsed, 25)
        self.assertLess(elapsed, 30)
        self.assertEqual(child.returncode, -signal.SIGKILL)
        self.assert_group_absent(child)
        print(json.dumps({'case': 'kill-escalation', 'seconds': round(elapsed, 3)}), flush=True)

    def test_unmarked_child_is_not_signalled(self):
        child = self.spawn_owned('', marked=False)
        self.assertFalse(self.cleanup(child))
        self.assertIsNone(child.poll())
        child._ob_owned_pgid = child.pid
        self.assertTrue(self.cleanup(child))
        self.assert_group_absent(child)


if __name__ == '__main__':
    unittest.main(verbosity=2)
