"""Offline contracts only. No engine, compiler, firmware, device or account."""
import copy
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import iphone_native_contract as S


class NativeContractTests(unittest.TestCase):
    def test_pinned_engine_and_child_command_never_execute_the_target(self):
        self.assertEqual(S.ENGINE_BYTES, 569649598)
        self.assertEqual(S.ENGINE_SHA256, "ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db")
        args = S.headless_command(Path("engine/support/analyzeHeadless"), Path("project"),
                                  Path("input"), Path("report.json"), Path("scripts"),
                                  Path("jdk"), Path("private-home"))
        self.assertEqual(args[0], "/usr/bin/env")
        self.assertIn("JAVA_HOME=jdk", args)
        self.assertEqual(args[args.index("-import") + 1], "input")
        self.assertEqual(args[args.index("-max-cpu") + 1], "2")
        self.assertEqual(args[args.index("-analysisTimeoutPerFile") + 1], "180")
        self.assertIn("-deleteProject", args)
        for flag in ("-run", "-process", "-connect", "-commit", "-overwrite"):
            self.assertNotIn(flag, args)

    def test_followup_command_admits_only_fixed_observed_owner_scope(self):
        common = (Path("engine/support/analyzeHeadless"), Path("project"), Path("input"),
                  Path("report.json"), Path("scripts"), Path("jdk"), Path("private-home"))
        args = S.headless_command(*common, scope="csr-key-owner")
        start = args.index("-postScript")
        self.assertEqual(args[start + 1:start + 4],
                         ["OBNativeActivationAnalysis.java", "report.json", "csr-key-owner"])
        self.assertEqual(args.count("csr-key-owner"), 1)
        with self.assertRaises(ValueError):
            S.headless_command(*common, scope="arbitrary-address")

    def test_owner_result_cannot_relabel_prior_seed_inspection_or_missing_code(self):
        value = {"analysis_scope": "csr-key-owner", "analysis_timeout_occurred": "false",
                 "decompiler_opened": True, "decompile_attempts": 2, "decompiled_count": 2,
                 "candidates": [{"entry": entry, "external": False, "thunk": False,
                                 "body_addresses": 4, "pseudocode": {"text": "return 1;"}}
                                for entry in ("0x1000056b4", "0x10005c4e4")]}
        self.assertEqual(S.require_owner_result(value)["status"], "observed-owner-callees-recovered")
        for mutation in ("scope", "entry", "code", "timeout"):
            changed = copy.deepcopy(value)
            if mutation == "scope": changed["analysis_scope"] = "seed-producers"
            if mutation == "entry": changed["candidates"][0]["entry"] = "0x10000718c"
            if mutation == "code": changed["candidates"][0]["pseudocode"] = None
            if mutation == "timeout": changed["analysis_timeout_occurred"] = "true"
            with self.subTest(mutation=mutation), self.assertRaises(RuntimeError):
                S.require_owner_result(changed)

    def test_mac_guard_requires_real_host_exact_opt_in_and_owned_work(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            work = root / "ob-iphone15-native-test"
            work.mkdir()
            good = {"RUNNER_TEMP": str(root), "GITHUB_ACTIONS": "true",
                    "NATIVE_CONTRACT_ANALYSIS": "true", "OUTBOUND_WRITER": "false",
                    "AUTOMATIC_UPLOADS": "false"}
            with patch.object(S.platform, "system", return_value="Darwin"), patch.dict(os.environ, good):
                S.require_owned_mac(work)
                with self.assertRaises(RuntimeError):
                    S.require_owned_mac(root)
                for name, value in (("NATIVE_CONTRACT_ANALYSIS", "1"), ("GITHUB_ACTIONS", "false"),
                                    ("AUTOMATIC_UPLOADS", "true"), ("OUTBOUND_WRITER", "true")):
                    with patch.dict(os.environ, {name: value}), self.assertRaises(RuntimeError):
                        S.require_owned_mac(work)
            with patch.object(S.platform, "system", return_value="Windows"), patch.dict(os.environ, good):
                with self.assertRaises(RuntimeError):
                    S.require_owned_mac(work)

    def test_wrong_native_is_refused_without_network_or_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            wrong = root / "mobileactivationd"
            wrong.write_bytes(b"not-the-native-input")
            with patch.object(S.urllib.request, "build_opener") as opener, self.assertRaises(RuntimeError):
                S.require_native(wrong, root)
            opener.assert_not_called()

    def test_redirects_reject_http_other_hosts_credentials_and_ports(self):
        handler = S.EngineRedirects()
        for url in ("http://github.com/a", "https://example.invalid/a", "https://u:p@github.com/a",
                    "https://github.com:8443/a"):
            with self.subTest(url=url), self.assertRaisesRegex(RuntimeError, "unexpected-engine-redirect"):
                handler.redirect_request(None, None, 302, "redirect", {}, url)

    @staticmethod
    def zip_member(name, *, mode=0o100644, size=1):
        info = zipfile.ZipInfo(name)
        # Windows ZipInfo construction normalizes backslashes. Preserve the
        # hostile carrier for the platform-independent manifest contract.
        info.filename = name
        info.external_attr = mode << 16
        info.file_size = size
        return info

    def test_zip_manifest_rejects_escape_symlink_duplicate_and_size_bomb(self):
        top = S.ENGINE_TOP
        cases = [[self.zip_member(name)] for name in (
            "../escape", top + "/../escape", "/absolute", "C:/absolute", top + "\\escape")]
        cases += [[self.zip_member(top + "/link", mode=0o120777)],
                  [self.zip_member(top + "/a"), self.zip_member(top + "/a")],
                  [self.zip_member(top + "/large", size=1024**3 + 1)]]
        for infos in cases:
            with self.subTest(names=[i.filename for i in infos]), self.assertRaises(RuntimeError):
                S.validate_zip(infos)
        self.assertEqual(S.validate_zip([self.zip_member(top + "/support/analyzeHeadless", size=17)]), 17)

    @staticmethod
    def analysis():
        return {"schema": 1, "tool": "ob-native-activation-headless", "analysis_timeout_occurred": "false",
                "candidates": [{"name": "fixture", "references": [], "calls": [],
                                "pseudocode": {"text": "return 1;", "chars": 9, "truncated": False}}],
                "decompiled_count": 1, "decompile_attempts": 1}

    def test_output_bounds_and_duplicate_keys_are_enforced(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            base = self.analysis()
            path.write_text(json.dumps(base), encoding="utf-8")
            self.assertEqual(S.read_analysis(path)["decompiled_count"], 1)
            for mutation in ("chars", "count", "references", "code-size", "schema", "attempts",
                             "diagnostic-size", "diagnostic-type", "open-type", "candidate-error"):
                value = copy.deepcopy(base)
                if mutation == "chars": value["candidates"][0]["pseudocode"]["chars"] = 8
                if mutation == "count": value["decompiled_count"] = True
                if mutation == "references": value["candidates"][0]["references"] = ["x"] * 9
                if mutation == "code-size": value["candidates"][0]["pseudocode"]["text"] = "x" * 20001
                if mutation == "schema": value["schema"] = True
                if mutation == "attempts": value["decompile_attempts"] = 9
                if mutation == "diagnostic-size": value["decompiler_message"] = "x" * 1025
                if mutation == "diagnostic-type": value["decompiler_message"] = []
                if mutation == "open-type": value["decompiler_opened"] = 1
                if mutation == "candidate-error": value["candidates"][0]["decompile_error"] = "x" * 1025
                path.write_text(json.dumps(value), encoding="utf-8")
                with self.subTest(mutation=mutation), self.assertRaises(RuntimeError):
                    S.read_analysis(path)
            path.write_text('{"schema":1,"schema":1}', encoding="utf-8")
            with self.assertRaises(ValueError):
                S.read_analysis(path)

    def test_backend_inventory_is_owned_bounded_and_never_runs_backend(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory).resolve()
            engine = work / "ghidra-engine" / S.ENGINE_TOP
            backend = engine / "Ghidra/Features/Decompiler/os/mac_arm_64/decompile"
            backend.parent.mkdir(parents=True)
            backend.write_bytes(b"static-fixture-not-executable")
            calls = []

            def owned(command, parent, name, timeout, **kwargs):
                self.assertEqual(parent, work)
                self.assertEqual(command, ["/usr/bin/file", "-b", str(backend)])
                self.assertEqual(timeout, 15)
                self.assertFalse(kwargs.get("check", True))
                calls.append(command)
                return 0, b"Mach-O 64-bit executable arm64\n", b""

            with patch.object(S.platform, "machine", return_value="arm64"):
                result = S.backend_inventory(engine, work, owned)
            self.assertEqual(result["host_machine"], "arm64")
            self.assertEqual(len(result["candidates"]), 2)
            available = [entry for entry in result["candidates"] if entry["exists"]]
            self.assertEqual(len(available), 1)
            self.assertEqual(available[0]["sha256"], S.digest(backend))
            self.assertEqual(available[0]["bytes"], backend.stat().st_size)
            self.assertEqual(available[0]["file_type"], "Mach-O 64-bit executable arm64")
            self.assertIs(type(available[0]["executable"]), bool)
            self.assertEqual(len(calls), 1)
            with self.assertRaisesRegex(RuntimeError, "owned-engine-root-required"):
                S.backend_inventory(work.parent, work, owned)
            self.assertEqual(len(calls), 1)

    def test_tool_diagnostic_retains_startup_error_even_before_success_tail(self):
        output = ("INFO loading\n" * 30 + "ERROR Decompiler Not Found: missing backend\n"
                  + "INFO script finished\n" * 30).encode()
        result = S.public_tool_diagnostic(output, b"")
        self.assertEqual(result, ["ERROR Decompiler Not Found: missing backend"])
        result = S.public_tool_diagnostic(("ERROR " + "x" * 2000 + "\n").encode() * 30, b"")
        self.assertEqual(len(result), 16)
        self.assertTrue(all(len(line) <= 240 for line in result))

    def test_missing_mac_backend_build_is_bounded_and_uses_only_pinned_source(self):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory).resolve()
            engine = work / "ghidra-engine" / S.ENGINE_TOP
            source = engine / "Ghidra/Features/Decompiler/src/decompile/cpp"
            source.mkdir(parents=True)
            (source / "Makefile").write_text("# pinned archive fixture")
            calls, progress = [], {}

            def owned(command, parent, name, timeout, **kwargs):
                self.assertEqual(parent, work)
                calls.append((command, name, timeout))
                if name == "ghidra-backend-build":
                    self.assertEqual(command[0], "/usr/bin/make")
                    self.assertIn("-j2", command)
                    self.assertIn("ghidra_opt", command)
                    self.assertIn("ARCH_TYPE=-arch arm64", command)
                    self.assertIn("CXX=/usr/bin/clang++ -std=c++11", command)
                    self.assertEqual(timeout, 480)
                    self.assertIn("-o", command)
                    self.assertIn("grammar.cc", command)
                    self.assertIn("xml.cc", command)
                    (source / "ghidra_opt").write_bytes(b"compiled-tool-fixture")
                if name == "ghidra-backend-architecture":
                    return 0, b"arm64\n", b""
                return 0, b"Mach-O 64-bit executable arm64\n", b""

            with patch.object(S, "require_owned_mac"), patch.object(S.platform, "machine", return_value="arm64"):
                result = S.prepare_backend(engine, work, owned, progress)
            target = engine / "Ghidra/Features/Decompiler/os/mac_arm_64/decompile"
            self.assertEqual(target.read_bytes(), b"compiled-tool-fixture")
            self.assertEqual(progress["backend_build"]["status"], "built-from-pinned-release-source")
            self.assertEqual(result["host_machine"], "arm64")
            self.assertEqual(sum(name == "ghidra-backend-build" for _, name, _ in calls), 1)
            self.assertFalse(any("install_ghidraopt" in command or "gradle" in str(command)
                                 for command, _, _ in calls))
            for command, _, _ in calls:
                self.assertNotEqual(command[0], str(target))
                self.assertNotEqual(command[0], str(source / "ghidra_opt"))

    def test_failed_backend_build_or_wrong_architecture_does_not_install_or_retry(self):
        for failure in ("build", "architecture"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                work = Path(directory).resolve()
                engine = work / "ghidra-engine" / S.ENGINE_TOP
                source = engine / "Ghidra/Features/Decompiler/src/decompile/cpp"
                source.mkdir(parents=True)
                (source / "Makefile").write_text("# pinned archive fixture")
                calls, progress = [], {}

                def owned(command, parent, name, timeout, **kwargs):
                    calls.append(name)
                    if name == "ghidra-backend-build":
                        if failure == "build": return 1, b"", b"ERROR bounded build failure"
                        (source / "ghidra_opt").write_bytes(b"compiled-tool-fixture")
                    if name == "ghidra-backend-architecture": return 0, b"x86_64", b""
                    return 0, b"", b""

                with patch.object(S, "require_owned_mac"), \
                        patch.object(S.platform, "machine", return_value="arm64"), \
                        self.assertRaises(RuntimeError):
                    S.prepare_backend(engine, work, owned, progress)
                self.assertEqual(calls.count("ghidra-backend-build"), 1)
                self.assertFalse((engine / "Ghidra/Features/Decompiler/os/mac_arm_64/decompile").exists())

    def test_fixture_failure_prevents_native_analysis_using_same_owned_runner(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source, work = root / "source", root / "work"
            for folder in (source / "ghidra_scripts", source / "fixtures", work):
                folder.mkdir(parents=True)
            (source / "ghidra_scripts/OBNativeActivationAnalysis.java").write_text("fixture")
            (source / "fixtures/native_activation_contract.c").write_text("fixture")
            jdk = root / "jdk"
            (jdk / "bin").mkdir(parents=True)
            (jdk / "bin/javac").write_bytes(b"fixture")
            engine = root / "engine"
            (engine / "support").mkdir(parents=True)
            (engine / "support/analyzeHeadless").write_bytes(b"fixture")
            calls = []

            def owned(command, parent, name, timeout, **kwargs):
                self.assertEqual(parent, work)
                calls.append(name)
                if name == "ghidra-java-home": return 0, str(jdk).encode(), b""
                if name == "ghidra-java-version": return 0, b"", b'openjdk version "21.0.6"'
                if name == "contract-fixture-compile":
                    (work / "native-activation-fixture").write_bytes(b"fixture")
                if name == "contract-fixture":
                    (work / "contract-fixture.json").write_text("{}")
                return 0, b"{}", b""

            progress = {}
            with patch.object(S, "SOURCE_DIR", source), patch.object(S, "require_owned_mac"), \
                    patch.object(S, "require_native"), patch.object(S, "extract_engine", return_value=(engine, 100)), \
                    patch.object(S, "prepare_backend", return_value={"host_machine": "fixture"}), \
                    patch.object(S.os, "access", return_value=True), patch.object(S, "read_analysis", return_value={}):
                with self.assertRaisesRegex(RuntimeError, "fixture-unqualified"):
                    S.inspect_contract(work / "mobileactivationd", work, owned,
                                       lambda _: (_ for _ in ()).throw(RuntimeError("fixture-unqualified")), progress)
            self.assertIn("contract-fixture", calls)
            self.assertNotIn("contract-native", calls)
            self.assertIn("backend_inventory", progress)
            self.assertIn("public_tool_diagnostic", progress)


if __name__ == "__main__":
    unittest.main()
