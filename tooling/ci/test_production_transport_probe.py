"""No network/compiler/device/account tests. Exercise the diagnostic safety seams."""
import importlib.util
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import Mock

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("transport_probe", HERE / "run_production_transport_probe.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class TransportProbeSafety(unittest.TestCase):
    def fixture(self, root):
        for relative in (
            "rustpush/src/lib.rs", "rustpush/apple-private-apis/icloud-auth/src/lib.rs",
            "rustpush/apple-private-apis/icloud-auth/src/client.rs",
        ):
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"// original\r\n")
        return {path: path.read_bytes() for path in root.rglob("*.rs")}

    def test_overlay_restores_success_byte_exactly(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            originals = self.fixture(root)
            with PROBE.overlay(root):
                self.assertTrue((root / PROBE.BIN).exists())
            self.assertFalse((root / PROBE.BIN).exists())
            self.assertEqual(originals, {path: path.read_bytes() for path in originals})

    def test_overlay_restores_exception_byte_exactly(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            originals = self.fixture(root)
            with self.assertRaisesRegex(RuntimeError, "simulated"):
                with PROBE.overlay(root):
                    raise RuntimeError("simulated compiler failure")
            self.assertFalse((root / PROBE.BIN).exists())
            self.assertEqual(originals, {path: path.read_bytes() for path in originals})

    def test_existing_source_is_not_overwritten(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.fixture(root)
            file = root / PROBE.BIN
            file.parent.mkdir(parents=True)
            file.write_bytes(b"user-owned")
            with self.assertRaisesRegex(RuntimeError, "existing"):
                with PROBE.overlay(root):
                    pass
            self.assertEqual(file.read_bytes(), b"user-owned")

    def test_wrong_commit_rejected_before_overlay(self):
        with patch.object(PROBE, "git", return_value="0" * 40):
            with self.assertRaisesRegex(RuntimeError, "reviewed"):
                PROBE.verify_source(Path("unused"))

    def test_dirty_source_rejected_before_overlay(self):
        with patch.object(PROBE, "git", side_effect=[PROBE.SOURCE, " M rust/Cargo.lock", PROBE.SOURCE]):
            with self.assertRaisesRegex(RuntimeError, "dirty"):
                PROBE.verify_source(Path("unused"))

    def test_fingerprint_lengths_and_explicit_certs(self):
        self.assertEqual(len(PROBE.PINS), 6)
        self.assertTrue(all(len(value) == 64 for value in PROBE.HASHES.values()))
        self.assertIn("rustpush/src/util.rs", PROBE.HASHES)
        self.assertIn("rustpush/apple-private-apis/icloud-auth/src/apple_root.der", PROBE.HASHES)

    def log(self, directory, calls=0, hosts=None):
        rows = [{"original_host": host} for host in (hosts or ["www.google.com", "init.ess.apple.com", "gsa.apple.com"])]
        rows.append({"anisette_provider_calls": calls, "credentials_loaded": False})
        file = Path(directory) / "run.log"
        file.write_text("\n".join(json.dumps(row) for row in rows))
        return file

    def test_exact_public_observation_count(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertEqual(len(PROBE.observations(self.log(directory))), 4)

    def test_provider_invocation_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "Anisette"):
                PROBE.observations(self.log(directory, calls=1))

    def test_unexpected_host_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "host"):
                PROBE.observations(self.log(directory, hosts=["example.com", "init.ess.apple.com", "gsa.apple.com"]))

    def test_arm64_elf_and_wrong_abi(self):
        with tempfile.TemporaryDirectory() as directory:
            file = Path(directory) / "probe"
            header = bytearray(20)
            header[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", header, 18, 183)
            file.write_bytes(header)
            self.assertEqual(PROBE.elf(file, 183)["elf_machine"], 183)
            with self.assertRaisesRegex(RuntimeError, "ABI"):
                PROBE.elf(file, 62)

    def test_no_tls_override_or_dynamic_url(self):
        source = (HERE / "transport_probe/main.rs").read_text()
        self.assertEqual(source.count("https://"), 3)
        self.assertIn("args_os().len() != 1", source)
        self.assertNotIn("danger_accept", source)
        self.assertNotIn(".post(", source)
        self.assertNotIn(".body(", source)

    def test_interrupted_command_reaps_owned_process(self):
        child = Mock(pid=123)
        child.wait.side_effect = [RuntimeError("simulated interruption"), -15]
        child.poll.return_value = None
        def fake_kill(_pid, sig):
            if sig == 0:
                raise ProcessLookupError()
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(PROBE.subprocess, "Popen", return_value=child):
                with patch.object(PROBE.os, "killpg", side_effect=fake_kill, create=True) as kill:
                    with self.assertRaisesRegex(RuntimeError, "interruption"):
                        PROBE.command(["unused"], Path(directory), Path(directory), "interrupted", 1)
            self.assertTrue(kill.called)
            receipt = json.loads((Path(directory) / "interrupted.json").read_text())
            self.assertTrue(receipt["process_group_reaped"])

    def test_transport_mode_excludes_app_build_and_signing(self):
        workflow = (HERE.parents[1] / ".github/workflows/gce-runner-pilot.yml").read_text()
        build = workflow.split("  benchmark-build:\n", 1)[1].split("  production-transport:\n", 1)[0]
        condition = next(line for line in build.splitlines() if line.strip().startswith("if:"))
        self.assertIn("!= 'production-transport-only'", condition)
        self.assertIn("!= 'production-android-build-only'", condition)
        job = workflow.split("  production-transport:\n", 1)[1].split("  apk-runtime:\n", 1)[0]
        self.assertIn("timeout-minutes: 40", job)
        self.assertNotIn("secrets.", job)
        self.assertNotIn("flutter ", job)
        self.assertNotIn("gradle", job)

    def test_transport_mode_waits_for_cleanup_and_pins_source(self):
        workflow = (HERE.parents[1] / ".github/workflows/gce-runner-pilot.yml").read_text()
        cleanup = workflow.split("  delete-runner:\n", 1)[1]
        self.assertIn("      - production-transport\n", cleanup)
        self.assertIn("always()", cleanup)
        self.assertIn("--max-run-duration 75m", workflow)
        guard = workflow.split('if [[ "$VALIDATION_MODE" == \'production-transport-only\' || "$VALIDATION_MODE" == \'production-android-build-only\' ]]; then', 1)[1].split('if [[ "$VALIDATION_MODE" == \'apk-runtime-only\' ]]; then', 1)[0]
        self.assertIn(PROBE.SOURCE, guard)
        self.assertIn('"$AUTOMATIC_UPLOADS" != \'false\'', guard)
        self.assertIn('"$OUTBOUND_WRITER" != \'false\'', guard)

    def test_android_ranlib_override_is_explicit(self):
        workflow = (HERE.parents[1] / ".github/workflows/gce-runner-pilot.yml").read_text()
        job = workflow.split("  production-transport:\n", 1)[1].split("  apk-runtime:\n", 1)[0]
        self.assertTrue(
            'export RANLIB_aarch64_linux_android="$ndk/llvm-ranlib"' in job,
            "Production probe does not select the NDK llvm-ranlib",
        )

    def test_build_only_does_not_build_or_execute_linux(self):
        receipt = {"android_executed": False}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            with patch.object(PROBE, "command", side_effect=AssertionError("unexpected host command")) as host:
                with patch.object(PROBE, "build_android_probe", return_value={"android_interpreter": "/system/bin/linker64"}) as android:
                    self.assertEqual(PROBE.run_platforms(path, path, path, ["cargo"], receipt, android_only=True), 0)
            host.assert_not_called()
            android.assert_called_once()
        self.assertFalse(receipt["linux_probe_executed"])
        self.assertNotIn("linux_transport_passed", receipt)
        self.assertFalse(receipt["android_executed"])
        self.assertEqual(receipt["result"], "android_artifact_ready_transport_unrun")

    def test_full_probe_failed_google_control_stops_android(self):
        receipt = {}
        rows = [{"strict_https": False, "http_status": 0}] * 3 + [{"anisette_provider_calls": 0}]
        success = {"exit_code": 0, "process_group_reaped": True}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            with patch.object(PROBE, "command", return_value=success) as commands:
                with patch.object(PROBE, "elf", return_value={}), patch.object(PROBE, "observations", return_value=rows):
                    with patch.object(PROBE, "build_android_probe") as android:
                        with self.assertRaisesRegex(RuntimeError, "Google control"):
                            PROBE.run_platforms(path, path, path, ["cargo"], receipt)
            android.assert_not_called()
            self.assertEqual([call.args[3] for call in commands.call_args_list], ["linux-build", "linux-probe"])

    def test_full_probe_keeps_actual_host_observations(self):
        receipt = {"android_executed": False}
        rows = [{"strict_https": True, "http_status": code} for code in (200, 200, 404)] + [{"anisette_provider_calls": 0}]
        success = {"exit_code": 0, "process_group_reaped": True}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            with patch.object(PROBE, "command", return_value=success), patch.object(PROBE, "elf", return_value={}):
                with patch.object(PROBE, "observations", return_value=rows):
                    with patch.object(PROBE, "build_android_probe", return_value={}) as android:
                        self.assertEqual(PROBE.run_platforms(path, path, path, ["cargo"], receipt), 0)
            android.assert_called_once()
        self.assertTrue(receipt["linux_probe_executed"])
        self.assertTrue(receipt["linux_transport_passed"])
        self.assertEqual(receipt["result"], "probe_and_artifact_ready")

    def test_android_phase_selects_only_exact_target(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            with patch.object(PROBE, "command", side_effect=RuntimeError("compiler sentinel")) as commands:
                with self.assertRaisesRegex(RuntimeError, "compiler sentinel"):
                    PROBE.build_android_probe(path, path, path, ["cargo", "build", "--locked"])
            self.assertEqual(commands.call_args.args[0], ["cargo", "build", "--locked", "--target", PROBE.TARGET])
            self.assertEqual(commands.call_args.args[3], "android-build")

    def test_build_only_cli_is_only_admitted_in_native_job(self):
        workflow = (HERE.parents[1] / ".github/workflows/gce-runner-pilot.yml").read_text()
        job = workflow.split("  production-transport:\n", 1)[1].split("  apk-runtime:\n", 1)[0]
        self.assertIn("inputs.validation_mode == 'production-android-build-only'", job)
        self.assertIn("probe_args+=(--android-only)", job)
        self.assertIn('test -x "$RANLIB_aarch64_linux_android"', job)
        self.assertNotIn(".post(", (HERE / "transport_probe/main.rs").read_text())


if __name__ == "__main__":
    unittest.main()
