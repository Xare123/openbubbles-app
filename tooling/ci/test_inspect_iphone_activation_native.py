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
