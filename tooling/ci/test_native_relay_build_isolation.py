"""One secret-free Mac-only helper lane; no GCE/Android/account execution."""
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'tooling/ios/native-validation-relay'


class NativeRelayBuildIsolation(unittest.TestCase):
    def test_mode_cannot_create_a_cloud_vm_and_uses_only_the_exact_hosted_job(self):
        text = (ROOT / '.github/workflows/gce-runner-pilot.yml').read_text(encoding='utf-8')
        mode = 'iphone-native-relay-only'
        self.assertIn('- ' + mode, text)
        creator = text.split('  create-runner:\n', 1)[1].split('    runs-on:', 1)[0]
        self.assertIn("inputs.validation_mode != '" + mode + "'", creator)
        job = re.split(r'\n  [a-z][a-z0-9-]+:\n', text.split('  iphone-native-relay:\n', 1)[1], maxsplit=1)[0]
        for value in ["inputs.validation_mode == '" + mode + "'", 'runs-on: macos-15',
                      'submodules: false', 'persist-credentials: false', 'ref: ${{ github.sha }}']:
            self.assertIn(value, job)
        for forbidden in ['secrets.', 'id-token:', 'gcloud ', 'flutter ', 'sudo ', 'source_ref']:
            self.assertNotIn(forbidden, job)
        self.assertEqual(job.count('uses: actions/checkout@'), 1)

    def test_narrow_entitlements_and_separate_bundle(self):
        info = plistlib.loads((HELPER / 'src/Info.plist').read_bytes())
        entitlements = plistlib.loads((HELPER / 'entitlements.plist').read_bytes())
        self.assertEqual(info['CFBundleIdentifier'], 'dev.openbubbles.relay.native')
        self.assertEqual(info['MinimumOSVersion'], '15.0')
        self.assertNotIn('NSAppTransportSecurity', info)
        self.assertEqual(set(entitlements), {'application-identifier', 'keychain-access-groups',
            'com.apple.private.MobileGestalt.AllowedProtectedKeys', 'abs-client', 'com.apple.authkit.client.private'})
        self.assertEqual(entitlements['application-identifier'], info['CFBundleIdentifier'])
        self.assertEqual(entitlements['abs-client'], 772496756)

    def test_build_requires_real_foundation_tests_and_generated_finite_mig(self):
        source = (HELPER / 'build.sh').read_text(encoding='utf-8')
        for required in ['tests/run-foundation-tests.sh', 'MACH_SEND_TIMEOUT', 'MACH_RCV_TIMEOUT',
                         '5000', '1200 1201 1202', 'nac/OBNativeNACValidator.m',
                         '-target arm64-apple-ios15.0', 'codesign --verify --deep --strict']:
            self.assertIn(required, source)
        for forbidden in ['curl ', 'gcloud ', 'rm -rf', 'get-validation-data', 'AppleAccountPassword']:
            self.assertNotIn(forbidden, source)
        self.assertIn('OBNACValidatorUnavailable.m', source)
        self.assertIn('continue', source)


if __name__ == '__main__':
    unittest.main()
