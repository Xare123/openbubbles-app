"""Credential-free source contracts, not a native NAC runtime claim."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
NAC = ROOT / 'tooling/ios/native-validation-relay/nac'


class NativeNACContractTests(unittest.TestCase):
    def test_only_the_three_known_ipc_operations_and_finite_wait_are_declared(self):
        value = (NAC / 'OBAbsintheIPC.defs').read_text(encoding='utf-8')
        self.assertIn('subsystem OBAbsintheIPC 1200;', value)
        self.assertIn('waittime 5000;', value)
        self.assertIn('ConsumeOnSendError Timeout;', value)
        self.assertEqual(re.findall(r'\broutine\s+(\w+)\(', value),
                         ['BeginSession', 'EstablishSession', 'SignBytes'])
        self.assertEqual(value.count('MACH_MSG_TYPE_INTEGER_64'), 1)
        self.assertIn('^array[] of MACH_MSG_TYPE_BYTE', value)

    def test_device_pipeline_does_not_substitute_account_signing_or_arbitrary_payload(self):
        value = (NAC / 'OBNativeNACValidator.m').read_text(encoding='utf-8')
        self.assertIn('0x50936603', value)
        self.assertIn('"com.apple.absd"', value)
        self.assertRegex(value, r'OBAbsintheSignBytes\(service, OBNACProtocolWord, handle, 0, 0,')
        self.assertNotIn('NSClassFromString', value)
        self.assertNotIn('signatureForData:', value)
        for phase in ['certificate-shape', 'native-init', 'session-shape',
                      'native-key-establishment', 'native-sign']:
            self.assertIn('@"' + phase + '"', value)

    def test_only_expected_https_urls_are_used_with_no_trust_override_or_redirect(self):
        value = (NAC / 'OBNativeNACValidator.m').read_text(encoding='utf-8')
        urls = re.findall(r'@"(https?://[^"\n]+)"', value)
        self.assertEqual(urls, [
            'https://static.ess.apple.com/identity/validation/cert-1.0.plist',
            'https://identity.ess.apple.com/WebObjects/TDIdentityService.woa/wa/initializeValidation'])
        self.assertIn('completionHandler(nil);', value)
        for forbidden in ['didReceiveChallenge', 'NSURLSessionAuthChallengeUseCredential',
                          'setAllowsAnyHTTPSCertificate', 'allowsExpiredSSLCertificates']:
            self.assertNotIn(forbidden, value)

    def test_owned_native_memory_and_service_right_are_released(self):
        value = (NAC / 'OBNativeNACValidator.m').read_text(encoding='utf-8')
        self.assertIn('vm_deallocate(mach_task_self(), pointer, count)', value)
        self.assertIn('mach_port_deallocate(mach_task_self(), service)', value)
        self.assertIn('@finally', value)
        self.assertIn('self.result = nil;', value)
        self.assertIn('invalidateAndCancel', value)
        self.assertNotIn('NACRelease', value)

    def test_ios_bootstrap_boundary_uses_fixed_verified_abi_and_owned_public_port(self):
        value = (NAC / 'OBNativeNACValidator.m').read_text(encoding='utf-8')
        self.assertNotIn('#import <servers/bootstrap.h>', value)
        self.assertIn('dlsym(RTLD_DEFAULT, "bootstrap_look_up")', value)
        self.assertIn('task_get_bootstrap_port(mach_task_self(), &bootstrap)', value)
        self.assertIn('mach_port_deallocate(mach_task_self(), bootstrap)', value)
        self.assertIn('typedef kern_return_t (*OBNACServiceLookup)(mach_port_t, const char *, mach_port_t *);', value)

    def test_no_log_account_input_or_persistent_proof_write_exists(self):
        value = (NAC / 'OBNativeNACValidator.m').read_text(encoding='utf-8')
        for forbidden in ['NSLog(', 'printf(', 'NSLogv(', 'writeToFile:', 'writeToURL:',
                          'NSUserDefaults', 'password', 'verificationCode', 'AppleAccount']:
            self.assertNotIn(forbidden, value)
        self.assertIn('dispatch_queue_create', value)
        self.assertIn('MIN(8.0, deadline - OBNACNow())', value)
        self.assertGreaterEqual(value.count('OBNACNow() >= deadline'), 5)


if __name__ == '__main__':
    unittest.main()
