"""Optional exact-input static analysis inside the existing owned Mac inspector.

No target execution, account/device access or independent process lifecycle.
The caller owns every child process, mounted image and temporary file.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ENGINE_URL = ("https://github.com/NationalSecurityAgency/ghidra/releases/download/"
              "Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip")
ENGINE_BYTES = 569649598
ENGINE_SHA256 = "ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db"
ENGINE_TOP = "ghidra_12.1.4_PUBLIC"
NATIVE_SHA256 = "54650d966b1dd0f7295b5e41f219d86c9007260ebaacd925a95e933ddb882028"
NATIVE_BYTES = 2398096
MAX_OUTPUT_BYTES = 2 * 1024**2
SOURCE_DIR = Path(__file__).resolve().parent
REDIRECT_HOSTS = frozenset({"github.com", "release-assets.githubusercontent.com",
                            "objects.githubusercontent.com"})


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def require_owned_mac(work):
    if (platform.system() != "Darwin" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("NATIVE_CONTRACT_ANALYSIS") != "true"
            or any(os.environ.get(name, "false") != "false"
                   for name in ("OUTBOUND_WRITER", "AUTOMATIC_UPLOADS"))):
        raise RuntimeError("owned-mac-contract-opt-in-required")
    root = Path(os.environ["RUNNER_TEMP"]).resolve()
    if (not work.is_absolute() or work.is_symlink() or not work.is_dir()
            or root not in work.resolve().parents
            or not work.name.startswith("ob-iphone15-native-")):
        raise RuntimeError("owned-native-work-required")


def require_native(path, work):
    if (path.parent.resolve() != work.resolve() or path.is_symlink() or not path.is_file()
            or path.stat().st_size != NATIVE_BYTES or digest(path) != NATIVE_SHA256):
        raise RuntimeError("exact-native-contract-input-required")


class EngineRedirects(urllib.request.HTTPRedirectHandler):
    max_redirections = 5
    max_repeats = 2

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        target = urllib.parse.urlparse(newurl)
        if (target.scheme != "https" or target.hostname not in REDIRECT_HOSTS
                or target.username or target.password or target.port not in (None, 443)):
            raise RuntimeError("unexpected-engine-redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download_engine(path):
    """Also bounded by the caller's owned 180-second process deadline."""
    value, count = hashlib.sha256(), 0
    deadline = time.monotonic() + 120
    opener = urllib.request.build_opener(EngineRedirects())
    with opener.open(ENGINE_URL, timeout=20) as response, path.open("xb") as output:
        if response.status != 200:
            raise RuntimeError("engine-http-status")
        length = response.headers.get("Content-Length")
        if length is not None and length != str(ENGINE_BYTES):
            raise RuntimeError("engine-size-mismatch")
        while True:
            if time.monotonic() >= deadline:
                raise RuntimeError("engine-download-deadline")
            block = response.read(1024 * 1024)
            if not block:
                break
            count += len(block)
            if count > ENGINE_BYTES:
                raise RuntimeError("engine-size-mismatch")
            value.update(block)
            output.write(block)
    if count != ENGINE_BYTES or value.hexdigest() != ENGINE_SHA256:
        raise RuntimeError("engine-checksum-mismatch")


def validate_zip(infos):
    if not 0 < len(infos) <= 200000:
        raise RuntimeError("bounded-engine-zip-required")
    total, seen = 0, set()
    for entry in infos:
        name = entry.filename
        parts = PurePosixPath(name).parts
        if (not parts or parts[0] != ENGINE_TOP or ".." in parts or "\\" in name
                or name.startswith("/") or re.match(r"^[A-Za-z]:", name)
                or stat.S_IFMT(entry.external_attr >> 16) not in (0, stat.S_IFDIR, stat.S_IFREG)
                or entry.flag_bits & 1 or not 0 <= entry.file_size <= 1024**3):
            raise RuntimeError("unsafe-engine-zip-member")
        canonical = "/".join(parts)
        if canonical in seen:
            raise RuntimeError("duplicate-engine-zip-member")
        seen.add(canonical)
        total += entry.file_size
        if total > 6 * 1024**3:
            raise RuntimeError("engine-expanded-size-limit")
    return total


