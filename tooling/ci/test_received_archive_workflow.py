"""Execute isolated Android flag/guard shell without building or secrets."""
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
            'SOURCE_REF': 'a' * 40, 'RUNNER_LANE': 'primary',
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
            ['canary', 'beta', 'agent'], ['full', 'build-only'], ['true', 'false'],
            ['true', 'false'], ['agent/native-relay-client-20261020', 'other-source'],
        ):
            env = {**self.environment, 'RECEIVED_ARCHIVE': 'true',
                   'BUILD_FLAVOR': flavor, 'VALIDATION_MODE': mode,
                   'OUTBOUND_WRITER': writer, 'AUTOMATIC_UPLOADS': automatic,
                   'TRUSTED_SOURCE_BRANCH': branch}
            expected = (flavor in ('canary', 'agent') and mode == 'full' and
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

    def flag_arguments(self, enabled, flavor='canary'):
        script = step_script(self.text, 'Qualify automatic-upload Canary flags')
        script = "flutter() { printf '%s\\n' \"$@\"; };\n" + script
        result = run_shell(script, {**self.environment, 'BUILD_FLAVOR': flavor,
                                    'RECEIVED_ARCHIVE': str(enabled).lower()})
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.splitlines()

    def build_arguments(self, enabled, flavor='canary'):
        script = step_script(self.text, 'Build benchmark APK').split(
            "# Flutter's verbose path", 1)[0]
        script = "git() { printf '%s\\n' \"$SOURCE_REF\"; };\n" + script
        script += '\nprintf \'%s\\n\' "${build_args[@]}"\n'
        result = run_shell(script, {**self.environment, 'BUILD_FLAVOR': flavor,
                                    'RECEIVED_ARCHIVE': str(enabled).lower()})
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

    def test_agent_build_and_flag_qualification_bind_the_same_source(self):
        for args in [self.flag_arguments(True, 'agent'), self.build_arguments(True, 'agent')]:
            for define in ['OPENBUBBLES_BACKEND_SOURCE', 'OPENBUBBLES_BUILD_COMMIT']:
                self.assertEqual(args.count('--dart-define=' + define + '=' + 'a' * 40), 1)
            self.assertEqual(args.count('--dart-define=OPENBUBBLES_AGENT_BACKEND=true'), 1)
            for flag in FLAGS:
                self.assertEqual(args.count('--dart-define=' + flag + '=true'), 1)
        args = self.build_arguments(True, 'agent')
        self.assertEqual(args[args.index('--flavor') + 1], 'agent')
        self.assertIn('--debug', args)
        self.assertNotIn('--release', args)
        self.assertNotIn('--profile', args)
        self.assertIn('--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_ANDROID_BACKGROUND_READ=true', args)
        self.assertIn('--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_EVIDENCE=true', args)
        self.assertFalse(any('REGISTRATION_RELAY_ACCESS_TOKEN' in arg or
                             'OPENBUBBLES_CANARY_ADB_CONTROL' in arg for arg in args))

    def test_canary_and_beta_never_receive_agent_flags(self):
        for flavor in ['canary', 'beta']:
            args = self.build_arguments(False, flavor)
            self.assertFalse(any('OPENBUBBLES_AGENT_BACKEND' in arg or
                                 'OPENBUBBLES_BACKEND_SOURCE' in arg for arg in args))
        canary = self.build_arguments(False)
        self.assertIn('--dart-define=OPENBUBBLES_CANARY_ADB_CONTROL=true', canary)
        self.assertIn('--dart-define=OPENBUBBLES_REGISTRATION_RELAY_ACCESS_TOKEN=synthetic-test-only', canary)

    def test_agent_build_refuses_missing_malformed_or_mismatched_source(self):
        script = step_script(self.text, 'Build benchmark APK').split(
            "# Flutter's verbose path", 1)[0]
        for actual, expected in [('a' * 40, ''), ('a' * 40, 'main'),
                                 ('a' * 40, 'A' * 40), ('b' * 40, 'a' * 40)]:
            result = run_shell('git() { printf "%s\\n" "$STUB_HEAD"; };\n' + script,
                               {**self.environment, 'BUILD_FLAVOR': 'agent',
                                'STUB_HEAD': actual, 'SOURCE_REF': expected})
            self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_agent_admission_requires_full_primary_and_preserves_branch_pin(self):
        # Stop before the network lookup: all configuration guards run unchanged.
        script = step_script(self.text, 'Validate configuration').split('trusted_sha="$(', 1)[0]
        required = ['GCP_PROJECT_ID', 'GCP_WIF_PROVIDER', 'GCP_WIF_SERVICE_ACCOUNT',
                    'GCP_RUNNER_SERVICE_ACCOUNT', 'GCP_RUNNER_NETWORK',
                    'GCP_RUNNER_SUBNET', 'GCE_RUNNER_PAT']
        base = {**self.environment, **dict.fromkeys(required, 'synthetic-test-only'),
                'BUILD_FLAVOR': 'agent', 'PROVISIONING_MODEL': 'standard'}
        for mode, lane in product(['full', 'build-only', 'dart-only', 'bindings-only'],
                                  ['primary', 'parallel']):
            result = run_shell(script, {**base, 'VALIDATION_MODE': mode, 'RUNNER_LANE': lane})
            self.assertEqual(result.returncode == 0, mode == 'full' and lane == 'primary', result.stderr)
        self.assertIn('"$SOURCE_REF" != "$trusted_sha"', self.text)
        prior = subprocess.run(['git', 'show', 'HEAD:.github/workflows/gce-runner-pilot.yml'],
                               cwd=ROOT, capture_output=True, text=True, check=True).stdout
        branch_block = lambda text: text.split('      source_branch:\n', 1)[1].split('      flavor:\n', 1)[0]
        self.assertEqual(branch_block(self.text), branch_block(prior))

    def test_agent_producer_and_signer_reject_wrong_package_or_release(self):
        producer = step_script(self.text, 'Verify producer APK identity and native libraries')
        signer = step_script(self.text, 'Sign and verify Canary').split(
            "printf '%s' \"$CANARY_KEYSTORE_BASE64\"", 1)[0]
        stubs = '''
find() { case "$*" in *apksigner*) echo apksigner;; *) echo aapt;; esac; }
test() { return 0; }
aapt() {
  printf "package: name='%s' versionCode='1'\\n" "$STUB_PACKAGE"
  if [[ "$STUB_DEBUG" == true ]]; then echo application-debuggable; fi
}
unzip() {
  printf '%s\\n' lib/arm64-v8a/libflutter.so lib/arm64-v8a/librust_lib_bluebubbles.so \\
    lib/arm64-v8a/libirondash_engine_context_native.so lib/arm64-v8a/libsuper_native_extensions.so
}
'''
        for script in [producer, signer]:
            for package, debug in product(['com.bluebubbles.messaging.backendtest',
                                           'com.bluebubbles.messaging.cloudkitcanary',
                                           'com.bluebubbles.messaging.beta'], ['true', 'false']):
                result = run_shell(stubs + script, {**self.environment, 'BUILD_FLAVOR': 'agent',
                                   'STUB_PACKAGE': package, 'STUB_DEBUG': debug,
                                   'RUNNER_TEMP': '/synthetic-not-written', 'ANDROID_HOME': '/synthetic',
                                   **dict.fromkeys(['CANARY_KEYSTORE_BASE64', 'CANARY_KEYSTORE_PASSWORD',
                                                    'CANARY_KEY_PASSWORD', 'CANARY_KEY_ALIAS'],
                                                   'synthetic-test-only')})
                self.assertEqual(result.returncode == 0,
                                 package == 'com.bluebubbles.messaging.backendtest' and debug == 'true',
                                 result.stderr)

    def test_agent_jvm_and_signed_artifact_paths_are_distinct(self):
        jvm = step_script(self.text, 'Run Android JVM unit tests')
        selector = re.search(r'case "\$BUILD_FLAVOR" in\n.*?\n\s*esac', jvm, re.S)
        self.assertIsNotNone(selector)
        for flavor, task in [('beta', 'Beta'), ('canary', 'Canary'), ('agent', 'Agent')]:
            result = run_shell(selector.group(0) + '\nprintf "%s" "$flavor"',
                               {**self.environment, 'BUILD_FLAVOR': flavor})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, task)
        self.assertIn('(inputs.flavor == \'canary\' || inputs.flavor == \'agent\')', self.text)
        self.assertIn('name: GCE producer ${{ inputs.flavor || \'beta\' }} APK', self.text)
        self.assertIn("${{ inputs.flavor == 'agent' && 'Backend Agent' || 'Canary' }} APK", self.text)
        signer = step_script(self.text, 'Sign and verify Canary')
        self.assertIn('apk="producer/app-${BUILD_FLAVOR}-debug.apk"', signer)
        self.assertIn("path: producer/app-${{ inputs.flavor || 'beta' }}-debug.apk", self.text)

    def test_actual_dart_suite_runs_agent_gate_with_matching_defines(self):
        text = (ROOT / 'tooling/ci/run_gce_validation_suites.sh').read_text()
        function = re.search(r'^run_dart_suite\(\) \{\n.*?^}', text, re.S | re.M)
        self.assertIsNotNone(function)
        stubs = 'flutter() { printf "FLUTTER:%s\\n" "$*"; }; pwsh() { echo PWSH; };\n'
        for flavor in ['beta', 'canary', 'agent']:
            result = run_shell(stubs + function.group(0) + '\nrun_dart_suite',
                               {**self.environment, 'BUILD_FLAVOR': flavor})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.count('FLUTTER:'), 2 if flavor == 'agent' else 1)
            self.assertIn('PWSH', result.stdout)
            if flavor == 'agent':
                for value in ['OPENBUBBLES_AGENT_BACKEND=true',
                              'OPENBUBBLES_BACKEND_SOURCE=' + 'a' * 40,
                              'OPENBUBBLES_BUILD_COMMIT=' + 'a' * 40,
                              'test/backend_harness/backend_harness_agent_gate_test.dart']:
                    self.assertIn(value, result.stdout)
        invalid = run_shell(stubs + function.group(0) + '\nrun_dart_suite',
                            {**self.environment, 'BUILD_FLAVOR': 'agent', 'SOURCE_REF': 'main'})
        self.assertNotEqual(invalid.returncode, 0)
        self.assertNotIn('FLUTTER:', invalid.stdout)
        failed = run_shell('flutter() { return 9; }; pwsh() { echo PWSH; };\n' +
                           function.group(0) + '\nrun_dart_suite',
                           {**self.environment, 'BUILD_FLAVOR': 'agent'})
        self.assertEqual(failed.returncode, 9)
        self.assertNotIn('PWSH', failed.stdout)

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
