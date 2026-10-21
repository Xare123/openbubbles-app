"""Execute the real bounded Canary flag/guard shell without building or secrets."""
from itertools import product
import os
from pathlib import Path
import re
import shutil
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/gce-runner-pilot.yml'
FLAGS = [
    'OPENBUBBLES_CLOUD_SYNC_V2_RECEIVED_' + suffix
    for suffix in ['CAPTURE', 'INSPECTION', 'UPLOADS', 'DISCOVERY', 'PROFILE']
]


def bash():
    if os.name == 'nt':
        candidate = Path('C:/Program Files/Git/bin/bash.exe')
        if candidate.is_file():
            return str(candidate)
    executable = shutil.which('bash')
    if executable is None:
        raise RuntimeError('Bash is required; do not silently skip guard checks')
    return executable


def run_shell(script, env):
    return subprocess.run(
        [bash(), '-c', script], env={**os.environ, **env},
        capture_output=True, text=True, timeout=10,
    )


def step_script(text, name):
    step = text.split('      - name: ' + name + '\n', 1)[1]
    block = step.split('        run: |\n', 1)[1]
    lines = []
    for line in block.splitlines():
        if line and not line.startswith('          '):
            break
        lines.append(line[10:])
    return '\n'.join(lines)


class ReceivedArchiveWorkflow(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.text = WORKFLOW.read_text(encoding='utf-8')
        cls.environment = {
            'RECEIVED_ARCHIVE': 'false', 'BUILD_FLAVOR': 'canary',
            'VALIDATION_MODE': 'full', 'OUTBOUND_WRITER': 'true',
            'AUTOMATIC_UPLOADS': 'true',
            'TRUSTED_SOURCE_BRANCH': 'agent/native-relay-client-20261020',
            'REGISTRATION_RELAY_ACCESS_TOKEN': 'synthetic-test-only',
        }

    def test_optional_input_and_environment_default_off(self):
        input_block = self.text.split('      received_archive:\n', 1)[1].split(
            '      native_contract_analysis:', 1)[0]
        self.assertIn('required: false', input_block)
        self.assertIn('default: false', input_block)
        self.assertIn('type: boolean', input_block)
        self.assertIn("RECEIVED_ARCHIVE: ${{ inputs.received_archive || false }}", self.text)

    def test_actual_shell_guard_rejects_every_incompatible_mode(self):
        guard = re.search(
            r'          if \[\[ "\$RECEIVED_ARCHIVE" == \'true\' &&\n.*?\n          fi',
            self.text, re.S,
        )
        self.assertIsNotNone(guard)
        for flavor, mode, writer, automatic, branch in product(
            ['canary', 'beta'], ['full', 'build-only'], ['true', 'false'],
            ['true', 'false'], ['agent/native-relay-client-20261020', 'other-source'],
        ):
            env = {**self.environment, 'RECEIVED_ARCHIVE': 'true',
                   'BUILD_FLAVOR': flavor, 'VALIDATION_MODE': mode,
                   'OUTBOUND_WRITER': writer, 'AUTOMATIC_UPLOADS': automatic,
                   'TRUSTED_SOURCE_BRANCH': branch}
            expected = (flavor == 'canary' and mode == 'full' and
                        writer == automatic == 'true' and
                        branch == 'agent/native-relay-client-20261020')
            with self.subTest(env={k: v for k, v in env.items() if k != 'REGISTRATION_RELAY_ACCESS_TOKEN'}):
                result = run_shell(guard.group(0), env)
                self.assertEqual(result.returncode == 0, expected, result.stderr)
        disabled = run_shell(guard.group(0), {
            **self.environment, 'BUILD_FLAVOR': 'beta', 'VALIDATION_MODE': 'build-only',
            'OUTBOUND_WRITER': 'false', 'AUTOMATIC_UPLOADS': 'false',
        })
        self.assertEqual(disabled.returncode, 0, disabled.stderr)

    def flag_arguments(self, enabled):
        script = step_script(self.text, 'Qualify automatic-upload Canary flags')
        script = "flutter() { printf '%s\\n' \"$@\"; };\n" + script
        result = run_shell(script, {**self.environment, 'RECEIVED_ARCHIVE': str(enabled).lower()})
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def build_arguments(self, enabled):
        script = step_script(self.text, 'Build benchmark APK').split(
            "# Flutter's verbose path", 1)[0]
        script = "git() { printf '%s\\n' synthetic-source; };\n" + script
        script += '\nprintf \'%s\\n\' "${build_args[@]}"\n'
        result = run_shell(script, {**self.environment, 'RECEIVED_ARCHIVE': str(enabled).lower()})
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def test_actual_flag_and_build_arguments_match_enabled_bundle(self):
        qualified = self.flag_arguments(True)
        built = self.build_arguments(True)
        for flag in FLAGS:
            self.assertEqual(qualified.count('--dart-define=' + flag + '=true'), 1)
            self.assertEqual(built.count('--dart-define=' + flag + '=true'), 1)
        for expected in ['TEST_EXPECT_RECEIVED_PROFILE', 'TEST_EXPECT_RECEIVED_ARCHIVE']:
            self.assertIn('--dart-define=' + expected + '=true', qualified)
            self.assertFalse(any(expected in arg for arg in built))
        self.assertIn('--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true', qualified)
        self.assertIn('--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true', built)

    def test_existing_disabled_build_does_not_inherit_received_flags(self):
        for args in [self.flag_arguments(False), self.build_arguments(False)]:
            for flag in FLAGS:
                self.assertFalse(any(flag in arg for arg in args))

    def test_producer_signer_and_signed_artifacts_share_exact_discriminator(self):
        suffix = "${{ inputs.received_archive && ' received-true' || '' }}"
        self.assertEqual(self.text.count(suffix), 3)
        names = re.findall(r'          name: (GCE (?:producer|CloudKit).*APK.*)', self.text)
        self.assertEqual(len(names), 3)
        self.assertTrue(all(line.endswith(suffix) for line in names))
        self.assertEqual(names[0].split(' APK ', 1)[1], names[1].split(' APK ', 1)[1])
        self.assertEqual(names[1].split(' APK ', 1)[1], names[2].split(' APK ', 1)[1])

    def test_vm_cleanup_lifetime_and_signing_controls_are_unchanged(self):
        prior = subprocess.run(
            ['git', 'show', '161f35952c22cb59b8cb3a034e176097f2df8b60:.github/workflows/gce-runner-pilot.yml'],
            cwd=ROOT, capture_output=True, text=True, check=True, timeout=10,
        ).stdout
        for marker in ['  delete-runner:\n']:
            self.assertEqual(self.text.split(marker, 1)[1], prior.split(marker, 1)[1])
        for control in ['--max-run-duration 75m', '--boot-disk-size 100GB',
                        'cancel-in-progress: false',
                        "expected_fingerprint='0ea17c1b67581ca79660d33db45af0a36b71ea36a4cbafec5293d3ae80570d79'"]:
            self.assertIn(control, self.text)
            self.assertIn(control, prior)


if __name__ == '__main__':
    unittest.main()
