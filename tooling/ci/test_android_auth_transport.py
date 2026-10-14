import json
from pathlib import Path
import tempfile
import unittest

import run_android_auth_transport as transport


class TransportTests(unittest.TestCase):
    def rows(self):
        return [
            {'probe': label, 'host': host, 'strict_https': True, 'http_status': status,
             'authentication_tested': False}
            for label, host, status in [('google-control', 'www.google.com', 200),
                                        ('gsa-public', 'gsa.apple.com', 403)]
        ] + [{'provider_calls': 0, 'credentials_loaded': False,
              'authentication_tested': False, 'transport_passed': True}]

    def check_rows(self, rows, code=0):
        return transport.observations(code, ('\n'.join(map(json.dumps, rows))).encode())['passed']

    def test_unauthenticated_403_proves_transport_not_login(self):
        self.assertTrue(self.check_rows(self.rows()))
        self.assertFalse(self.check_rows(self.rows(), 1))
        self.assertFalse(self.check_rows(self.rows()[:2]))

    def test_rejects_wrong_host_failed_tls_and_untyped_status(self):
        for key, value in [('host', 'other.example'), ('strict_https', 'true'),
                           ('http_status', True), ('authentication_tested', True)]:
            rows = self.rows()
            rows[1][key] = value
            self.assertFalse(self.check_rows(rows))

    def test_rejects_provider_or_account_access(self):
        for key, value in [('provider_calls', 1), ('provider_calls', False),
                           ('credentials_loaded', True), ('transport_passed', 'true')]:
            rows = self.rows()
            rows[-1][key] = value
            self.assertFalse(self.check_rows(rows))

    def test_only_one_owned_compiler_artifact_is_selected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root/'auth-test'
            binary.touch()
            row = {'reason': 'compiler-artifact', 'target': {'name': 'icloud_auth'},
                   'profile': {'test': True}, 'executable': str(binary)}
            self.assertEqual(transport.test_executable(json.dumps(row), root), binary.resolve())
            with self.assertRaises(RuntimeError):
                transport.test_executable(json.dumps(row)+'\n'+json.dumps(row), root)
            with self.assertRaises(RuntimeError):
                transport.test_executable(json.dumps(row), root/'unrelated')

    def test_uses_real_constructor_without_authentication_or_tls_override(self):
        source = transport.TEMPLATE.read_text()
        self.assertIn('AppleAccount::new_with_anisette(', source)
        self.assertIn('account.client.get(url)', source)
        for value in ('danger_accept', '.proxy(', 'login_email_pass(', 'send_sms_2fa',
                      'send_2fa_to_devices', '.post(', '.put(', '.headers('):
            self.assertNotIn(value, source)
        self.assertEqual(source.count('https://'), 2)

    def test_lane_skips_gce_flutter_and_all_account_inputs(self):
        source = (Path(__file__).resolve().parents[2]/'.github/workflows/gce-runner-pilot.yml').read_text()
        job = source.split('  corten-android-auth-transport:', 1)[1].split('  corten-android-cleanup:', 1)[0]
        for value in ('secrets.', 'gcloud', 'flutter', 'private_auth_input', '--hold-seconds'):
            self.assertNotIn(value, job)
        self.assertIn('run_android_auth_transport.py', job)
        create = source.split('  create-runner:', 1)[1].split('    runs-on:', 1)[0]
        self.assertIn("inputs.validation_mode != 'corten-android-auth-transport-only'", create)


if __name__ == '__main__':
    unittest.main(verbosity=2)
