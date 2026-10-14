import contextlib
import io
import json
import os
import plistlib
import socket
import ssl
import urllib.error
import unittest
from unittest import mock

import run_windows_adi_machine as probe


class Response(io.BytesIO):
    status = 200


class Opener:
    def __init__(self, data):
        self.data = data
        self.requests = []

    def open(self, request, timeout):
        self.requests.append((request, timeout))
        return Response(self.data)


class MachineContractTests(unittest.TestCase):
    def test_only_pinned_official_roots_preserve_strict_tls(self):
        context = probe.apple_tls()
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)

    def test_network_diagnostics_separate_causes_without_private_details(self):
        failures = [
            (ssl.SSLCertVerificationError(1, "secret-url"), "tls-certificate"),
            (ssl.SSLError(1, "secret-url"), "tls"),
            (socket.gaierror(-2, "secret-host"), "dns"),
            (TimeoutError("secret-token"), "timeout"),
            (ConnectionRefusedError(111, "secret-token"), "connection"),
        ]
        for error, kind in failures:
            with self.subTest(kind=kind), contextlib.redirect_stdout(io.StringIO()) as output:
                probe.network_failure("lookup", urllib.error.URLError(error))
            self.assertEqual(json.loads(output.getvalue())["failure"], kind)
            self.assertNotIn("secret", output.getvalue())

    def test_only_exact_apple_https_hosts_and_grandslam_paths(self):
        for url in (probe.LOOKUP, "https://gsd.apple.com/grandslam/start"):
            self.assertEqual(probe.apple_url(url), url)
        for url in (None, "http://gsa.apple.com/grandslam/start",
                    "https://gsa.apple.com.attacker.invalid/grandslam/start",
                    "https://gsa.apple.com:444/grandslam/start",
                    "https://user:secret@gsa.apple.com/grandslam/start",
                    "https://gsa.apple.com/grandslam/start?secret=value",
                    "https://gsa.apple.com/grandslam/start#fragment",
                    "https://gsa.apple.com/other", "https://[bad"):
            with self.subTest(url=url), self.assertRaises(probe.ProbeError):
                probe.apple_url(url)

    def test_unapproved_endpoint_never_reaches_opener(self):
        opener = Opener(b"unused")
        with self.assertRaises(probe.ProbeError):
            probe.request(opener, "lookup", "https://other.invalid/grandslam/", {})
        self.assertEqual(opener.requests, [])

    def test_redirects_are_not_followed(self):
        self.assertIsNone(probe.NoRedirect().redirect_request(None, None, 302, "", {}, probe.LOOKUP))

    def test_network_body_and_errors_are_not_printed(self):
        private = "private-token-not-for-logs"
        opener = Opener(plistlib.dumps({"Response": {"spim": private}}))
        with contextlib.redirect_stdout(io.StringIO()) as output:
            result = probe.request(opener, "start", probe.LOOKUP, {})
        self.assertEqual(result["Response"]["spim"], private)
        self.assertNotIn(private, output.getvalue())
        self.assertEqual(opener.requests[0][1], 20)

    def test_bounded_plist_body(self):
        for body in (b"<html>private</html>", b"x" * (probe.MAX_BODY + 1)):
            with self.subTest(length=len(body)), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(probe.ProbeError):
                probe.request(Opener(body), "lookup", probe.LOOKUP, {})

    def test_native_blobs_require_nonempty_strict_base64(self):
        self.assertEqual(probe.binary_string({"spim": "AQID"}, "spim"), "AQID")
        for value in (None, 7, "", "***", "AA==\n", "A" * probe.MAX_BODY):
            with self.subTest(kind=type(value).__name__), self.assertRaises(probe.ProbeError):
                probe.binary_string({"spim": value}, "spim")

    def test_apple_status_is_numeric_and_sanitized(self):
        with contextlib.redirect_stdout(io.StringIO()) as output, self.assertRaises(probe.ProbeError):
            probe.response_dict({"Response": {"Status": {"ec": -1, "em": "secret"}}})
        self.assertNotIn("secret", output.getvalue())
        for value in ({}, {"Response": []}, {"Response": {"Status": {"ec": "0"}}}):
            with self.assertRaises(probe.ProbeError):
                probe.response_dict(value)

    def test_existing_success_is_not_full_account_acceptance(self):
        self.assertEqual(probe.response_dict({"Response": {"Status": {"ec": 0}}}), {"Status": {"ec": 0}})

    def test_complete_mock_handshake_redacts_identity_and_buffers(self):
        identity = ".".join(["12345678"] * 7)
        records = [
            {"stage": "ready", "device_id": identity},
            {"stage": "started", "cpim": "AQID"},
            {"stage": "provisioned", "provisioned": True},
            {"stage": "cleanup", "machine_state_removed": True},
        ]
        child = mock.Mock()
        child.stdout = io.StringIO("".join(json.dumps(value) + "\n" for value in records))
        child.stdin = io.StringIO()
        child.wait.return_value = 0
        child.poll.return_value = 0
        responses = [
            {"urls": {"midStartProvisioning": "https://gsa.apple.com/grandslam/start",
                      "midFinishProvisioning": "https://gsa.apple.com/grandslam/finish"}},
            {"Response": {"spim": "BAUG"}},
            {"Response": {"ptm": "BwgJ", "tk": "CgsM", "X-Apple-I-MD-RINFO": "17106176"}},
        ]
        with mock.patch.object(probe.os, "name", "nt"), mock.patch.dict(os.environ, {
            "GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "github-hosted"
        }), mock.patch("sys.argv", ["probe", "--probe", "test.exe", "--library", "verified.dll"]), \
                mock.patch.object(probe.subprocess, "Popen", return_value=child), \
                mock.patch.object(probe.subprocess, "CREATE_NO_WINDOW", 0, create=True), \
                mock.patch.object(probe, "request", side_effect=responses) as requests, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            probe.main()
        receipt = output.getvalue()
        for private in (identity, "AQID", "BAUG", "BwgJ", "CgsM"):
            self.assertNotIn(private, receipt)
        self.assertIn('"sms_requested": false', receipt)
        self.assertIn('"machine_state_removed": true', receipt)
        self.assertEqual(requests.call_count, 3)
        child.kill.assert_not_called()


if __name__ == "__main__":
    unittest.main()
