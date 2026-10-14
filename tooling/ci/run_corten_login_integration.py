"""One exact-source, credential-free private-provider integration batch.

The overlay is explicit, reviewed and restored. No app/account/Apple operation,
APK, signing, framework download or hardware input occurs in this qualification.
"""
import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import time
import tomllib

from run_corten_component_probe import (SOURCE, NATIVE, OWNED_GROUPS, command,
    git, prepare_android_dependency, verify_source)

TOOLS = Path(__file__).resolve().parents[1]
OVERLAY = TOOLS / "corten_login_integration"
TRACKED = (
    "lib/cloud_sync_v2_windows_harness.dart",
    "lib/services/rustpush/rustpush_service.dart",
    "lib/app/layouts/setup/setup_view.dart",
    "lib/app/layouts/setup/pages/rustpush/appleid_login.dart",
    "lib/app/layouts/setup/pages/rustpush/hw_inp.dart",
    "lib/app/layouts/setup/pages/rustpush/phone_number.dart",
    "lib/src/rust/api/api.dart",
    "lib/src/rust/frb_generated.dart",
    "rust/Cargo.toml",
    "rust/Cargo.lock",
    "rust/src/api/api.rs",
    "rust/src/api/cloud_sync_chat1_correlation.rs",
    "rust/src/frb_generated.rs",
    "rust/src/lib.rs",
    "test/services/rustpush_startup_readiness_contract_test.dart",
    "rustpush/Cargo.toml",
    "rustpush/src/lib.rs",
    "rustpush/src/macos.rs",
    "rustpush/keystore/src/software.rs",
    "rustpush/keystore/src/backup.rs",
    "rustpush/apple-private-apis/icloud-auth/src/client.rs",
    "rustpush/apple-private-apis/icloud-auth/src/lib.rs",
)
ADDED = {
    "rust/src/corten_dev_validation.rs": "corten_dev_validation.rs",
    "rustpush/src/mac_validation_provider.rs": "mac_validation_provider.rs",
    "test/app/layouts/setup/setup_connection_failure_test.dart": "setup_connection_failure_test.dart",
    "test/app/layouts/setup/trusted_device_verification_test.dart": "trusted_device_verification_test.dart",
    "rustpush/apple-private-apis/icloud-auth/src/auth_probe.rs": "auth_probe.rs"
}

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify_overlay_source(source):
    """Require the exact reviewed text snapshot, including both FFI sides."""
    manifest = json.loads((OVERLAY / "source-manifest.json").read_text())
    if (manifest.get("format_version") != 1 or manifest.get("source") != SOURCE
            or manifest.get("native") != NATIVE
            or manifest.get("normalization") != "utf8-crlf-to-lf"
            or set(manifest.get("files", {})) != set(TRACKED) | set(ADDED)):
        raise RuntimeError("Integration source manifest does not match admitted scope")
    for name, expected in manifest["files"].items():
        actual = hashlib.sha256((source/name).read_bytes().replace(b"\r\n", b"\n")).hexdigest()
        if actual != expected:
            raise RuntimeError("Integration source differs from reviewed snapshot: " + name)
    return manifest["files"]

def remove_owned_inputs(source, directories, files):
    """Only inputs created by this invocation, never evidence or existing work."""
    root = source.resolve()
    for path in [*files, *directories]:
        resolved = path.resolve()
        if resolved == root or not resolved.is_relative_to(root) or path.is_symlink():
            raise RuntimeError("Owned cleanup target escaped exact source checkout")
    for path in reversed(files):
        path.unlink(missing_ok=True)
    for path in reversed(directories):
        if path.exists():
            shutil.rmtree(path)
    if any(path.exists() for path in [*files, *directories]):
        raise RuntimeError("Owned input cleanup incomplete")

def unchanged_registry_pins(before, after):
    keys = lambda raw: {(p["name"], p["version"], p.get("source"), p.get("checksum"))
                       for p in tomllib.loads(raw.decode())["package"] if p.get("source")}
    missing = keys(before) - keys(after)
    if missing:
        raise RuntimeError("Existing application dependency pins changed: " + repr(sorted(missing)))
    return sorted(keys(after) - keys(before))

