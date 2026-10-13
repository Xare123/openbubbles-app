"""Bounded Corten component qualification. No app, account or message actions."""
import argparse
import base64
import difflib
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tarfile
import time
import tomllib
import urllib.error
import urllib.request

SOURCE = "ad05e2136a9f722aab74d3381a65483e49f5d1dc"
NATIVE = "5076fe684b8856886c295e99b623757d9cf6b754"
TRANSFER_SHA256 = "44d56a8f46dbb883ba00d81171fe11d605d5abc246f3ee9dd8c34949101882fa"
FRAMEWORK_SHA256 = "74c2a8fe826a478f14f6e17b3709a8b315e8c0e0e34e3fba6b9c4eee2f4516e9"
FRAMEWORK_URL = "https://raw.githubusercontent.com/JJTech0130/nacserver/0a2aa2406542fb09c14a37db17ff14865b8aea29/IMDAppleServices"
METADATA_KEY = "ob-corten-hardware"
OWNED_GROUPS = set()
UNICORN_CHECKSUM = "827118d4fdedff61086fe435c6bd84f9f7e2f189a7d0fdcffdb788b23cea10d8"


def patch_android_thread_directives(text):
    old = 'println!("cargo:rustc-link-lib=pthread");'
    if text.count(old) != 2:
        raise RuntimeError("unexpected pinned Unicorn thread directives")
    new = 'if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("android") { println!("cargo:rustc-link-lib=pthread"); }'
    return text.replace(old, new)


def capture_json(args, source, env):
    process = subprocess.Popen(args, cwd=source, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, start_new_session=True)
    OWNED_GROUPS.add(process.pid)
    try:
        output, _ = process.communicate(timeout=60)
    except subprocess.TimeoutExpired:
        reap(process)
        raise RuntimeError("bounded Cargo metadata timed out")
    reap(process)
    if process.returncode or len(output) > 2 * 1024 * 1024:
        raise RuntimeError("Cargo metadata failed before dependency admission")
    return json.loads(output)


def prepare_android_dependency(prototype, temporary, source, env, out):
    manifest = str(prototype / "Cargo.toml")
    original_lock = (prototype / "Cargo.lock").read_bytes()
    lock = tomllib.loads(original_lock.decode())
    pinned = [p for p in lock["package"] if p["name"] == "unicorn-engine"]
    if len(pinned) != 1 or pinned[0]["version"] != "2.1.3" or pinned[0]["checksum"] != UNICORN_CHECKSUM:
        raise RuntimeError("unexpected Unicorn lock entry")
    metadata = capture_json(["cargo","metadata","--locked","--format-version=1","--manifest-path",manifest], source, env)
    crates = [p for p in metadata["packages"] if p["name"] == "unicorn-engine" and p["version"] == "2.1.3"]
    if len(crates) != 1 or not crates[0]["source"].startswith("registry+"):
        raise RuntimeError("expected pinned registry Unicorn source")
    registry = Path(crates[0]["manifest_path"]).resolve().parent
    archive = Path(env["CARGO_HOME"]) / "registry/cache" / registry.parent.name / "unicorn-engine-2.1.3.crate"
    if hashlib.sha256(archive.read_bytes()).hexdigest() != UNICORN_CHECKSUM:
        raise RuntimeError("registry archive provenance mismatch")
    vendor_root = temporary / "corten-unicorn-android-source"
    if vendor_root.exists():
        raise RuntimeError("existing owned dependency copy must not be replaced")
    vendor_root.mkdir()
    with tarfile.open(archive) as package:
        if any(not member.name.startswith("unicorn-engine-2.1.3/") for member in package.getmembers()):
            raise RuntimeError("unexpected archive root")
        package.extractall(vendor_root, filter="data")
    vendor = vendor_root / "unicorn-engine-2.1.3"
    build = vendor / "bindings/rust/build.rs"
    original_build_bytes = build.read_bytes()
    original = build.read_text()
    changed = patch_android_thread_directives(original)
    patch_file = temporary / "corten-android-pthread.patch"
    patch_file.write_text("".join(difflib.unified_diff(original.splitlines(True),changed.splitlines(True),
                          fromfile="a/bindings/rust/build.rs",tofile="b/bindings/rust/build.rs")))
    patched = command(["patch","--batch","--forward","--fuzz=0","-p1","-i",str(patch_file)],vendor,out / "android-dependency-patch.log",5,env)
    if patched["exit"]:
        raise RuntimeError("target-specific dependency patch failed")
    override = f'patch.crates-io.unicorn-engine.path="{vendor}"'
    # Resolve only this explicit owned copy; do not edit the shared registry.
    capture_json(["cargo","metadata","--offline","--format-version=1","--manifest-path",manifest,"--config",override],source,env)
    new_lock = tomllib.loads((prototype / "Cargo.lock").read_text())
    without_engine = lambda packages: sorted((p["name"],p["version"],p.get("source"),p.get("checksum")) for p in packages if p["name"] != "unicorn-engine")
    if without_engine(lock["package"]) != without_engine(new_lock["package"]):
        raise RuntimeError("unrelated dependency lock drift")
    return override, {"base_registry_checksum":UNICORN_CHECKSUM,
                      "original_build_sha256":hashlib.sha256(original_build_bytes).hexdigest(),
                      "patched_build_sha256":hashlib.sha256((vendor / "bindings/rust/build.rs").read_bytes()).hexdigest(),
                      "prototype_lock_before":hashlib.sha256(original_lock).hexdigest(),
                      "prototype_lock_after":hashlib.sha256((prototype / "Cargo.lock").read_bytes()).hexdigest(),
                      "unrelated_lock_entries_unchanged":True,"shared_registry_changed":False}


