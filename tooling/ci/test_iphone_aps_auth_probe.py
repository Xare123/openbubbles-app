"""Bounded source/package and real-C nonce checks, not native signing proof."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "tooling/ios/aps-auth-check"


class APSAuthProbeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (APP / "main.m").read_text(encoding="utf-8")
        cls.build = (APP / "build.sh").read_text(encoding="utf-8")
        cls.workflow = (ROOT / ".github/workflows/gce-runner-pilot.yml").read_text(encoding="utf-8")

    def test_exact_diagnostic_and_keychain_groups_only(self):
        info = plistlib.loads((APP / "Info.plist").read_bytes())
        entitlements = plistlib.loads((APP / "entitlements.plist").read_bytes())
        bundle = "dev.openbubbles.diagnostics.apsauth"
        self.assertEqual(info["CFBundleIdentifier"], bundle)
        self.assertEqual(info["CFBundleExecutable"], "OBAPSAuthCheck")
        self.assertEqual(info["CFBundleVersion"], "1")
        self.assertNotIn("UIBackgroundModes", info)
        self.assertEqual(entitlements, {"application-identifier": bundle,
            "keychain-access-groups": [bundle, "com.apple.apsd"]})

    def test_runtime_abi_and_matching_public_keys_precede_export(self):
        for text in ('strcmp(result, "^{__SecIdentity=}") == 0',
                     "method_getNumberOfArguments(method) != 2",
                     "CFGetTypeID(keys->identity) != SecIdentityGetTypeID()",
                     "CFEqual(keys->certificatePublicBytes, keys->derivedPublicBytes)"):
            self.assertIn(text, self.source)
        self.assertLess(self.source.index("if (!OBIdentityABI(cls, selector))"),
                        self.source.index("keys->identity = ((SecIdentityRef"))
        self.assertLess(self.source.index("CFEqual(keys->certificatePublicBytes"),
                        self.source.index("SecCertificateCopyData(keys->certificate)"))

    def test_one_native_signature_and_own_certificate_verification(self):
        self.assertEqual(self.source.count("SecKeyCreateSignature("), 1)
        self.assertEqual(self.source.count("SecKeyVerifySignature("), 1)
        self.assertLess(self.source.index("ob_apns_nonce_valid(apnsNonce"),
                        self.source.index("signature = SecKeyCreateSignature("))
        self.assertIn("CFDataGetLength(signature) == keys.keyBits / 8", self.source)
        self.assertIn("kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1", self.source)
        self.assertNotIn("while (", self.source.split("uint8_t apnsNonce[17]", 1)[1])

    def test_no_private_key_export_generic_api_network_or_persistence(self):
        import re
        exports = re.findall(r"SecKeyCopyExternalRepresentation\(([^,]+),", self.source)
        self.assertEqual(exports, ["keys->certificatePublicKey", "keys->derivedPublicKey"])
        for forbidden in ("SecItemCopyMatching(", "SecItemAdd(", "SecItemUpdate(",
                          "SecItemDelete(", "invalidateDeviceIdentity", "_flushIdentityCache",
                          "NSURLSession", "NSLog(", "writeToFile:", "NSUserDefaults",
                          "posix_spawn", "registerForRemoteNotifications", "exception.description"):
            self.assertNotIn(forbidden, self.source)
        self.assertIn('@"private_key_exported": @NO', self.source)
        self.assertNotIn("dataWithJSONObject:attributes", self.source)

    def test_fixed_two_phase_protocol_and_no_default_start(self):
        for text in ("OBPort = 49177", "htonl(INADDR_LOOPBACK)", "char request[42]",
                     'memcmp(request, "OBAPSAU1:", 9)', "request[41] != '\\n'",
                     "uint8_t apnsNonce[17]", "data.length > 16384", "45 * NSEC_PER_SEC",
                     ".tv_sec = 15", 'argc == 2 && strcmp(argv[1], "--ob-aps-auth-once-v1") == 0'):
            self.assertIn(text, self.source)
        self.assertEqual(self.source.count("accept(listener, NULL, NULL)"), 1)
        self.assertNotIn("SO_REUSEPORT", self.source)
        self.assertIn("if (OBUSBMode && !self.started) [self start]", self.source)

    def test_cancellation_and_cf_cleanup(self):
        cancel = self.source.split("- (void)cancelSession {", 1)[1].split("- (void)applicationWillResignActive", 1)[0]
        self.assertIn("shutdown(self.peer, SHUT_RDWR)", cancel)
        self.assertNotIn("close(", cancel)
        self.assertIn("@finally { if (signature) CFRelease(signature); }", self.source)
        self.assertIn("OBReleaseKeys(&keys);", self.source)
        self.assertIn("self.peer = self.listener = -1;", self.source)
        self.assertIn("if (self.cancelled) { [self.fdLock unlock]; return; }", self.source)

    def test_build_is_source_bound_arm64_create_new(self):
        for text in ("^[0-9a-f]{40}$", '! -e "$output"', "arm64-apple-ios14.0",
                     "codesign --verify --deep --strict", "'arm64'", "OBAPSAuthCheck.tipa", "SOURCE_SHA"):
            self.assertIn(text, self.build)
        self.assertNotIn("curl", self.build)
        self.assertNotIn("sudo", self.build)

    def test_one_mac_job_no_vm_secrets_or_account(self):
        mode = "iphone-aps-auth-only"
        self.assertIn("          - " + mode, self.workflow)
        creator = self.workflow.split("  create-runner:", 1)[1].split("    runs-on:", 1)[0]
        self.assertIn("inputs.validation_mode != '" + mode + "'", creator)
        block = self.workflow.split("  iphone-aps-auth:\n", 1)[1].split("\n  iphone-", 1)[0]
        for text in ("inputs.validation_mode == '" + mode + "'", "runs-on: macos-15",
                     "timeout-minutes: 8", "persist-credentials: false", "submodules: false",
                     "ref: ${{ github.sha }}", "tooling/ios/aps-auth-check/build.sh"):
            self.assertIn(text, block)
        self.assertNotIn("secrets.", block)
        self.assertNotIn("id-token:", block)

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "real C nonce check runs on Mac builder")
    def test_real_c_nonce_boundaries_and_unsigned_overflow(self):
        source = r'''
#include "nonce.h"
#include <assert.h>
#include <string.h>
static void set_stamp(uint8_t *bytes, uint64_t stamp) {
  for (int i=8; i>=1; --i) { bytes[i]=(uint8_t)stamp; stamp >>= 8; }
}
int main(void) {
  uint8_t bytes[17]={0};
  assert(!ob_apns_nonce_valid(NULL,17,40000));
  assert(!ob_apns_nonce_valid(bytes,16,40000));
  assert(!ob_apns_nonce_valid(bytes,17,0));
  set_stamp(bytes,40000);
  assert(ob_apns_nonce_valid(bytes,17,40000));
  assert(ob_apns_nonce_valid(bytes,17,10000));
  assert(ob_apns_nonce_valid(bytes,17,70000));
  assert(!ob_apns_nonce_valid(bytes,17,9999));
  assert(!ob_apns_nonce_valid(bytes,17,70001));
  bytes[0]=1; assert(!ob_apns_nonce_valid(bytes,17,40000)); bytes[0]=0;
  set_stamp(bytes,UINT64_MAX);
  assert(!ob_apns_nonce_valid(bytes,17,0));
  assert(ob_apns_nonce_valid(bytes,17,UINT64_MAX-30000));
  assert(!ob_apns_nonce_valid(bytes,17,UINT64_MAX-30001));
  memset(bytes+9,0xff,8); assert(ob_apns_nonce_valid(bytes,17,UINT64_MAX));
  return 0;
}'''
        with tempfile.TemporaryDirectory(prefix="ob-aps-nonce-") as directory:
            path = Path(directory)
            (path / "test.c").write_text(source, encoding="utf-8")
            subprocess.run(["clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", str(APP),
                            str(path / "test.c"), "-o", str(path / "test")], check=True, timeout=20)
            subprocess.run([str(path / "test")], check=True, timeout=5)


if __name__ == "__main__":
    unittest.main()