@contextmanager
def overlay(source, out, env):
    originals = {name:(source / name).read_bytes() for name in TRACKED}
    for name in ADDED:
        if (source / name).exists():
            raise RuntimeError("Refuse to replace existing integration module: " + name)
    try:
        check = command(["git","apply","--check",str(OVERLAY / "application.patch")], source,
                        out / "overlay-check.log", 10, env)
        if check["exit"]:
            raise RuntimeError("Integration patch differs from exact baseline")
        applied = command(["git","apply",str(OVERLAY / "application.patch")], source,
                          out / "overlay-apply.log", 10, env)
        if applied["exit"]:
            raise RuntimeError("Integration patch did not apply")
        for destination, template in ADDED.items():
            (source / destination).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(OVERLAY / template, source / destination)
        verify_overlay_source(source)
        yield originals["rust/Cargo.lock"]
    finally:
        for name, original in originals.items():
            (source / name).write_bytes(original)
        for name in ADDED:
            (source / name).unlink(missing_ok=True)

def run(source, out):
    out.mkdir(parents=True, exist_ok=False)
    began = time.monotonic()
    receipt = {"source":SOURCE,"native":NATIVE,"account_access":False,
        "hardware_input":False,"apple_requests":False,"apk":False,
        "app_execution":"UNRUN","android_execution":"UNRUN"}
    env = os.environ.copy()
    temporary = Path(env["RUNNER_TEMP"])
    env.update({"CARGO_TARGET_DIR":str(temporary / "corten-integration-target"),
                "CARGO_BUILD_JOBS":"6", "CARGO_PROFILE_DEV_DEBUG":"0",
                "CARGO_PROFILE_TEST_DEBUG":"0", "CARGO_INCREMENTAL":"0",
                "RUSTFLAGS":""})
    env.pop("CARGO_ENCODED_RUSTFLAGS",None)
    env.pop("RUSTC_WRAPPER",None)
    result = 1
    owned_directories, owned_files = [], []
    try:
        receipt["pins"] = verify_source(source)
        if shutil.disk_usage(source).free < 20 * 1024**3:
            raise RuntimeError("Less than20GiB free before integration")
        prototype = source / "tooling/cloud_sync/corten_mac_validation_probe"
        if prototype.exists():
            raise RuntimeError("Prototype destination must be new")
        prototype.mkdir(parents=True)
        owned_directories.append(prototype)
        shutil.copytree(TOOLS / "corten_mac_validation_probe", prototype, dirs_exist_ok=True)
        receipt["overlay_sha256"] = {p.name:digest(p) for p in OVERLAY.iterdir() if p.is_file()}
        for suffix in ("crt","pem"):
            for number in list(range(193,202)) + [208]:
                target = source / f"rustpush/certs/fairplay/4056631661436364584235346952{number}.{suffix}"
                if target.exists():
                    raise RuntimeError("Unexpected existing FairPlay fixture")
                target.parent.mkdir(parents=True,exist_ok=True)
                with target.open("xb") as fixture:
                    owned_files.append(target)
                    with (source / f"rustpush/certs/legacy-fairplay/fairplay.{suffix}").open("rb") as original:
                        shutil.copyfileobj(original, fixture)
        with overlay(source,out,env) as original_lock:
            receipt["application_source_hashes"] = verify_overlay_source(source)
            manifest = str(source / "rust/Cargo.toml")
            # Preserve every existing registry pin; allow only additive engine
            # packages before freezing this one private integration graph.
            receipt["resolve"] = command(["cargo","fetch",
                "--manifest-path",manifest],source,
                out / "resolve.log",300,env)
            if receipt["resolve"]["exit"]:
                raise RuntimeError("Private integration graph did not resolve")
            receipt["added_pins"] = unchanged_registry_pins(original_lock,(source / "rust/Cargo.lock").read_bytes())
            shutil.copyfile(source / "rust/Cargo.lock",out / "integration.Cargo.lock")
            receipt["integration_lock_sha256"] = digest(source / "rust/Cargo.lock")
            base = ["cargo","test","--offline","--locked","--manifest-path",manifest,
                    "--features","corten-dev-validation"]
            receipt["adapter_tests"] = command(base + ["--lib","corten_dev_validation::tests::","--","--test-threads=1"],
                source,out / "adapter-tests.log",900,env)
            if receipt["adapter_tests"]["exit"]:
                raise RuntimeError("Actual app provider tests failed")
            receipt["exchange_tests"] = command(["cargo","test","--locked",
                "--manifest-path",str(prototype/"Cargo.toml"),"--lib","exchange::tests::"],
                source,out / "exchange-tests.log",300,env)
            if receipt["exchange_tests"]["exit"]:
                raise RuntimeError("Shared exchange tests failed")
            receipt["unavailable_guard"] = "COVERED_BY_ACTUAL_APP_ADAPTER_TEST"
            # Same owned upstream fix used by the already-running Android
            # component. Never change the shared Cargo registry.
            override,receipt["android_dependency"] = prepare_android_dependency(prototype,temporary,source,env,out)
            # Add the exact owned source replacement, with no unrelated updates.
            receipt["android_resolve"] = command(["cargo","fetch","--offline",
                "--manifest-path",manifest,"--config",override],
                source,out / "android-resolve.log",90,env)
            if receipt["android_resolve"]["exit"]:
                raise RuntimeError("Android source override failed")
            receipt["android_lock_sha256"] = digest(source / "rust/Cargo.lock")
            shutil.copyfile(source / "rust/Cargo.lock", out/"android.Cargo.lock")
            compiler = Path(env["ANDROID_NDK_HOME"]) / "toolchains/llvm/prebuilt/linux-x86_64/bin"
            env.update({"CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER":str(compiler/"aarch64-linux-android24-clang"),
                "CC_aarch64_linux_android":str(compiler/"aarch64-linux-android24-clang"),
                "CXX_aarch64_linux_android":str(compiler/"aarch64-linux-android24-clang++"),
                "AR_aarch64_linux_android":str(compiler/"llvm-ar"),
                "RANLIB_aarch64_linux_android":str(compiler/"llvm-ranlib"),
                "CMAKE_TOOLCHAIN_FILE_aarch64_linux_android":str(Path(__file__).with_name("corten_android.cmake"))})
            env["PATH"] = str(compiler) + os.pathsep + env["PATH"]
            receipt["android_library"] = command(["cargo","build","--offline","--locked",
                "--manifest-path",manifest,"--features","corten-dev-validation","--config",override,
                "--target","aarch64-linux-android","--lib"],source,out/"android-library.log",900,env)
            if receipt["android_library"]["exit"]:
                raise RuntimeError("Integrated Android native library failed")
            library = Path(env["CARGO_TARGET_DIR"])/"aarch64-linux-android/debug/librust_lib_bluebubbles.so"
            from sealed_component import seal
            receipt["private_library"] = seal(library,Path(__file__).with_name("corten_integration_recipient.pem"),
                out/"native-library.sealed",SOURCE,git(TOOLS.parent,"rev-parse","HEAD"))
            result = 0
    except Exception as error:
        receipt["failure"] = str(error)
    finally:
        for group in list(OWNED_GROUPS):
            try: os.killpg(group,signal.SIGKILL)
            except ProcessLookupError: pass
        try:
            remove_owned_inputs(source, owned_directories, owned_files)
            receipt["owned_inputs_removed"] = True
        except Exception as error:
            receipt["owned_input_cleanup_failure"] = str(error)
            result = 1
        try:
            receipt["restored_pins"] = verify_source(source)
        except Exception as error:
            receipt["restoration_failure"] = str(error)
            result = 1
        receipt["seconds"] = round(time.monotonic()-began,3)
        receipt["result"] = "integration_compiled_not_logged_in" if result==0 else "failed"
        (out/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
        print(json.dumps(receipt))
    return result

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--source",required=True,type=Path)
    parser.add_argument("--out",required=True,type=Path)
    args=parser.parse_args()
    raise SystemExit(run(args.source.resolve(),args.out.resolve()))
