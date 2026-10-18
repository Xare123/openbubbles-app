"""Frozen-fixture/parser/privacy guards. Not native compile, USB or login proof."""
import hashlib
import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
DIRECTORY = ROOT / "tooling/ios/account-qualifier-fixture"
SPEC = importlib.util.spec_from_file_location("ob_qualifier_validation", DIRECTORY / "validate_fixture.py")
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)
BUNDLE = "dev.openbubbles.diagnostics.accountqualifier"
RUN = "0a34797b7dc44e8e8a41f1fe4c2b01d8"
CLIENT = "7332110D-8CF0-4B5A-9C4D-EB9C806CF832"


def synthetic_body():
    return {"protocolVersion": "1.0", "userInfo": {"client-id": CLIENT, "language": "en-US",
            "timezone": "America/New_York"}, "delegates": {"com.apple.private.ids":
            {"protocol-version": "4"}, "com.apple.mobileme": {}}}


def packed(value=None, body=None, **changes):
    body = body if body is not None else plistlib.dumps(value or synthetic_body(), sort_keys=False)
    info = {"schema": 1, "run_id": RUN, "client_id": CLIENT, "body_sha256": hashlib.sha256(body).hexdigest()}
    info.update(changes)
    return json.dumps(info).encode(), body


class FixtureValidationTests(unittest.TestCase):
    def test_validates_bytes_without_reserializing(self):
        metadata, body = packed()
        self.assertEqual(VALIDATOR.validate_bytes(metadata, body)["body_sha256"], hashlib.sha256(body).hexdigest())
        self.assertEqual(body, plistlib.dumps(synthetic_body(), sort_keys=False))

    def test_unknown_credential_fields_fail_at_every_level(self):
        for keypath in [(), ("userInfo",), ("delegates",), ("delegates", "com.apple.private.ids"),
                        ("delegates", "com.apple.mobileme")]:
            value = synthetic_body()
            target = value
            for key in keypath:
                target = target[key]
            target["password"] = "synthetic-forbidden"
            with self.subTest(keypath=keypath), self.assertRaises(VALIDATOR.FixtureError):
                VALIDATOR.validate_bytes(*packed(value))

    def test_manifest_requires_exact_keys_and_strict_types(self):
        cases = [{"schema": True}, {"schema": 1.0}, {"schema": "1"}, {"run_id": "A" * 32},
                 {"client_id": CLIENT.lower()}, {"run_id": RUN + "\n"}, {"source_sha": "0" * 40}]
        for changes in cases:
            with self.subTest(changes=changes), self.assertRaises(VALIDATOR.FixtureError):
                VALIDATOR.validate_bytes(*packed(**changes))

    def test_hash_size_format_and_entities_fail(self):
        metadata, body = packed()
        for candidate in [body + b" ", b"", b"x" * 8193]:
            with self.subTest(length=len(candidate)), self.assertRaises(VALIDATOR.FixtureError):
                VALIDATOR.validate_bytes(metadata, candidate)
        binary = plistlib.dumps(synthetic_body(), fmt=plistlib.FMT_BINARY)
        for candidate in [binary, b'<!ENTITY x "x">' + body]:
            with self.assertRaises(VALIDATOR.FixtureError):
                VALIDATOR.validate_bytes(*packed(body=candidate))

    def test_duplicate_json_and_plist_keys_fail(self):
        metadata, body = packed()
        duplicate_json = metadata[:-1] + b', "schema": 1}'
        with self.assertRaises(VALIDATOR.FixtureError):
            VALIDATOR.validate_bytes(duplicate_json, body)
        marker = b"<key>protocolVersion</key>"
        duplicate_body = body.replace(marker, b"<key>protocolVersion</key><string>1.0</string>" + marker, 1)
        with self.assertRaises(VALIDATOR.FixtureError):
            VALIDATOR.validate_bytes(*packed(body=duplicate_body))

    def test_mismatched_client_and_non_ascii_metadata_fail(self):
        for field, text in [("client-id", "8332110D-8CF0-4B5A-9C4D-EB9C806CF832"),
                            ("language", "en\nUS"), ("timezone", "x" * 129), ("language", "é")]:
            value = synthetic_body()
            value["userInfo"][field] = text
            with self.subTest(field=field), self.assertRaises(VALIDATOR.FixtureError):
                VALIDATOR.validate_bytes(*packed(value))

    def test_parent_files_when_present_match_actual_contract(self):
        paths = [DIRECTORY / "fixture.json", DIRECTORY / "body.plist"]
        if not all(path.exists() for path in paths):
            self.skipTest("Parent frozen fixture files not supplied yet")
        metadata = paths[0].read_bytes()
        source_body = paths[1].read_bytes()
        exact_body = VALIDATOR.normalize_source_body(metadata, source_body)
        info = VALIDATOR.validate_bytes(metadata, exact_body)
        self.assertEqual(info["run_id"], RUN)
        self.assertEqual(info["client_id"], CLIENT)
        self.assertEqual(len(exact_body), 647)
        self.assertEqual(info["body_sha256"], "9b2e7baef14416e69de6d8a09d3096c5d697b9b02216af5edda3157523cec239")
        with tempfile.TemporaryDirectory(prefix=".fixture-stage-test-", dir=DIRECTORY) as output:
            metadata_copy, staged_body, staged_info = VALIDATOR.stage_fixture(DIRECTORY, pathlib.Path(output))
            self.assertEqual(metadata_copy, metadata)
            self.assertEqual(staged_body, exact_body)
            self.assertEqual(staged_info, info)
            self.assertEqual(VALIDATOR.load_fixture(pathlib.Path(output))[1], exact_body)
            with self.assertRaises(VALIDATOR.FixtureError):
                VALIDATOR.stage_fixture(DIRECTORY, pathlib.Path(output))
        self.assertEqual(paths[1].read_bytes(), source_body)

    def test_source_normalization_is_exactly_one_hash_verified_lf(self):
        exact = plistlib.dumps(synthetic_body(), sort_keys=False).removesuffix(b"\n")
        metadata, _body = packed(body=exact)
        self.assertEqual(VALIDATOR.normalize_source_body(metadata, exact), exact)
        self.assertEqual(VALIDATOR.normalize_source_body(metadata, exact + b"\n"), exact)
        for suffix in [b"\n\n", b"\r\n", b" ", b" \n", b"\n "]:
            with self.subTest(suffix=suffix), self.assertRaises(VALIDATOR.FixtureError):
                VALIDATOR.normalize_source_body(metadata, exact + suffix)
        with self.assertRaises(VALIDATOR.FixtureError):
            VALIDATOR.validate_bytes(metadata, exact + b"\n")
        with self.assertRaises(VALIDATOR.FixtureError):
            VALIDATOR.normalize_source_body(metadata, exact.replace(b"en-US", b"en-GB") + b"\n")
        legitimate_lf = exact + b"\n"
        lf_metadata, _body = packed(body=legitimate_lf)
        self.assertEqual(VALIDATOR.normalize_source_body(lf_metadata, legitimate_lf), legitimate_lf)


