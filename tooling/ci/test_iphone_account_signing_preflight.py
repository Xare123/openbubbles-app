"""Narrow packaging/privacy guards only. Not iOS runtime or login evidence."""
import pathlib
import plistlib
import re
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
DIRECTORY = ROOT / "tooling/ios/account-signing-preflight"


def method_source(source, signature):
    """Scope source guards to one top-level Objective-C method, not a sibling."""
    return source.split(signature + " {", 1)[1].split("\n}\n", 1)[0]


class AccountSigningPreflightGuards(unittest.TestCase):
    def test_distinct_bundle_and_no_transport_security_exceptions(self):
        info = plistlib.loads((DIRECTORY / "Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "dev.openbubbles.diagnostics.accountsigning")
        self.assertEqual(info["CFBundleExecutable"], "OBAccountSigningProbe")
        self.assertEqual(info["CFBundleVersion"], "2")
        self.assertNotIn("NSAppTransportSecurity", info)
        self.assertNotIn("CFBundleURLTypes", info)

    def test_only_narrow_existing_native_client_entitlements(self):
        entitlements = plistlib.loads((DIRECTORY / "entitlements.plist").read_bytes())
        self.assertEqual(set(entitlements), {"application-identifier", "keychain-access-groups",
            "com.apple.private.MobileGestalt.AllowedProtectedKeys", "abs-client",
            "com.apple.authkit.client.private"})
        self.assertEqual(entitlements["application-identifier"], "dev.openbubbles.diagnostics.accountsigning")
        self.assertEqual(entitlements["keychain-access-groups"], [entitlements["application-identifier"]])
        self.assertEqual(entitlements["abs-client"], 772496756)
        self.assertIs(entitlements["com.apple.authkit.client.private"], True)
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
        manual = method_source(source, "- (void)runCheck")
        signing = method_source(source, "- (void)signStage:(NSString *)stage payload:(NSData *)payload signer:(id)signer")
        self.assertIn('NSSelectorFromString(@"signatureForData:completion:")', source)
        self.assertIn('OBMethodHasType(method, 4, \'v\')', manual)
        self.assertIn('strcmp(completionType, "@?")', manual)
        self.assertIn("45 * NSEC_PER_SEC", manual)
        self.assertLess(manual.index("dispatch_after("), manual.index("dlopen("))
        self.assertIn("dispatch_async(self.nativeQueue", manual)
        self.assertIn("dispatch_async(self.nativeQueue", signing)
        self.assertIn("deadline.timeIntervalSinceNow <= 0", signing)
        self.assertIn("if (!owner || owner.finished) return", signing)
        self.assertIn("if (self.started) return", manual)
        self.assertIn("OpenBubbles account-signing preflight v1", signing)
        self.assertIn('@"empty-payload" payload:NSData.data', manual)
        self.assertIn("A timeout does NOT claim it canceled", manual)

    def test_authkit_auto_mode_requires_exact_singleton_argument(self):
        source = (DIRECTORY / "main.m").read_text()
        entry = method_source(source, "int main(int argc, char **argv)")
        selection = entry.split("OBAuthKitRequested =", 1)[1].split(";", 1)[0]
        self.assertIn("argc == 2 && argv && argv[0] && argv[1]", selection)
        self.assertIn('strcmp(argv[1], "--ob-native-authkit-no-provision-v1") == 0', selection)
        self.assertNotIn("||", selection)
        self.assertEqual(source.count('"--ob-native-authkit-no-provision-v1"'), 1)
        self.assertEqual(len(re.findall(r"OBAuthKitRequested\s*=", source)), 2)
        for forbidden in ["getenv(", "NSProcessInfo", "openURL:", "continueUserActivity:"]:
            self.assertNotIn(forbidden, source)

    def test_authkit_first_active_once_and_manual_button_preserved(self):
        source = (DIRECTORY / "main.m").read_text()
        active = method_source(source, "- (void)applicationDidBecomeActive:(UIApplication *)application")
        native = method_source(source, "- (void)runNativeAnisetteCheck")
        self.assertIn("if (OBAuthKitRequested && !self.started)", active)
        self.assertIn("application.idleTimerDisabled = YES", active)
        self.assertEqual(source.count("[self runNativeAnisetteCheck]"), 1)
        self.assertIn("[self runNativeAnisetteCheck]", active)
        self.assertLess(native.index("if (self.started) return"), native.index("self.started = NSDate.date"))
        self.assertIn("self.runButton.enabled = NO", native)
        self.assertIn("action:@selector(runCheck) forControlEvents:UIControlEventTouchUpInside", source)
        self.assertEqual(len(re.findall(r"self\.started\s*=", source)), 2)
        self.assertNotIn("self.started = nil", source)

    def test_authkit_fetch_is_exactly_once_with_no_provision_or_fallback(self):
        source = (DIRECTORY / "main.m").read_text()
        native = method_source(source, "- (void)runNativeAnisetteCheck")
        self.assertIn('NSSelectorFromString(@"fetchAnisetteDataAndProvisionIfNecessary:error:")', native)
        self.assertEqual(native.count("(controller, fetch, NO, &error)"), 1)
        self.assertNotRegex(native, r"\b(?:while|for)\s*\(")
        for forbidden in ["provisionWithCompletion:", "eraseWithCompletion:", "syncWithSIMData:",
                          "anisetteDataWithError:", "anisetteDataWithCompletion:",
                          "legacyAnisetteDataForDSID:", "fetchAnisetteDataAndProvisionIfNecessary:withCompletion:",
                          "AAAbsintheSigner", "signatureForData:", "signStage:", "runCheck", "ACAccount"]:
            self.assertNotIn(forbidden, native)
        self.assertIn('@"provision_requested": @NO', native)

    def test_authkit_sync_and_data_accessors_have_abi_guards(self):
        source = (DIRECTORY / "main.m").read_text()
        native = method_source(source, "- (void)runNativeAnisetteCheck")
        for check in ["class_getInstanceMethod(controllerClass, fetch)",
                      "method_getArgumentType(method, 2, provisionType, sizeof(provisionType))",
                      "method_getArgumentType(method, 3, errorType, sizeof(errorType))",
                      "OBMethodHasType(method, 4, '@')", 'strcmp(provisionType, "B") == 0',
                      'strcmp(provisionType, "c") == 0', 'strcmp(errorType, "^@") == 0',
                      "id (*)(id, SEL, BOOL, NSError **)"]:
            self.assertIn(check, native)
        self.assertLess(native.index("BOOL abi ="), native.index("[controllerClass new]"))
        for accessor, encoding in [("machine", "@"), ("otp", "@"), ("routing", "Q")]:
            check = f"OBMethodHasType(class_getInstanceMethod(dataClass, {accessor}), 2, '{encoding}')"
            self.assertIn(check, native)
            self.assertLess(native.index(check), native.index(f")(data, {accessor})"))

    def test_authkit_metadata_contains_only_fixed_keys_and_bounded_error_fields(self):
        source = (DIRECTORY / "main.m").read_text()
        native = method_source(source, "- (void)runNativeAnisetteCheck")
        initializer = native.split("NSMutableDictionary *stage = [@{", 1)[1].split("} mutableCopy];", 1)[0]
        stage_keys = set(re.findall(r'@"([^"\n]+)"\s*:', initializer))
        stage_keys.update(re.findall(r'stage\[@"([^"\n]+)"\]', native))
        self.assertEqual(stage_keys, {"stage", "provision_requested", "class_present", "selector_abi_valid",
                                     "native_fetch_attempted", "machine_id_present", "otp_present",
                                     "routing_info_present", "error_present", "error_code", "error_domain"})
        for key in ["machine_id_present", "otp_present", "routing_info_present"]:
            self.assertRegex(native, rf'stage\[@"{key}"\]\s*=\s*@\(')
        self.assertIn("[machineValue isKindOfClass:NSString.class]", native)
        self.assertIn("[otpValue isKindOfClass:NSString.class]", native)
        self.assertIn("[machineValue length] <= 4096", native)
        self.assertIn("[otpValue length] <= 4096", native)
        self.assertIn('stage[@"routing_info_present"] = @(route != 0)', native)
        self.assertIn('stage[@"error_code"] = @(error.code)', native)
        self.assertIn('[error.domain isEqualToString:@"AKAnisetteErrorDomain"] ? @"AKAnisetteErrorDomain" : @"other"', native)
        self.assertIn('stage[@"error_domain"] = @"native-exception"', native)
        for key, value in re.findall(r'stage\[@"([^"\n]+)"\]\s*=\s*([^;]+);', native):
            if key == "error_domain":
                self.assertIn(value.strip(), {
                    '[error.domain isEqualToString:@"AKAnisetteErrorDomain"] ? @"AKAnisetteErrorDomain" : @"other"',
                    '@"native-exception"',
                })
            else:
                self.assertRegex(value.strip(), r"^(?:@\(.+\)|@YES|@NO)$")
        for forbidden in ["localizedDescription", "userInfo", ".description", "NSLog(", "printf(",
                          "addEntriesFromDictionary:", "setObject:", "writeTo", "NSJSONSerialization"]:
            self.assertNotIn(forbidden, native)

    def test_authkit_observer_is_installed_before_background_framework_work(self):
        source = (DIRECTORY / "main.m").read_text()
        native = method_source(source, "- (void)runNativeAnisetteCheck")
        self.assertIn("45 * NSEC_PER_SEC", native)
        self.assertIn("[self.started dateByAddingTimeInterval:45]", native)
        self.assertLess(native.index("dispatch_after("), native.index("dispatch_async(self.nativeQueue"))
        self.assertLess(native.index("dispatch_async(self.nativeQueue"), native.index("dlopen("))
        self.assertIn("DISPATCH_QUEUE_SERIAL", native)
        self.assertIn("native-context-observation-timeout-underlying-work-unqualified", native)

    def test_authkit_rechecks_deadline_and_cancellation_after_controller_initialization(self):
        source = (DIRECTORY / "main.m").read_text()
        native = method_source(source, "- (void)runNativeAnisetteCheck")
        self.assertIn("@property(atomic) BOOL nativeContextCancelled;", source)
        self.assertEqual(source.count("self.nativeContextCancelled = NO;"), 1)
        self.assertLess(native.index("if (self.started) return"), native.index("self.nativeContextCancelled = NO;"))
        self.assertLess(native.index("self.nativeContextCancelled = NO;"), native.index("dispatch_async(self.nativeQueue"))
        worker = native.split("dispatch_async(self.nativeQueue, ^{", 1)[1]
        worker = worker.split("dispatch_async(dispatch_get_main_queue(), ^{", 1)[0]
        self.assertIn("if (weakSelf.nativeContextCancelled || deadline.timeIntervalSinceNow <= 0) return;", worker)
        self.assertNotRegex(worker, r"(?:self|weakSelf|owner)\.finished\b",
                            "Background work must not read the main-queue nonatomic completion flag.")
        self.assertIn("if (abi && !weakSelf.nativeContextCancelled && deadline.timeIntervalSinceNow > 0)", worker)
        before_fetch = native.split("id controller = [controllerClass new];", 1)[1]
        before_fetch = before_fetch.split("id data =", 1)[0]
        self.assertIn("if (controller && !weakSelf.nativeContextCancelled && deadline.timeIntervalSinceNow > 0)",
                      before_fetch, "Both deadline and cancellation must gate fetch after initialization.")

    def test_authkit_resign_and_late_delivery_finish_once_without_native_values(self):
        source = (DIRECTORY / "main.m").read_text()
        native = method_source(source, "- (void)runNativeAnisetteCheck")
        resign = method_source(source, "- (void)applicationWillResignActive:(UIApplication *)application")
        finish = method_source(source, "- (void)finish:(NSString *)disposition")
        self.assertIn("OBAuthKitRequested && self.started && !self.finished", resign)
        self.assertIn("native-context-cancelled-underlying-work-unqualified", resign)
        self.assertIn("self.nativeContextCancelled = YES;", resign)
        self.assertIn("application.idleTimerDisabled = NO", resign)
        delivery = native.rsplit("dispatch_async(dispatch_get_main_queue(), ^{", 1)[1]
        self.assertLess(delivery.index("if (!owner || owner.finished) return"), delivery.index("[owner.stages addObject:"))
        for forbidden in ["machineValue", "otpValue", "NSError", "route !=", "objc_msgSend"]:
            self.assertNotIn(forbidden, delivery)
        self.assertLess(finish.index("if (self.finished) return"), finish.index("self.finished = YES"))
        self.assertIn("self.nativeContextCancelled = YES;", finish)
        self.assertLess(finish.index("self.nativeContextCancelled = YES;"), finish.index("NSDictionary *metadata"))
        self.assertIn("idleTimerDisabled = NO", finish)
        self.assertIn('@"signatures_retained": @NO', finish)
        self.assertIn('@"account_credentials_supplied": @NO', finish)
        self.assertIn('@"login_qualified": @NO', finish)

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
        job = re.split(r"\n  [a-z][a-z0-9-]+:\n", text.split("  iphone-account-signing-preflight:\n", 1)[1], maxsplit=1)[0]
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
