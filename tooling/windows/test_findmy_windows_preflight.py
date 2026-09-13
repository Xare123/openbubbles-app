"""Offline tests only. Every profile below is generated synthetic data."""
import copy
import importlib.util
from pathlib import Path
import plistlib
import re
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("preflight", HERE / "findmy_windows_preflight.py")
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class RetainedPreflightTests(unittest.TestCase):
    def setUp(self):
        root = HERE.parent.parent / "build"
        root.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="findmy-synthetic-", dir=root)
        self.addCleanup(self.temp.cleanup)
        self.profile = Path(self.temp.name)
        (self.profile / "anisette_test").mkdir()
        (self.profile / ".openbubbles-cloud-sync-v2-windows-dev").write_text(preflight.MARKER)
        self.values = {
            "hw_info.plist": {"identity": b"synthetic-encrypted-identity",
                "os_config": {"type": "Relay", "host": "https://synthetic.invalid",
                    "code": "synthetic-credential", "dev_uuid": "synthetic-uuid"},
                "push": {"token": b"a" * 32, "keypair": {"private": "aps-key", "cert": b"cert"}}},
            "gsa.plist": {"username": "synthetic-user", "encrypted_password": b"synthetic-password",
                "postdata_done": True},
            "keystore.plist": {"format_version": 2, "protected_master_key": b"synthetic-dpapi",
                "state": {"keys": {alias: b"synthetic-encrypted-key" for alias in
                    ("aps-key", "gsa:password", "ids:identity-storage-key:openbubbles")}, "secrets": {}}},
            "sharedstreams.plist": {"dsid": "synthetic-dsid"},
            "anisette_test/state.plist": {"keychain_identifier": b"i" * 16,
                "adi_pb": b"synthetic-adi", "endpoint": preflight.ANISETTE_ENDPOINT},
        }
        self.write()

    def write(self, fmt=plistlib.FMT_BINARY):
        for name, value in self.values.items():
            (self.profile / name).write_bytes(plistlib.dumps(value, fmt=fmt))

    def test_binary_and_xml_have_identical_private_snapshots(self):
        binary = preflight.retained_snapshot(self.profile)
        self.write(plistlib.FMT_XML)
        self.assertEqual(binary, preflight.retained_snapshot(self.profile))
        self.assertTrue(all(re.fullmatch("[a-f0-9]{64}", value) for value in binary.values()))

    def test_every_missing_retained_file_is_rejected_without_creation(self):
        for name in self.values:
            with self.subTest(name=name):
                target = self.profile / name
                encoded = target.read_bytes()
                target.unlink()
                with self.assertRaises(Exception):
                    preflight.retained_snapshot(self.profile)
                self.assertFalse(target.exists())
                target.write_bytes(encoded)

    def test_missing_keys_cannot_trigger_ensure_creation(self):
        baseline = copy.deepcopy(self.values)
        for alias in baseline["keystore.plist"]["state"]["keys"]:
            self.values = copy.deepcopy(baseline)
            del self.values["keystore.plist"]["state"]["keys"][alias]
            self.write()
            with self.subTest(alias=alias), self.assertRaises(preflight.Rejected):
                preflight.retained_snapshot(self.profile)

    def test_retained_field_gates(self):
        baseline = copy.deepcopy(self.values)
        cases = [
            ("hw_info.plist", ["identity"], b""),
            ("hw_info.plist", ["push", "token"], b"short"),
            ("gsa.plist", ["postdata_done"], False),
            ("gsa.plist", ["postdata_done"], 1),
            ("gsa.plist", ["encrypted_password"], b""),
            ("keystore.plist", ["format_version"], 1),
            ("sharedstreams.plist", ["dsid"], ""),
            ("anisette_test/state.plist", ["endpoint"], "https://different.invalid"),
            ("anisette_test/state.plist", ["adi_pb"], b""),
            ("anisette_test/state.plist", ["keychain_identifier"], b"short"),
        ]
        for name, keys, value in cases:
            self.values = copy.deepcopy(baseline)
            target = self.values[name]
            for key in keys[:-1]:
                target = target[key]
            target[keys[-1]] = value
            self.write()
            with self.subTest(name=name, keys=keys), self.assertRaises(preflight.Rejected):
                preflight.retained_snapshot(self.profile)

    def test_local_state_and_adi_renewal_do_not_look_like_identity_change(self):
        before = preflight.retained_snapshot(self.profile)
        self.values["hw_info.plist"]["push"]["token"] = b"b" * 32
        self.values["hw_info.plist"]["identity"] = b"same-identity-new-aes-gcm-nonce"
        self.values["anisette_test/state.plist"]["adi_pb"] = b"renewed-adi"
        self.write()
        self.assertEqual(before, preflight.retained_snapshot(self.profile))

    def test_existing_identity_and_service_can_renew_absent_adi_material(self):
        before = preflight.retained_snapshot(self.profile)
        del self.values["anisette_test/state.plist"]["adi_pb"]
        self.write()
        self.assertEqual(before, preflight.retained_snapshot(self.profile))

    def test_configuration_or_credentials_drift_is_detected(self):
        before = preflight.retained_snapshot(self.profile)
        self.values["gsa.plist"]["username"] = "different-synthetic-user"
        self.write()
        self.assertNotEqual(before, preflight.retained_snapshot(self.profile))

    def test_malformed_and_oversized_input_fails_without_echo(self):
        (self.profile / "keystore.plist").write_bytes(b"private-invalid-plist")
        with self.assertRaises(Exception):
            preflight.retained_snapshot(self.profile)
        with self.assertRaises(preflight.Rejected):
            preflight.bounded(self.profile / "keystore.plist", 2)

    def test_symlink_is_rejected(self):
        link = self.profile / "linked"
        try:
            link.symlink_to(self.profile / "gsa.plist")
        except OSError:
            self.skipTest("host does not permit synthetic symlink creation")
        with self.assertRaises(preflight.Rejected):
            preflight.bounded(link)

    def test_source_pins_match_reviewed_bridge_and_probe(self):
        for relative, expected in preflight.SOURCE_PINS.items():
            self.assertEqual(expected, preflight.file_hash(HERE.parent.parent / relative), relative)

    def test_host_native_surface_excludes_remote_writers_and_app_bootstrap(self):
        host = (HERE.parent.parent / "test/live/findmy_windows_live_test.dart").read_text()
        self.assertEqual(set(re.findall(r"api\s*\.\s*(\w+)\(", host)), {
            "doFirstTimeInit", "readHardware", "decodeIdentity", "setupPush", "closeAps",
            "makeAnisette", "restoreAccount", "makeTokenProvider", "makeFindMyPhone",
            "makeFindMyFriends", "refreshDevices", "refreshFollowing", "selectFriend",
        })
        self.assertNotIn("cloud_sync_v2_windows_harness.dart", host)
        self.assertNotIn("Database.init(", host)
        self.assertNotIn("Logger.init(", host)


if __name__ == "__main__":
    unittest.main()
