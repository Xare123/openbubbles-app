"""Narrow packaging/privacy guards only. Not iOS runtime or login evidence."""
import pathlib
import plistlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
DIRECTORY = ROOT / "tooling/ios/account-signing-preflight"


class AccountSigningPreflightGuards(unittest.TestCase):
    def test_distinct_bundle_and_no_transport_security_exceptions(self):
        info = plistlib.loads((DIRECTORY / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "dev.openbubbles.diagnostics.accountsigning")
        self.assertEqual(info["CFBundleExecutable"], "OBAccountSigningProbe")
        self.assertNotIn("NSAppTransportSecurity", info)
        self.assertNotIn("CFBundleURLTypes", info)

    def test_only_narrow_existing_native_client_entitlements(self):
        entitlements = plistlib.loads((DIRECTORY / "entitlements.plist").read_bytes())
        self.assertEqual(set(entitlements), {"application-identifier", "keychain-access-groups",
            "com.apple.private.MobileGestalt.AllowedProtectedKeys", "abs-client"})
        self.assertEqual(entitlements["application-identifier"], "dev.openbubbles.diagnostics.accountsigning")
        self.assertEqual(entitlements["keychain-access-groups"], [entitlements["application-identifier"]])
        self.assertEqual(entitlements["abs-client"], 772496756)
        self.assertEqual(entitlements["com.apple.private.MobileGestalt.AllowedProtectedKeys"],
            ["SerialNumber", "UniqueDeviceID"])

    def test_no_remote_inputs_account_or_signature_output(self):
        source = (DIRECTORY / "main.m").read_text()
        for forbidden in ["base64Encoded", "NSLog(", "printf(", "SecItem", "URLSession",
                          "get-validation-data", "get-version-info", "loadHTMLString",
                          "gsa.apple.com", "registration-relay", "keychainAccessGroups"]:
            self.assertNotIn(forbidden, source)
        self.assertIn("@\"signatures_retained\": @NO", source)
        self.assertIn("@\"login_qualified\": @NO", source)
        self.assertIn("NSDataWritingWithoutOverwriting", source)
        self.assertEqual(source.count("writeToURL:"), 1)

    def test_fixed_payloads_abi_checks_and_bounded_late_callback_guard(self):
        source = (DIRECTORY / "main.m").read_text()
        self.assertIn('NSSelectorFromString(@"signatureForData:completion:")', source)
        self.assertIn('OBMethodHasType(method, 4, \'v\')', source)
        self.assertIn('strcmp(completionType, "@?")', source)
        self.assertIn("45 * NSEC_PER_SEC", source)
        self.assertLess(source.index("dispatch_after("), source.index("dlopen("))
        self.assertIn("dispatch_async(self.nativeQueue", source)
        self.assertIn("deadline.timeIntervalSinceNow <= 0", source)
        self.assertIn("if (!owner || owner.finished) return", source)
        self.assertIn("if (self.started) return", source)
        self.assertIn("OpenBubbles account-signing preflight v1", source)
        self.assertIn('@"empty-payload" payload:NSData.data', source)
        self.assertIn("A timeout does NOT claim it canceled", source)

    def test_build_is_one_arch_ad_hoc_no_download_or_device_operation(self):
        source = (DIRECTORY / "build.sh").read_text()
        self.assertIn('! -e "$output" && ! -L "$output"', source)
        self.assertIn("arm64-apple-ios14.0", source)
        self.assertIn("codesign --verify --deep --strict", source)
        self.assertIn("shasum -a 256", source)
        for forbidden in ["curl ", "wget ", "sudo ", "rm ", "idevice", "pymobile", "git clone",
                          "security import", "security create", "xcodebuild", "xcrun devicectl"]:
            self.assertNotIn(forbidden, source)

    def test_workflow_isolates_hosted_diagnostic_from_gce_and_apks(self):
        text = (ROOT / ".github/workflows/gce-runner-pilot.yml").read_text()
        mode = "iphone-account-signing-preflight-only"
        create = text.split("  create-runner:\n", 1)[1]
        self.assertIn(f"inputs.validation_mode != '{mode}'", create.split("    runs-on:", 1)[0])
        job = text.split("  iphone-account-signing-preflight:\n", 1)[1].split("\n  iphone-activation-static:", 1)[0]
        self.assertIn(f"inputs.validation_mode == '{mode}'", job)
        self.assertIn("runs-on: macos-15", job)
        self.assertIn("timeout-minutes: 10", job)
        self.assertIn("submodules: false", job)
        self.assertIn("persist-credentials: false", job)
        self.assertNotIn("secrets.", job)
        self.assertNotIn("id-token:", job)
        self.assertNotIn("gcloud ", job)
        self.assertNotIn("flutter ", job)
        self.assertEqual(len(re.findall(r"uses: actions/checkout@", job)), 1)


if __name__ == "__main__":
    unittest.main()
