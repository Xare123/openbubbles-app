"""Stdlib-only safety tests for the iPhone activation native inspector."""

import hashlib
import os
import plistlib
from pathlib import Path
import struct
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

import inspect_iphone_activation_native as S


APPLE_IPSW_URL = (
    "https://updates.cdn-apple.com/2023WinterFCS/fullrestores/"
    "042-45465/C67B609C-7B93-4607-8C82-DCBED1045EA1/"
    "iPhone_4.7_P3_15.7.9_19H365_Restore.ipsw"
)


def macho64_arm64(payload=b"fixture"):
    header = struct.pack(
        "<IIIIIIII",
        0xFEEDFACF,
        0x0100000C,
        0,
        2,
        0,
        0,
        0,
        0,
    )
    return header + payload


class InspectIPhoneActivationNativeTests(unittest.TestCase):
    def test_annotated_instruction_command_has_no_runtime_llm_or_analysis_bypass(self):
        command = S.annotated_disassembly_command(Path("ipsw"), Path("native"), Path("owned.a2s"))
        self.assertEqual(command, ["ipsw", "macho", "disass", "--cache", "owned.a2s", "native"])
        for forbidden in ("--force", "--dec", "--dec-llm", "--quiet", "--json"):
            self.assertNotIn(forbidden, command)

    def test_annotated_instruction_selection_keeps_only_real_addressed_instruction_windows(self):
        raw = b'''sub_100001000:
0x100001000:  fd 7b bf a9   stp x29, x30, [sp, #-0x10]!
0x100001004:  08 00 00 90   adrp x8, #0x100212000
0x100001008:  00 00 00 91   add x0, x8, #0xd50 ; "DeviceCertRequest"
0x10000100c:  00 00 00 94   bl _objc_msgSend
arbitrary unaddressed data must not escape
'''
        result = S.select_activation_instruction_windows(raw)
        self.assertEqual(result["matching_instruction_count"], 1)
        self.assertEqual(result["windows"][0]["match_address"], "0x100001008")
        self.assertEqual(result["windows"][0]["target"], "DeviceCertRequest")
        self.assertEqual(len(result["windows"][0]["instructions"]), 4)
        self.assertNotIn("arbitrary unaddressed", str(result))
        self.assertFalse(result["external_csr_interface_proved"])
        self.assertFalse(result["runtime_or_caller_access_proved"])

    def test_annotated_instruction_targets_are_exact_and_protocol_metadata_does_not_match(self):
        raw = b'''name 0x100000000 issueClientCertificateLegacy:WithCompletionBlock:
0x100001000:  00000091   add x0, x8, #0 ; "DeviceCertRequestSuffix"
0x100001004:  00000091   add x0, x8, #0 ; "DeviceCertRequest"
'''
        result = S.select_activation_instruction_windows(raw)
        self.assertEqual(result["matching_instruction_count"], 1)
        self.assertEqual(result["windows"][0]["match_address"], "0x100001004")

    def test_annotated_instruction_selection_prioritizes_certificate_selector_and_caps_context(self):
        lines = [f'0x{0x100001000 + n * 4:x}:  00000091   add x0, x8, #0 ; "DeviceCertRequest"'
                 for n in range(80)]
        lines.append('0x100002000:  00000091   add x0, x8, #0 ; sel_issueClientCertificateLegacy:WithCompletionBlock:')
        result = S.select_activation_instruction_windows("\n".join(lines).encode())
        self.assertEqual(result["matching_instruction_count"], 81)
        self.assertEqual(len(result["windows"]), 24)
        self.assertTrue(result["truncated"])
        self.assertEqual(result["windows"][0]["target"], "issueClientCertificateLegacy:WithCompletionBlock:")
        self.assertLessEqual(max(len(window["instructions"]) for window in result["windows"]), 33)

    def test_annotated_instruction_parser_bounds_lines_and_drops_other_comments(self):
        raw = ('0x100001000:  00000091   add x0, x8, #0 ; "DeviceCertRequest"\n'
               '0x100001004:  00000091   add x0, x8, #0 ; "unselected-static-value"\n').encode()
        result = S.select_activation_instruction_windows(raw)
        self.assertNotIn("unselected-static-value", str(result))
        self.assertIn("[other-static-comment-omitted]", str(result))

    def test_annotated_instruction_parser_rejects_oversized_input_and_empty_is_unknown(self):
        with self.assertRaises(ValueError):
            S.select_activation_instruction_windows(b"x" * (32 * 1024**2 + 1))
        result = S.select_activation_instruction_windows(b"no addressed instructions")
        self.assertEqual(result["windows"], [])
        self.assertEqual(result["matching_instruction_count"], 0)
        self.assertFalse(result["external_csr_interface_proved"])

    def test_objc_command_is_metadata_only(self):
        self.assertEqual(S.objc_metadata_command(Path("native")),
                         ["/usr/bin/otool", "-ov", "native"])

    def test_objc_metadata_keeps_only_bounded_target_names_and_typed_fields(self):
        raw = b"""    name 0x1000 ActivationManager
    baseMethods 0x1100
        name 0x1200 createActivationInfoWithOptions:reply:
        types 0x1300 v32@0:8@16@?24
        imp 0x1400
        name 0x1500 unrelatedMethod:
        types 0x1600 v24@0:8@16
        imp 0x1700
arbitrary payload must not be retained
"""
        result = S.select_objc_activation_metadata(raw)
        self.assertEqual(result["matching_name_count"], 2)
        self.assertEqual(result["records"][0]["record_kind"], "named-metadata-only")
        method = result["records"][1]
        self.assertEqual(method["name"], "createActivationInfoWithOptions:reply:")
        self.assertEqual(method["type_encoding"], "v32@0:8@16@?24")
        self.assertEqual(method["implementation_address"], "0x1400")
        self.assertEqual(method["record_kind"], "typed-method-metadata")
        self.assertNotIn("unrelatedMethod", str(result))
        self.assertNotIn("arbitrary payload", str(result))
        self.assertFalse(result["external_csr_interface_proved"])

    def test_objc_metadata_does_not_attach_nested_or_next_method_fields(self):
        raw = b"""    name 0x1000 ActivationManager
        name 0x1200 ordinaryMethod
        types 0x1300 v16@0:8
        imp 0x1400
    name 0x1500 certificateName
    name 0x1600 unrelated
    types 0x1700 v16@0:8
    imp 0x1800
"""
        result = S.select_objc_activation_metadata(raw)
        self.assertEqual(len(result["records"]), 2)
        for record in result["records"]:
            self.assertIsNone(record["type_encoding"])
            self.assertIsNone(record["implementation_address"])

    def test_objc_metadata_caps_records_without_claiming_exhaustive_export(self):
        raw = b"\n".join(b"    name 0x1000 createActivationInfo" for _ in range(70))
        result = S.select_objc_activation_metadata(raw)
        self.assertEqual(result["matching_name_count"], 70)
        self.assertEqual(len(result["records"]), 64)
        self.assertTrue(result["truncated"])
        self.assertFalse(result["external_csr_interface_proved"])

    def test_activation_literals_require_exact_fixed_names_and_bounded_offsets(self):
        raw = b"""  10 DeviceCertRequest
  20 FairPlaySignature
  30 arbitrary-account-value
  40 DeviceCertRequestSuffix
fffffffffffffffff DeviceCertRequest
"""
        result = S.select_activation_literals(raw)
        self.assertEqual(result["records"], [
            {"file_offset_hex": "0x10", "name": "DeviceCertRequest"},
            {"file_offset_hex": "0x20", "name": "FairPlaySignature"}])
        self.assertFalse(result["external_csr_interface_proved"])

    def test_metadata_parsers_reject_oversized_input(self):
        raw = b"x" * (32 * 1024**2 + 1)
        for parser in (S.select_objc_activation_metadata, S.select_activation_literals):
            with self.subTest(parser=parser.__name__), self.assertRaises(ValueError):
                parser(raw)

    def test_command_failure_bounds_public_errors_and_removes_url_tokens(self):
        error = S.CommandFailure("extract-rootfs", 1,
                                 ("ignored\n" * 20 + "failed https://example.invalid/?token=secret\n"
                                  + "X" * 1000).encode())
        self.assertEqual(str(error), "extract-rootfs-exit-1")
        self.assertNotIn("token=secret", error.diagnostic)
        self.assertNotIn("X" * 60, error.diagnostic)
        self.assertLessEqual(len(error.diagnostic.splitlines()), 8)

    def test_select_archive_accepts_architecture_aliases(self):
        expected = {
            "arm64": "ipsw_3.1.739_macOS_arm64.tar.gz",
            "aarch64": "ipsw_3.1.739_macOS_arm64.tar.gz",
            "x86_64": "ipsw_3.1.739_macOS_x86_64.tar.gz",
            "amd64": "ipsw_3.1.739_macOS_x86_64.tar.gz",
        }
        for machine, filename in expected.items():
            selected, sha256 = S.select_archive(machine)
            self.assertEqual(selected, filename)
            self.assertRegex(sha256, r"^[0-9a-f]{64}$")

    def test_select_archive_rejects_unknown_machine(self):
        with self.assertRaises(ValueError):
            S.select_archive("riscv64")

    def test_extract_command_is_exact_remote_rootfs_selection(self):
        with tempfile.TemporaryDirectory() as directory:
            tool = Path(directory) / "ipsw"
            output = Path(directory) / "out"
            command = S.extract_command(tool, output)

        self.assertEqual(
            command,
            [
                str(tool),
                "extract",
                "--remote",
                "--dmg",
                "fs",
                "--flat",
                "--output",
                str(output),
                APPLE_IPSW_URL,
            ],
        )
        for forbidden in (
            "--files",
            "--dyld",
            "--insecure",
            "--lookup",
            "--pem-db",
            "--fcs-key",
        ):
            self.assertNotIn(forbidden, command)

    def test_readonly_attach_command_requires_explicit_safe_hdiutil_flags(self):
        command = S.readonly_attach_command(Path("root.dmg"), Path("mount"))
        self.assertEqual(
            command,
            [
                "/usr/bin/hdiutil",
                "attach",
                "-readonly",
                "-nobrowse",
                "-noautoopen",
                "-plist",
                "-mountpoint",
                "mount",
                "root.dmg",
            ],
        )
        for forbidden in ("-noverify", "-shadow"):
            self.assertNotIn(forbidden, command)

    def test_inspect_on_mac_rejects_before_filesystem_or_download(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "out"
            for system, github_actions in (("Linux", "true"), ("Darwin", "false")):
                with self.subTest(system=system, github_actions=github_actions):
                    with patch.object(S.platform, "system", return_value=system), patch.dict(
                        os.environ, {"GITHUB_ACTIONS": github_actions}, clear=False
                    ), patch.object(S, "validate_out_root") as validate, patch.object(
                        S, "download_tool"
                    ) as download:
                        with self.assertRaisesRegex(RuntimeError, "owned-github-macos-runner-required"):
                            S.inspect_on_mac(output)
                    validate.assert_not_called()
                    download.assert_not_called()

    def test_stop_owned_only_signals_registered_unreaped_processes(self):
        original = list(S.OWNED_PROCESSES)
        try:
            unregistered = SimpleNamespace(pid=123456, returncode=None, poll=Mock())
            registered = SimpleNamespace(pid=123457, returncode=0, _ob_group_reaped=True)
            S.OWNED_PROCESSES[:] = []
            with patch.object(S.os, "getpgrp", return_value=123455, create=True), patch.object(
                S.os, "killpg", create=True
            ) as killpg:
                self.assertFalse(S.stop_owned(unregistered))
                killpg.assert_not_called()

                S.OWNED_PROCESSES.append(registered)
                self.assertTrue(S.stop_owned(registered))
                killpg.assert_not_called()
        finally:
            S.OWNED_PROCESSES[:] = original

    def test_validate_out_root_accepts_new_absolute_descendant(self):
        with tempfile.TemporaryDirectory() as directory:
            runner_temp = Path(directory).resolve()
            candidate = runner_temp / "job" / "out"
            result = S.validate_out_root(candidate, runner_temp)
            self.assertIsInstance(result, Path)
            self.assertEqual(result, candidate)
            self.assertFalse(candidate.exists())

    def test_validate_out_root_rejects_relative_root_itself_and_existing(self):
        with tempfile.TemporaryDirectory() as directory:
            runner_temp = Path(directory).resolve()
            cases = (
                Path("relative/out"),
                runner_temp,
                runner_temp / "existing",
            )
            (runner_temp / "existing").mkdir()
            for candidate in cases:
                with self.subTest(candidate=candidate):
                    with self.assertRaises((ValueError, FileExistsError)):
                        S.validate_out_root(candidate, runner_temp)

    def test_validate_out_root_rejects_symlink_escaping_runner_temp(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            runner_temp = Path(directory).resolve()
            link = runner_temp / "escape"
            try:
                link.symlink_to(Path(outside).resolve(), target_is_directory=True)
            except OSError as error:
                self.skipTest(f"symlink creation unavailable: {error}")
            with self.assertRaises(ValueError):
                S.validate_out_root(link / "out", runner_temp)

    def test_owned_images_keeps_only_dev_entries_for_images_inside_work(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as outside:
            work = Path(directory).resolve()
            inside = work / "root.dmg"
            inside.write_bytes(b"image")
            outside_image = Path(outside).resolve() / "other.dmg"
            outside_image.write_bytes(b"other")
            raw = plistlib.dumps(
                {
                    "images": [
                        {
                            "image-path": str(inside),
                            "system-entities": [
                                {"dev-entry": "/dev/disk9"},
                                {"dev-entry": "/dev/disk9s1"},
                            ],
                        },
                        {
                            "image-path": str(outside_image),
                            "system-entities": [{"dev-entry": "/dev/disk99"}],
                        },
                    ]
                }
            )
            self.assertEqual(
                S.owned_images(raw, work),
                ["/dev/disk9", "/dev/disk9s1"],
            )

    def test_owned_images_ignores_missing_or_malformed_entities(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory).resolve()
            image = work / "root.dmg"
            image.write_bytes(b"image")
            raw = plistlib.dumps(
                {
                    "images": [
                        {"image-path": str(image), "system-entities": [{}]},
                        {"image-path": str(image), "system-entities": [{"other": "value"}]},
                    ]
                }
            )
            self.assertEqual(S.owned_images(raw, work), [])

    def test_inspect_macho_reports_only_native_arm64_macho_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mobileactivationd"
            data = macho64_arm64(b"static fixture")
            path.write_bytes(data)
            result = S.inspect_macho(path)
            self.assertEqual(result["bytes"], len(data))
            self.assertEqual(result["sha256"], hashlib.sha256(data).hexdigest())

    def test_inspect_macho_rejects_invalid_wrong_cpu_and_non_64_bit_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cases = {
                "invalid": b"not-mach-o",
                "wrong-cpu": struct.pack("<IIIIIIII", 0xFEEDFACF, 0x01000007, 0, 2, 0, 0, 0, 0),
                "32-bit": struct.pack("<IIIIIII", 0xFEEDFACE, 0x0100000C, 0, 2, 0, 0, 0),
            }
            for name, data in cases.items():
                path = root / name
                path.write_bytes(data)
                with self.subTest(name=name):
                    with self.assertRaises(ValueError):
                        S.inspect_macho(path)

    def test_inspect_macho_rejects_symlink_and_nonregular_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target"
            target.write_bytes(macho64_arm64())
            link = root / "link"
            try:
                link.symlink_to(target)
            except OSError as error:
                self.skipTest(f"symlink creation unavailable: {error}")
            with self.assertRaises(ValueError):
                S.inspect_macho(link)
            with self.assertRaises(ValueError):
                S.inspect_macho(root)


if __name__ == "__main__":
    unittest.main()
