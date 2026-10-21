"""Source/package guards, not iPhone runtime, key export or login evidence."""
from pathlib import Path
import plistlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "tooling/ios/aps-identity-check"


class APSIdentityProbeGuards(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (APP / "main.m").read_text(encoding="utf-8")
        cls.build = (APP / "build.sh").read_text(encoding="utf-8")
        cls.workflow = (ROOT / ".github/workflows/gce-runner-pilot.yml").read_text(encoding="utf-8")

    def test_separate_bundle_and_minimal_entitlements(self):
        info = plistlib.loads((APP / "Info.plist").read_bytes())
        entitlements = plistlib.loads((APP / "entitlements.plist").read_bytes())
        bundle = "dev.openbubbles.diagnostics.apsidentity"
        self.assertEqual(info["CFBundleIdentifier"], bundle)
        self.assertEqual(info["CFBundleVersion"], "1")
        self.assertEqual(entitlements, {"application-identifier": bundle, "keychain-access-groups": [bundle]})
        self.assertNotIn("UIBackgroundModes", info)

    def test_only_declared_identity_factory_after_exact_runtime_abi_check(self):
        self.assertIn('NSClassFromString(@"APSConnection")', self.source)
        self.assertIn('NSSelectorFromString(@"copyIdentity")', self.source)
        self.assertIn('strcmp(result, "^{__SecIdentity=}") == 0', self.source)
        self.assertIn("method_getNumberOfArguments(method) != 2", self.source)
        self.assertLess(self.source.index("if (!OBIdentityABI(cls, selector))"),
                        self.source.index("identity = ((SecIdentityRef (*)(id, SEL))objc_msgSend)"))
        self.assertIn("CFGetTypeID(identity) != SecIdentityGetTypeID()", self.source)

    def test_private_key_reference_is_never_exported_or_used_to_sign(self):
        exports = re.findall(r"SecKeyCopyExternalRepresentation\((\w+),", self.source)
        self.assertEqual(exports, ["certificatePublicKey", "derivedPublicKey"])
        for forbidden in ("SecKeyCreateSignature(", "SecItemCopyMatching(", "invalidateDeviceIdentity",
                          "_flushIdentityCache", "registerForRemoteNotifications", "NSURLSession",
                          "NSTask", "posix_spawn", "system("):
            self.assertNotIn(forbidden, self.source)
        self.assertIn("SecKeyIsAlgorithmSupported(", self.source)

    def test_only_fixed_metadata_is_serialized_and_no_native_error_description(self):
        self.assertIn("dataWithJSONObject:metadata", self.source)
        self.assertNotIn("dataWithJSONObject:attributes", self.source)
        self.assertNotIn("NSLog(", self.source)
        self.assertNotIn("exception.description", self.source)
        self.assertIn('@"private_key_exported": @NO', self.source)
        self.assertIn('@"explicit_network_requests": @0', self.source)
        self.assertIn('@"native_backend_side_effects_unqualified": @YES', self.source)

    def test_one_fixed_loopback_request_and_bounded_response(self):
        for text in ("OBPort = 49176", "htonl(INADDR_LOOPBACK)", "char request[42]",
                     'memcmp(request, "OBAPSID1:", 9)', "request[41] != '\\n'",
                     "data.length > 8192", "45 * NSEC_PER_SEC", ".tv_sec = 5"):
            self.assertIn(text, self.source)
        self.assertEqual(self.source.count("accept(listener, NULL, NULL)"), 1)
        self.assertNotIn("SO_REUSEPORT", self.source)

    def test_lifetime_does_not_close_descriptors_during_framework_operation(self):
        cancel = self.source.split("- (void)cancelSession {", 1)[1].split("- (void)applicationWillResignActive", 1)[0]
        self.assertIn("shutdown(self.peer, SHUT_RDWR)", cancel)
        self.assertNotIn("close(", cancel)
        self.assertIn("self.started && !self.finished && !self.cancelled", self.source)
        self.assertIn("if (self.cancelled) { [self.fdLock unlock]; return; }", self.source)
        self.assertIn("self.peer = self.listener = -1;", self.source)

    def test_build_is_source_bound_arm64_and_create_new(self):
        for text in ("^[0-9a-f]{40}$", '! -e "$output"', "arm64-apple-ios14.0", "codesign --verify --deep --strict",
                     "'arm64'", "OBAPSIdentityCheck.tipa", "SOURCE_SHA"):
            self.assertIn(text, self.build)
        for forbidden in ("sudo", "curl", "security import", "keychain-access-groups.*"):
            self.assertNotIn(forbidden, self.build)

    def test_new_mode_excludes_vm_and_has_one_secret_free_mac_job(self):
        mode = "iphone-aps-identity-only"
        self.assertTrue("          - " + mode in self.workflow, "metadata mode missing")
        creator = self.workflow.split("  create-runner:", 1)[1].split("    runs-on:", 1)[0]
        self.assertTrue("inputs.validation_mode != '" + mode + "'" in creator, "VM exclusion missing")
        block = self.workflow.split("  iphone-aps-identity:\n", 1)[1].split("\n  iphone-", 1)[0]
        for text in ("inputs.validation_mode == '" + mode + "'", "runs-on: macos-15",
                     "timeout-minutes: 8", "persist-credentials: false", "submodules: false",
                     "ref: ${{ github.sha }}", "tooling/ios/aps-identity-check/build.sh"):
            self.assertTrue(text in block, "missing job guard: " + text)
        self.assertNotIn("secrets.", block)
        self.assertNotIn("id-token:", block)
        self.assertEqual(self.workflow.count("inputs.validation_mode == '" + mode + "'"), 1)


if __name__ == "__main__":
    unittest.main()
