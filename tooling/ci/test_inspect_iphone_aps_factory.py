import inspect
from pathlib import Path
import unittest

import inspect_iphone_aps_factory as probe


class APSFactoryGuards(unittest.TestCase):
    def test_followup_targets_only_two_observed_blocks_not_original_factory(self):
        self.assertEqual(probe.BLOCKS, {
            "___29+[APSConnection copyIdentity]_block_invoke": 0x1a2f43848,
            "___29+[APSConnection copyIdentity]_block_invoke.202": 0x1a2f43978,
        })
        self.assertEqual(probe.EXPECTED_CACHE_SHA256,
            "feb18dafcc76f6583b68575b34414f233749100430608624336c7112fbab39d7")
        with self.assertRaises(ValueError):
            probe.factory_command(Path("ipsw"), Path("cache"), Path("owned"), "+[APSConnection copyIdentity]")

    def test_mode_is_explicit_and_excludes_old_analysis_and_writes(self):
        for env in ({}, {"NATIVE_APS_FACTORY_ANALYSIS": "false"},
                    {"NATIVE_APS_FACTORY_ANALYSIS": "True"},
                    {"NATIVE_APS_FACTORY_ANALYSIS": "true", "NATIVE_CONTRACT_ANALYSIS": "true"},
                    {"NATIVE_APS_FACTORY_ANALYSIS": "true", "AUTOMATIC_UPLOADS": "true"},
                    {"NATIVE_APS_FACTORY_ANALYSIS": "true", "OUTBOUND_WRITER": "true"}):
            with self.subTest(env=env), self.assertRaises(ValueError):
                probe.require_mode(env)
        probe.require_mode({"NATIVE_APS_FACTORY_ANALYSIS": "true"})

    def test_only_one_fixed_factory_not_whole_image_disassembly(self):
        command = probe.factory_command(Path("ipsw"), Path("cache"), Path("owned"), next(iter(probe.BLOCKS)))
        self.assertEqual(command, ["ipsw", "dyld", "disass", "cache", "--vaddr", "0x1a2f43848",
            "--cache", str(Path("owned/aps-symbols.a2s"))])
        for flag in ("--image", "--force", "--dec", "--dylibs", "--quiet", "--json"):
            self.assertNotIn(flag, command)

    def test_metadata_is_only_one_framework_without_extraction(self):
        self.assertEqual(probe.metadata_command(Path("ipsw"), Path("cache")),
            ["ipsw", "dyld", "macho", "cache", probe.IMAGE, "--objc"])

    def test_metadata_selects_named_class_or_method_only(self):
        value = probe.select_metadata(b"ignored\n@interface APSConnection : NSObject\n+copyIdentity; //0x123\nignored\n")
        self.assertEqual([row["line"] for row in value], [2, 3])
        with self.assertRaises(ValueError):
            probe.select_metadata(b"copyIdentity\n" * 25)

    def test_real_addressed_factory_required_not_declaration_or_text(self):
        symbol = next(iter(probe.BLOCKS))
        for raw in (b"", symbol.encode(), b"0x180001000: 00 00 80 d2 mov x0, #0",
                    (symbol + "\n0x100000000: 00 00 80 d2 mov x0, #0").encode()):
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                probe.parse_factory(raw, symbol)

    def test_two_instruction_fixture_remains_static_not_runtime_proof(self):
        symbol = next(iter(probe.BLOCKS))
        result = probe.parse_factory((symbol + ":\n"
            "0x1a2f43848: 00 00 80 d2 mov x0, #0\n"
            "0x1a2f4384c: c0 03 5f d6 ret\n").encode(), symbol)
        self.assertEqual(result["instruction_count"], 2)
        self.assertFalse(result["executed"])
        self.assertFalse(result["cause_of_runtime_null_proved"])

    def test_noncontiguous_duplicate_or_oversized_bodies_rejected(self):
        symbol = next(iter(probe.BLOCKS))
        for raw in ((symbol + "\n0x1a2f43848: 00 00 80 d2 mov x0, #0\n"
                     "0x1a2f43850: c0 03 5f d6 ret").encode(),
                    b"x" * 300001):
            with self.subTest(size=len(raw)), self.assertRaises(ValueError):
                probe.parse_factory(raw, symbol)

    def test_other_block_name_or_wrong_entry_rejected(self):
        symbol = next(iter(probe.BLOCKS))
        with self.assertRaises(ValueError):
            probe.parse_factory(b"0x1a2f43848: c0 03 5f d6 ret", "some-other-function")
        with self.assertRaises(ValueError):
            probe.parse_factory(b"0x1a2f43978: c0 03 5f d6 ret", symbol)

    def test_owns_readonly_mount_and_complete_cleanup_without_native_execution(self):
        source = inspect.getsource(probe.inspect_on_mac)
        for marker in ("owned.readonly_attach_command", "os.ST_RDONLY", "owned.validate_out_root",
                       "owned.owned_images", "owned.stop_owned", "temp not in work.parents",
                       "owned_images_detached", "owned_process_groups_reaped", "owned_work_removed"):
            self.assertIn(marker, source)
        for marker in ("pymobiledevice3", "get-validation-data", "issueClientCertificate", "SecItemCopyMatching"):
            self.assertNotIn(marker, source)

    def test_workflow_opt_in_runs_only_new_suite_and_preserves_old_path(self):
        path = Path(__file__).resolve().parents[2] / ".github/workflows/gce-runner-pilot.yml"
        source = path.read_text(encoding="utf-8")
        self.assertTrue("native_aps_factory_analysis:" in source, "new explicit opt-in missing")
        self.assertTrue("NATIVE_APS_FACTORY_ANALYSIS:" in source, "new opt-in env missing")
        job = source.split("\n  iphone-activation-static:\n", 1)[1].split("\n  corten-android-auth-transport:", 1)[0]
        self.assertIn('if [[ "$NATIVE_APS_FACTORY_ANALYSIS" == true ]]', job)
        self.assertIn("test_inspect_iphone_aps_factory.py", job)
        self.assertIn("inspect_iphone_aps_factory.py --out", job)
        self.assertIn("else", job)
        self.assertIn("test_inspect_iphone_activation_native.py", job)
        self.assertIn("inspect_iphone_activation_native.py --out", job)
        self.assertNotIn("id-token:", job)
        self.assertNotIn("secrets.", job)


if __name__ == "__main__":
    unittest.main()