def extract_engine(archive, destination):
    if archive.stat().st_size != ENGINE_BYTES or digest(archive) != ENGINE_SHA256:
        raise RuntimeError("engine-checksum-mismatch")
    with zipfile.ZipFile(archive) as package:
        infos = package.infolist()
        expanded = validate_zip(infos)
        if shutil.disk_usage(destination.parent).free < expanded + 1024**3:
            raise RuntimeError("engine-expanded-disk-unavailable")
        destination.mkdir(mode=0o700)
        root = destination.resolve()
        for entry in infos:
            target = root.joinpath(*PurePosixPath(entry.filename).parts)
            if root not in target.resolve().parents:
                raise RuntimeError("engine-member-outside-owned-root")
            if entry.is_dir():
                target.mkdir(parents=True, exist_ok=True, mode=0o700)
                continue
            target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            count = 0
            with package.open(entry) as source, target.open("xb") as output:
                while block := source.read(1024 * 1024):
                    count += len(block)
                    if count > entry.file_size:
                        raise RuntimeError("engine-member-size-mismatch")
                    output.write(block)
            if count != entry.file_size:
                raise RuntimeError("engine-member-size-mismatch")
            target.chmod(0o700 if (entry.external_attr >> 16) & 0o111 else 0o600)
    return destination / ENGINE_TOP, expanded