class NativeBoundaryGuards(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (DIRECTORY / "main.m").read_text()
        cls.build = (DIRECTORY / "build.sh").read_text()

    def test_bundle_entitlements_are_distinct_and_exact(self):
        info = plistlib.loads((DIRECTORY / "Info.plist").read_bytes())
        entitlements = plistlib.loads((DIRECTORY / "entitlements.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], BUNDLE)
        self.assertEqual(info["CFBundleExecutable"], "OBAccountQualifierFixture")
        self.assertEqual(set(entitlements), {"application-identifier", "keychain-access-groups",
            "com.apple.private.MobileGestalt.AllowedProtectedKeys", "abs-client"})
        self.assertEqual(entitlements["application-identifier"], BUNDLE)
        self.assertEqual(entitlements["keychain-access-groups"], [BUNDLE])
        self.assertEqual(entitlements["abs-client"], 772496756)
        self.assertEqual(entitlements["com.apple.private.MobileGestalt.AllowedProtectedKeys"], ["SerialNumber", "UniqueDeviceID"])
        for key in ["UIBackgroundModes", "CFBundleURLTypes", "UIFileSharingEnabled", "NSAppTransportSecurity"]:
            self.assertNotIn(key, info)

    def test_listener_and_fixed_frame_have_no_payload_input(self):
        self.assertEqual(len(("OBQUAL1:" + RUN + "\n").encode("ascii")), 41)
        self.assertIn('inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)', self.source)
        self.assertIn("OBPort = 49173, OBHeaderBytes = 41", self.source)
        self.assertIn("uint8_t bytes[OBHeaderBytes + 1]", self.source)
        self.assertIn("if (used > OBHeaderBytes) return NO", self.source)
        self.assertIn("if (count == 0) break", self.source)
        self.assertEqual(self.source.count("recv("), 1)
        for forbidden in ["INADDR_ANY", "AF_INET6", "SO_REUSEPORT", "SO_REUSEADDR", "0.0.0.0"]:
            self.assertNotIn(forbidden, self.source)
        read_request = self.source.split("static BOOL OBReadRequest", 1)[1].split("static BOOL OBSendAll", 1)[0]
        self.assertNotIn("signer", read_request)
        self.assertNotIn("payload", read_request.split("for (;;)", 1)[1])

    def test_descriptor_ownership_and_io_deadlines(self):
        close = self.source.split("static void OBClose", 1)[1].split("static BOOL OBNonblocking", 1)[0]
        self.assertLess(close.index("*ownedFD = -1"), close.index("close(fd)"))
        exchange = self.source.split("- (void)runExchange:", 1)[1]
        self.assertLess(exchange.index("OBClose(&listener)"), exchange.index("OBReadRequest("))
        self.assertIn("OBExchangeSeconds = 54", self.source)
        self.assertIn("OBReplySeconds = 3", self.source)
        self.assertIn("OBHeaderSeconds = 10", self.source)
        self.assertIn("O_NONBLOCK", self.source)
        self.assertIn("SO_NOSIGPIPE", self.source)
        self.assertIn("OBWait(fd, POLLIN, deadline, control)", self.source)
        self.assertIn("OBWait(fd, POLLOUT, deadline, control)", self.source)
        self.assertIn("@finally", exchange)
        self.assertIn("OBClose(&peer); OBClose(&listener)", exchange)

    def test_native_deadline_abi_and_same_signer(self):
        job = self.source.split("@implementation OBSigningJob", 1)[1].split("static NSData *OBResponse", 1)[0]
        self.assertLess(job.index("dispatch_after("), job.index("dlopen("))
        self.assertIn("self->_done || self->_phase != phase || OBNow() >= self->_deadline", job)
        self.assertIn("[self invokePhase:2 signer:signer payload:self->_body]", job)
        self.assertIn("[self invokePhase:1 signer:signer payload:NSData.data]", job)
        self.assertIn("OBMethodHasType(method, 4, 'v')", job)
        self.assertIn('strcmp(completionType, "@?")', job)
        self.assertIn("if ([self activePhase:phase])", job)
        for forbidden in ["recv(", "send(", "close(", "shutdown("]:
            self.assertNotIn(forbidden, job)

    def test_response_exact_keys_bounded_and_no_failure_proofs(self):
        response = self.source.split("static NSData *OBResponse", 1)[1].split("@interface OBAccountQualifierFixture", 1)[0]
        for key in ["schema", "source_sha", "run_id", "body_sha256", "empty_signature_b64",
                    "body_signature_b64", "elapsed_ms", "error"]:
            self.assertIn('@"' + key + '"', response)
        self.assertEqual(response.count("error ? @\"\""), 2)
        self.assertIn("json.length <= OBMaxReply", response)
        self.assertIn("htonl((uint32_t)json.length)", self.source)
        self.assertIn("OBMaxSignature = 2048", self.source)
        self.assertIn("OBMaxReply = 16384", self.source)

    def test_no_account_disk_or_http_output(self):
        for forbidden in ["URLSession", "NSLog(", "printf(", "writeTo", "NSDocumentDirectory", "SecItem",
                          "ACAccount", "performSignedRequest", "signatureForData:\")", "UIApplication openURL",
                          "https://", "http://", "CFStream", "NWListener"]:
            self.assertNotIn(forbidden, self.source)
        self.assertEqual(self.source.count("NSSelectorFromString("), 3)
        self.assertIn("OBErase(_emptySignature); OBErase(_bodySignature)", self.source)
        ui = self.source.split("@implementation OBAccountQualifierFixture", 1)[1]
        self.assertNotIn("base64EncodedString", ui)
        self.assertIn("if (self.control) return", ui)
        self.assertIn("applicationWillResignActive", ui)

    def test_build_pins_original_bytes_without_device_or_network(self):
        self.assertIn('! -e "$output" && ! -L "$output"', self.build)
        self.assertIn('validate_fixture.py" --source "$source_dir"', self.build)
        self.assertIn('validate_fixture.py" --stage "$app" "$source_dir"', self.build)
        self.assertIn('validate_fixture.py" "$app"', self.build)
        self.assertNotIn('cp -- "$source_dir/body.plist"', self.build)
        for macro in ["OB_SOURCE_SHA", "OB_FIXTURE_BODY_SHA256", "OB_FIXTURE_JSON_SHA256"]:
            self.assertIn(macro, self.build)
            self.assertIn(macro, self.source)
        for forbidden in ["curl ", "wget ", "rm ", "sudo ", "pymobile", "idevice", "devicectl", "git clone", "gcloud "]:
            self.assertNotIn(forbidden, self.build)
        self.assertIn("arm64-apple-ios14.0", self.build)
        self.assertIn("codesign --verify --deep --strict", self.build)


if __name__ == "__main__":
    unittest.main()
