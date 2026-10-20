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
            for mutation in ("chars", "count", "references", "code-size", "schema", "attempts"):
                value = copy.deepcopy(base)
                if mutation == "chars": value["candidates"][0]["pseudocode"]["chars"] = 8
                if mutation == "count": value["decompiled_count"] = True
                if mutation == "references": value["candidates"][0]["references"] = ["x"] * 9
                if mutation == "code-size": value["candidates"][0]["pseudocode"]["text"] = "x" * 20001
                if mutation == "schema": value["schema"] = True
                if mutation == "attempts": value["decompile_attempts"] = 9
                path.write_text(json.dumps(value), encoding="utf-8")
                with self.subTest(mutation=mutation), self.assertRaises(RuntimeError):
                    S.read_analysis(path)
            path.write_text('{"schema":1,"schema":1}', encoding="utf-8")
            with self.assertRaises(ValueError):
                S.read_analysis(path)

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

            with patch.object(S, "SOURCE_DIR", source), patch.object(S, "require_owned_mac"), \
                    patch.object(S, "require_native"), patch.object(S, "extract_engine", return_value=(engine, 100)), \
                    patch.object(S.os, "access", return_value=True), patch.object(S, "read_analysis", return_value={}):
                with self.assertRaisesRegex(RuntimeError, "fixture-unqualified"):
                    S.inspect_contract(work / "mobileactivationd", work, owned,
                                       lambda _: (_ for _ in ()).throw(RuntimeError("fixture-unqualified")), {})
            self.assertIn("contract-fixture", calls)
            self.assertNotIn("contract-native", calls)


if __name__ == "__main__":
    unittest.main()