def reject_duplicate_json(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate-json-key")
        result[key] = value
    return result


def bounded_diagnostic(value):
    return value is None or (type(value) is str and len(value.encode("utf-16-le")) // 2 <= 1024)


def read_analysis(path):
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= MAX_OUTPUT_BYTES:
        raise RuntimeError("bounded-headless-result-required")
    value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_json)
    if type(value) is not dict:
        raise RuntimeError("headless-result-schema-invalid")
    candidates = value.get("candidates")
    if (type(value.get("schema")) is not int or value.get("schema") != 1
            or value.get("tool") != "ob-native-activation-headless"
            or type(candidates) is not list or len(candidates) > 64
            or value.get("analysis_timeout_occurred") not in ("false", "true", "unknown")):
        raise RuntimeError("headless-result-schema-invalid")
    if (not bounded_diagnostic(value.get("decompiler_message"))
            or ("decompiler_opened" in value and type(value["decompiler_opened"]) is not bool)):
        raise RuntimeError("headless-diagnostic-bounds-invalid")
    count = 0
    for candidate in candidates:
        if (len(candidate.get("references", [])) > 8 or len(candidate.get("calls") or []) > 64
                or len(candidate.get("name", "")) > 500
                or not bounded_diagnostic(candidate.get("decompile_error"))):
            raise RuntimeError("headless-result-bounds-invalid")
        code = candidate.get("pseudocode")
        if code is not None:
            if (type(code) is not dict or type(code.get("text")) is not str
                    or not 0 < len(code["text"].encode("utf-16-le")) // 2 <= 20000
                    or code.get("chars") != len(code["text"].encode("utf-16-le")) // 2):
                raise RuntimeError("headless-pseudocode-bounds-invalid")
            count += 1
    if count > 8 or type(value.get("decompiled_count")) is not int or value.get("decompiled_count") != count:
        raise RuntimeError("headless-decompilation-count-invalid")
    attempts = value.get("decompile_attempts")
    if type(attempts) is not int or not count <= attempts <= 8:
        raise RuntimeError("headless-decompilation-attempts-invalid")
    return value


def backend_inventory(engine, work, run_owned):
    """Inspect only pinned engine files. Never execute a backend or target."""
    if (engine.is_symlink() or not engine.is_dir()
            or work.resolve() not in engine.resolve().parents):
        raise RuntimeError("owned-engine-root-required")
    result = {"host_machine": platform.machine(), "candidates": []}
    for arch in ("mac_arm_64", "mac_x86_64"):
        relative = "Ghidra/Features/Decompiler/os/" + arch + "/decompile"
        path = engine / relative
        entry = {"path": relative, "exists": path.exists()}
        result["candidates"].append(entry)
        if not path.exists():
            continue
        info = path.lstat()
        if (path.is_symlink() or not stat.S_ISREG(info.st_mode)
                or engine.resolve() not in path.resolve().parents
                or not 0 < info.st_size <= 128 * 1024**2):
            raise RuntimeError("bounded-owned-backend-required")
        entry.update({"bytes": info.st_size, "sha256": digest(path),
                      "mode": oct(stat.S_IMODE(info.st_mode)),
                      "executable": os.access(path, os.X_OK)})
        code, output, _ = run_owned(["/usr/bin/file", "-b", str(path)], work,
                                    "ghidra-backend-" + arch, 15, check=False)
        entry.update({"file_exit": code, "file_type": output.decode(errors="replace").strip()[:240]})
    return result


def public_tool_diagnostic(stdout, stderr):
    """Keep a small failure-relevant excerpt, not entire engine logs."""
    lines = (stdout + b"\n" + stderr).decode(errors="replace").splitlines()
    critical = [line for line in lines if re.search(
        r"\b(?:ERROR|Exception|dyld)\b|Permission denied|Could not find|Unable to start", line, re.I)]
    relevant = critical or [line for line in lines if "decompil" in line.lower()] or lines[-8:]
    return [line[:240] for line in relevant[-16:]]


def headless_command(launcher, project, binary, output, script_dir, java_home, private_home):
    return ["/usr/bin/env", "JAVA_HOME=" + str(java_home),
            "JAVA_TOOL_OPTIONS=-Duser.home=" + str(private_home),
            str(launcher), str(project), output.stem, "-import", str(binary),
            "-scriptPath", str(script_dir), "-postScript", "OBNativeActivationAnalysis.java", str(output),
            "-max-cpu", "2", "-analysisTimeoutPerFile", "180", "-deleteProject"]


def inspect_contract(native, work, run_owned, qualify_fixture, progress):
    require_owned_mac(work)
    require_native(native, work)
    scripts = SOURCE_DIR / "ghidra_scripts"
    fixture_source = SOURCE_DIR / "fixtures/native_activation_contract.c"
    if not (scripts / "OBNativeActivationAnalysis.java").is_file() or not fixture_source.is_file():
        raise RuntimeError("contract-source-fixtures-required")
    progress.update({"status": "preparing", "engine_version": "12.1.4", "engine_sha256": ENGINE_SHA256,
                     "native_sha256": NATIVE_SHA256, "target_executed": False, "accounts": 0,
                     "activation_requests": 0, "runtime_or_accepted_csr_proved": False})
    _, java_path, _ = run_owned(["/usr/libexec/java_home", "-v", "21"], work, "ghidra-java-home", 15)
    java_home = Path(java_path.decode().strip())
    if not java_home.is_absolute() or not (java_home / "bin/javac").is_file():
        raise RuntimeError("installed-jdk-21-required")
    _, _, java_version = run_owned([str(java_home / "bin/java"), "-version"], work, "ghidra-java-version", 15)
    if not re.search(r'version "21(?:[.\"]|$)', java_version.decode(errors="replace")):
        raise RuntimeError("installed-jdk-21-required")
    archive = work / "ghidra.zip"
    progress["status"] = "engine-download"
    code, fetch_output, _ = run_owned(
        [sys.executable, str(Path(__file__).resolve()), "--fetch-engine", str(archive)],
        work, "ghidra-engine-download", 180, check=False)
    if code != 0:
        if len(fetch_output) < 4096:
            progress["download_result"] = json.loads(fetch_output)
        raise RuntimeError("pinned-engine-download-failed")
    engine, expanded = extract_engine(archive, work / "ghidra-engine")
    progress["engine_expanded_bytes"] = expanded
    progress["backend_inventory"] = backend_inventory(engine, work, run_owned)
    launcher = engine / "support/analyzeHeadless"
    if not launcher.is_file() or not os.access(launcher, os.X_OK):
        raise RuntimeError("headless-launcher-unavailable")
    private_home, project = work / "ghidra-home", work / "ghidra-projects"
    private_home.mkdir(mode=0o700)
    project.mkdir(mode=0o700)
    fixture = work / "native-activation-fixture"
    run_owned(["/usr/bin/clang", "-arch", "arm64", "-O0", "-fno-builtin", "-framework", "CoreFoundation",
               str(fixture_source), "-o", str(fixture)], work, "contract-fixture-compile", 60)
    progress["fixture_input_sha256"] = digest(fixture)
    for kind, binary in (("fixture", fixture), ("native", native)):
        progress["status"] = kind + "-analysis"
        output = work / ("contract-" + kind + ".json")
        code, stdout, stderr = run_owned(headless_command(
            launcher, project, binary, output, scripts, java_home, private_home),
            work, "contract-" + kind, 300, check=False)
        progress["public_tool_diagnostic"] = public_tool_diagnostic(stdout, stderr)
        if code != 0 or not output.is_file():
            raise RuntimeError("headless-" + kind + "-failed")
        result = read_analysis(output)
        if kind == "fixture":
            progress["fixture_result"] = result
            progress["fixture_qualification"] = qualify_fixture(result)
        else:
            progress["native_result"] = result
    require_native(native, work)
    progress["status"] = "static-contract-analysis-completed"


def fetch_child(path):
    require_owned_mac(path.parent)
    require_native(path.parent / "mobileactivationd", path.parent)
    if path.name != "ghidra.zip" or path.exists() or path.is_symlink():
        raise RuntimeError("fresh-owned-engine-archive-required")
    if shutil.disk_usage(path.parent).free < ENGINE_BYTES + 1024**3:
        raise RuntimeError("engine-download-disk-unavailable")
    download_engine(path)
    return {"status": "pinned-engine-downloaded", "bytes": ENGINE_BYTES, "sha256": ENGINE_SHA256}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--fetch-engine", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(fetch_child(args.fetch_engine)))
    except Exception as error:
        reason = ("engine-http-" + str(error.code) if isinstance(error, urllib.error.HTTPError)
                  else str(error) if isinstance(error, RuntimeError) and re.fullmatch(r"[a-z0-9-]+", str(error))
                  else type(error).__name__)
        print(json.dumps({"status": "engine-download-failed", "reason": reason}))
        raise SystemExit(1)