def git(source, *args):
    return subprocess.check_output(["git", "-C", str(source), *args], text=True).strip()


def verify_source(source):
    if git(source, "rev-parse", "HEAD") != SOURCE:
        raise RuntimeError("reviewed application SHA required")
    if git(source, "status", "--porcelain", "--untracked-files=no"):
        raise RuntimeError("tracked application source is dirty")
    if git(source / "rustpush", "rev-parse", "HEAD") != NATIVE:
        raise RuntimeError("reviewed rustpush pin required")
    status = git(source, "submodule", "status", "--recursive").splitlines()
    if len(status) != 6 or any(row.startswith(("-", "+", "U")) for row in status):
        raise RuntimeError("six initialized exact recursive pins required")
    return status


def reap(process):
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=3)
    OWNED_GROUPS.discard(process.pid)


def command(args, directory, log, timeout, env=None, private_input=None):
    began = time.monotonic()
    process = subprocess.Popen(
        args, cwd=directory, env=env, stdin=subprocess.PIPE if private_input is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True,
    )
    OWNED_GROUPS.add(process.pid)
    try:
        output, _ = process.communicate(input=private_input, timeout=timeout)
    except subprocess.TimeoutExpired:
        reap(process)
        raise RuntimeError("bounded owned process timed out")
    finally:
        private_input = None
    reap(process)
    if len(output) > 2 * 1024 * 1024:
        raise RuntimeError("diagnostic output exceeded bound")
    log.write_bytes(output)
    text = output.decode("utf-8", errors="replace")
    # Input/proof bytes never reach stdout; the probe emits metadata only.
    print(text, flush=True)
    result = {"exit": process.returncode, "seconds": time.monotonic() - began, "log": log.name,
              "log_sha256": hashlib.sha256(output).hexdigest(), "owned_process_reaped": True}
    return result


def decode_private_input(encoded):
    if len(encoded) > 1024:
        raise RuntimeError("private transfer exceeds bound")
    raw = base64.b64decode(encoded, validate=True)
    if len(raw) != 423 or not raw.startswith(b"OABS\0") or hashlib.sha256(raw).hexdigest() != TRANSFER_SHA256:
        raise RuntimeError("private transfer identity mismatch")
    return raw


def metadata_input():
    print("READY_FOR_OPTIONAL_PRIVATE_HARDWARE_INPUT", flush=True)
    deadline = time.monotonic() + 180
    address = "http://metadata.google.internal/computeMetadata/v1/instance/attributes/" + METADATA_KEY
    while time.monotonic() < deadline:
        request = urllib.request.Request(address, headers={"Metadata-Flavor": "Google"})
        try:
            with urllib.request.urlopen(request, timeout=3) as response:
                if response.headers.get("Metadata-Flavor") != "Google":
                    raise RuntimeError("unexpected metadata provider")
                encoded = response.read(1025)
            return decode_private_input(encoded)
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise RuntimeError("private input metadata unavailable") from None
        time.sleep(3)
    return None


def fetch_framework(path):
    with urllib.request.urlopen(FRAMEWORK_URL, timeout=20) as response:
        data = response.read(6_222_785)
    if len(data) != 6_222_784 or hashlib.sha256(data).hexdigest() != FRAMEWORK_SHA256:
        raise RuntimeError("pinned external framework mismatch")
    path.write_bytes(data)


