"""Source safety checks only. Foundation execution and iOS acceptance are separate."""
from pathlib import Path
import plistlib
import unittest

ROOT=Path(__file__).resolve().parents[2]
SOURCE=ROOT/'tooling/ios/native-validation-relay/src'

class NativePushContract(unittest.TestCase):
    def test_native_key_is_referenced_not_exported_and_each_signature_is_verified(self):
        value=(SOURCE/'OBRelayNativePush.m').read_text(encoding='utf-8')
        for exact in ['"APSConnection"','"copyIdentity"','"^{__SecIdentity=}"',
                      'SecIdentityCopyPrivateKey(identity,&privateKey)',
                      'SecKeyCopyExternalRepresentation(certificateKey,NULL)',
                      'SecKeyCopyExternalRepresentation(publicKey,NULL)',
                      'SecKeyVerifySignature(certificateKey,algorithm',
                      'kSecKeyAlgorithmRSASignatureDigestPKCS1v15SHA1']:
            self.assertIn(exact,value)
        self.assertEqual(value.count('SecKeyCopyExternalRepresentation('),2)
        for forbidden in ['SecKeyCopyExternalRepresentation(privateKey','SecItemDelete(',
                          'NSLog(', 'printf(', 'writeToFile:', 'writeToURL:']:
            self.assertNotIn(forbidden,value)

    def test_persistent_replays_and_one_owned_native_operation_are_bounded(self):
        value=(SOURCE/'OBRelayPushService.m').read_text(encoding='utf-8')
        for exact in ['next.count>=512','[self.defaults synchronize]',
                      'self.current || self.quarantined','context.cancelled=YES',
                      'self.current!=context','self.operation(request)',
                      'OBRelayPushParseCommand(command,code,now)',
                      'OBRelayPushResponseMAC(requestHash,cert,sig,code)']:
            self.assertIn(exact,value)
        self.assertLess(value.index('![self admitReplay:request'),value.index('self.operation(request)'))
        self.assertEqual(value.count('setObject:'),1)
        self.assertNotIn('NSLog(',value)
        connection=(SOURCE/'OBRelayConnection.m').read_text(encoding='utf-8')
        self.assertIn('owner.epoch == epoch && owner.task == boundTask',connection)
        self.assertIn('[self.pushService invalidatePendingRequest]',connection)

    def test_version_and_entitlements_are_exact_and_old_nac_remains_separate(self):
        info=plistlib.loads((SOURCE/'Info.plist').read_bytes())
        self.assertEqual(info['CFBundleVersion'],'2')
        rights=plistlib.loads((SOURCE.parent/'entitlements.plist').read_bytes())
        self.assertEqual(rights['keychain-access-groups'],['dev.openbubbles.relay.native','com.apple.apsd'])
        build=(SOURCE.parent/'tests/run-foundation-tests.sh').read_text(encoding='utf-8')
        for fixture in ['push-protocol-tests.m','push-service-tests.m','OBRelayNativePush.m']:
            self.assertIn(fixture,build)

if __name__=='__main__':
    unittest.main()
