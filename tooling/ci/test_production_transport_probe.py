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
        guard = workflow.split('if [[ "$VALIDATION_MODE" == \'production-transport-only\' ]]; then', 1)[1].split('if [[ "$VALIDATION_MODE" == \'apk-runtime-only\' ]]; then', 1)[0]
        self.assertIn(PROBE.SOURCE, guard)
        self.assertIn('"$AUTOMATIC_UPLOADS" != \'false\'', guard)
        self.assertIn('"$OUTBOUND_WRITER" != \'false\'', guard)


if __name__ == "__main__":
    unittest.main()
