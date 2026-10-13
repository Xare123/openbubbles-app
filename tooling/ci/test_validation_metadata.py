"""Protect public diagnostics from private input/proof material."""
import json
import unittest
from validation_metadata import sanitize_output


class ValidationMetadata(unittest.TestCase):
    def test_raw_native_error_is_removed(self):
        raw = json.dumps({"step":"failed","error":"fixture-private-value-should-never-appear","elapsed_seconds":1}).encode()
        output = sanitize_output(raw)
        self.assertNotIn(b"fixture-private", output)
        self.assertIn(b"validation_failed", output)

    def test_nac_numeric_failure_survives_without_raw_string(self):
        event = json.loads(sanitize_output(b'{"step":"failed","error":"NAC return code -7"}'))
        self.assertEqual(event["error_code"], -7)
        self.assertNotIn("error", event)

    def test_unknown_payload_field_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "unapproved"):
            sanitize_output(b'{"step":"sign","proof":"fixture-private-value"}')

    def test_secret_disguised_as_counter_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "value"):
            sanitize_output(b'{"step":"hardware","input_bytes":"fixture-private-value"}')

    def test_partial_zero_exit_cannot_qualify(self):
        with self.assertRaisesRegex(ValueError, "incomplete"):
            sanitize_output(b'{"step":"complete","elapsed_seconds":1}', require_complete=True)

    def test_complete_metadata_is_admitted_without_account_claim(self):
        events = [
            {"step":"framework","sha256":"a"*64,"bytes":6222784,"hash_verified":True},
            {"step":"hardware","input_bytes":423,"input_sha256":"b"*64,"encrypted_fields":[8]*5,"identity_preserved":True},
            {"step":"bag","http_status":200,"bytes":100},
            {"step":"certificate","http_status":200,"bytes":200},
            {"step":"nac_init","request_bytes":50,"result":"success"},
            {"step":"session","http_status":200,"bytes":100},
            {"step":"key_establishment","response_bytes":50,"result":"success"},
            {"step":"sign","proof_bytes":100,"proof_sha256":"c"*64,"result":"generated","account_acceptance":"UNRUN","production_integration":"UNRUN"},
            {"step":"complete","elapsed_seconds":3},
        ]
        raw = "\n".join(json.dumps(event) for event in events).encode()
        output = sanitize_output(raw, require_complete=True)
        self.assertEqual(len(output.splitlines()), 9)
        self.assertIn(b'"account_acceptance": "UNRUN"', output)


if __name__ == "__main__":
    unittest.main()