def qualify(source, out, android_only=False):
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    out.mkdir(parents=True, exist_ok=False)
    receipt = {"request":"OB-CORTEN-COMPONENT-20261013-A", "application_sha":SOURCE, "native_sha":NATIVE,
               "account_access":False, "relay_access":False, "apk_build":False,
               "private_hardware":"UNRUN", "android_execution":"UNRUN", "production_integration":"UNRUN"}
    if android_only:
        receipt["request"] = "OB-CORTEN-ANDROID-20261013-B"
        receipt["linux_tests"] = "SKIPPED_ALREADY_QUALIFIED_38341133825"
        receipt["engine"] = "SKIPPED_ALREADY_QUALIFIED_38341133825"
    began = time.monotonic()
    temporary = Path(os.environ["RUNNER_TEMP"])
    prototype = source / "tooling/cloud_sync/corten_mac_validation_probe"
    tools = Path(__file__).resolve().parent.parent / "corten_mac_validation_probe"
    failure = None
    try:
        receipt["pins"] = verify_source(source)
        if prototype.exists():
            raise RuntimeError("existing prototype directory must not be replaced")
        shutil.copytree(tools, prototype)
        env = os.environ.copy()
        env["CARGO_TARGET_DIR"] = str(temporary / "corten-target")
        env["CARGO_BUILD_JOBS"] = "6"
        env["CARGO_PROFILE_DEV_DEBUG"] = "0"
        env["CARGO_INCREMENTAL"] = "0"
        env["RUSTFLAGS"] = ""
        env.pop("CARGO_ENCODED_RUSTFLAGS", None)
        env.pop("RUSTC_WRAPPER", None)
        manifest = str(prototype / "Cargo.toml")
        if not android_only:
            receipt["linux_tests"] = command(["cargo","test","--locked","--manifest-path",manifest,"--lib","--","--test-threads=1"], source, out / "linux-tests.log", 420, env)
            if receipt["linux_tests"]["exit"]:
                raise RuntimeError("Linux component regressions failed")
            receipt["linux_build"] = command(["cargo","build","--locked","--manifest-path",manifest], source, out / "linux-build.log", 240, env)
            if receipt["linux_build"]["exit"]:
                raise RuntimeError("Linux component build failed")
            binary = temporary / "corten-target/debug/corten-mac-validation-probe"
            framework = temporary / "corten-IMDAppleServices"
            fetch_framework(framework)
            receipt["framework_sha256"] = FRAMEWORK_SHA256
            receipt["linux_binary_sha256"] = hashlib.sha256(binary.read_bytes()).hexdigest()
            receipt["engine"] = command([str(binary),"--framework",str(framework),"engine"], source, out / "linux-engine.log", 15, env)
            if receipt["engine"]["exit"]:
                raise RuntimeError("Linux engine qualification failed")
            private = metadata_input()
            if private is not None:
                receipt["private_hardware"] = command([str(binary),"--framework",str(framework),"validate"], source, out / "private-validation-metadata.log", 75, env, private)
                private = None
                if receipt["private_hardware"]["exit"]:
                    failure = "genuine Mac challenge-response did not qualify"
            else:
                receipt["private_hardware_reason"] = "no separately authorized private input supplied during the bounded window"

        override, receipt["android_dependency"] = prepare_android_dependency(prototype,temporary,source,env,out)
        ndk = Path(env["ANDROID_NDK_HOME"])
        compiler = ndk / "toolchains/llvm/prebuilt/linux-x86_64/bin"
        android_env = env.copy()
        android_env.update({
            "CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER":str(compiler / "aarch64-linux-android24-clang"),
            "CC_aarch64_linux_android":str(compiler / "aarch64-linux-android24-clang"),
            "CXX_aarch64_linux_android":str(compiler / "aarch64-linux-android24-clang++"),
            "AR_aarch64_linux_android":str(compiler / "llvm-ar"),
            "RANLIB_aarch64_linux_android":str(compiler / "llvm-ranlib"),
            "CMAKE_TOOLCHAIN_FILE_aarch64_linux_android":str(Path(__file__).resolve().parent / "corten_android.cmake"),
        })
        receipt["android_build"] = command(["cargo","build","--locked","--manifest-path",manifest,"--config",override,"--target","aarch64-linux-android"], source, out / "android-build.log", 600, android_env)
        if receipt["android_build"]["exit"]:
            raise RuntimeError("Android component cross-build failed")
        android_binary = temporary / "corten-target/aarch64-linux-android/debug/corten-mac-validation-probe"
        receipt["android_elf_sha256"] = hashlib.sha256(android_binary.read_bytes()).hexdigest()
        if android_binary.read_bytes()[:4] != b"\x7fELF":
            raise RuntimeError("Android output is not an ELF")
        receipt["android_elf"] = command(["readelf","-h",str(android_binary)], source, out / "android-elf.log", 5, env)
        if receipt["android_elf"]["exit"]:
            raise RuntimeError("Android ELF verification failed")
    except Exception as error:
        failure = str(error)
    finally:
        for group in list(OWNED_GROUPS):
            try:
                os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass
        receipt["tracked_source_after"] = git(source, "status", "--porcelain", "--untracked-files=no")
        receipt["owned_process_groups"] = len(OWNED_GROUPS)
        receipt["seconds"] = time.monotonic() - began
        receipt["result"] = "failed" if failure else "source_component_qualified"
        if failure:
            receipt["error"] = failure
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
        # No external framework or linked AGPL/GPL binary is published as an artifact.
        if receipt["tracked_source_after"]:
            raise RuntimeError("tracked source changed unexpectedly")
    if failure:
        raise RuntimeError(failure)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--android-only", action="store_true")
    args = parser.parse_args()
    qualify(args.source.resolve(), args.out.resolve(), args.android_only)


if __name__ == "__main__":
    main()
