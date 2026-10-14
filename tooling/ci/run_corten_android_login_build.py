"""One private single-x64 normal Android app build; no account or framework input."""
import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
from urllib.parse import urlparse
from urllib.request import url2pathname
import zipfile

from run_corten_login_integration import (SOURCE, NATIVE, TOOLS, OVERLAY, digest,
    overlay, unchanged_registry_pins, remove_owned_inputs, verify_overlay_source)
from run_corten_component_probe import (OWNED_GROUPS, command, git,
    prepare_android_dependency, verify_source)
from sealed_component import seal, LOGIN_TARGET

EXTRA_TRACKED = ("pubspec.lock", "android/gradle.properties", "android/app/build.gradle",
    "rust_builder/cargokit/gradle/plugin.gradle",
    "rust_builder/cargokit/build_tool/lib/src/builder.dart",
    ".dart_tool/build/fcd1995bc647fb959e82ea360c6c2c9a/asset_graph.json",
    "linux/flutter/generated_plugin_registrant.cc", "linux/flutter/generated_plugins.cmake",
    "windows/flutter/generated_plugin_registrant.cc", "windows/flutter/generated_plugins.cmake",
    "macos/Flutter/GeneratedPluginRegistrant.swift")


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError("private build overlay differs from reviewed baseline: " + old[:60])
    return text.replace(old, new, 1)


@contextmanager
def single_target_pub_plugins(source, pub_cache):
    """Suppress unused debug x86 builds in the two resolved plugin copies."""
    originals = {}
    cache = pub_cache.resolve()
    packages = json.loads((source/".dart_tool/package_config.json").read_text())["packages"]
    try:
        for name in ("irondash_engine_context", "super_native_extensions"):
            matches = [p for p in packages if p["name"] == name]
            if len(matches) != 1:
                raise RuntimeError("resolved CargoKit plugin missing: " + name)
            uri = urlparse(matches[0]["rootUri"])
            if uri.scheme != "file" or uri.netloc:
                raise RuntimeError("expected local resolved pub package")
            plugin = Path(url2pathname(uri.path))/"cargokit/gradle/plugin.gradle"
            if not plugin.resolve().is_relative_to(cache) or plugin.is_symlink():
                raise RuntimeError("plugin escaped isolated pub cache")
            raw = plugin.read_bytes()
            changed = replace_once(raw.decode(), 'if (buildType == "debug") {',
                'if (buildType == "debug" && !flutterProject.hasProperty("target-platform")) {')
            originals[plugin] = raw
            plugin.write_text(changed)
        yield
    finally:
        for path, raw in originals.items():
            path.write_bytes(raw)


@contextmanager
def build_overlay(source, override):
    originals = {name:(source/name).read_bytes() if (source/name).is_file() else None
                 for name in EXTRA_TRACKED}
    config = source/"rust/cargokit.yaml"
    if config.exists():
        raise RuntimeError("refuse existing CargoKit configuration")
    try:
        # Exact compiler and one requested target, instead of CargoKit's extra
        # debug ABIs. Only this fresh private checkout is changed, then restored.
        builder = source/EXTRA_TRACKED[4]
        builder.write_text(replace_once(builder.read_text(),
            "_buildOptions?.toolchain.name ?? 'stable'", "'1.98.1'"))
        plugin = source/EXTRA_TRACKED[3]
        plugin.write_text(replace_once(plugin.read_text(),
            'if (buildType == "debug") {',
            'if (buildType == "debug" && !flutterProject.hasProperty("target-platform")) {'))
        gradle = source/"android/app/build.gradle"
        content = replace_once(gradle.read_text(), "    compileSdk 36",
            '    compileSdk 36\n    ndkVersion "28.2.13676358"')
        gradle.write_text(content)
        props = source/"android/gradle.properties"
        lines = [line for line in props.read_text().splitlines()
                 if not line.startswith(("org.gradle.jvmargs=", "org.gradle.workers.max=", "org.gradle.daemon="))]
        props.write_text("\n".join(lines) + "\norg.gradle.jvmargs=-Xmx4096M -XX:MaxMetaspaceSize=1536M\norg.gradle.workers.max=2\norg.gradle.daemon=false\n")
        # JSON is a YAML subset. Existing CargoKit parser receives normal flags.
        config.write_text(json.dumps({"cargo":{"debug":{"extra_flags":[
            "--features", "corten-dev-validation", "--offline", "--locked", "--config", override]}}}))
        yield
    finally:
        config.unlink(missing_ok=True)
        for name, raw in originals.items():
            path = source/name
            if raw is None:
                path.unlink(missing_ok=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(raw)


def check_apk(apk):
    required = {"libflutter.so", "librust_lib_bluebubbles.so",
                "libirondash_engine_context_native.so", "libsuper_native_extensions.so"}
    with zipfile.ZipFile(apk) as archive:
        native = [n for n in archive.namelist() if n.startswith("lib/") and n.endswith(".so")]
        if not native or {n.split("/")[1] for n in native} != {"x86_64"}:
            raise RuntimeError("APK is not single-x64")
        if not required.issubset({Path(n).name for n in native}):
            raise RuntimeError("APK missing required native libraries")
        header = archive.open("lib/x86_64/librust_lib_bluebubbles.so").read(20)
        if header[:6] != b"\x7fELF\x02\x01" or header[18:20] != b"\x3e\x00":
            raise RuntimeError("actual application ELF is not x64")
    return {"bytes":apk.stat().st_size, "sha256":digest(apk), "abi":"x86_64"}


def run(source, out, delivery):
    if os.name != "posix":
        raise RuntimeError("qualification runs on the isolated Linux worker only")
    out.mkdir(parents=True, exist_ok=False)
    delivery.mkdir(parents=True, exist_ok=False)
    started = time.monotonic()
    env = os.environ.copy()
    temporary = Path(env["RUNNER_TEMP"])
    env.update({"CARGO_BUILD_JOBS":"2", "CARGO_PROFILE_DEV_DEBUG":"0",
                "CARGO_INCREMENTAL":"0", "RUSTFLAGS":""})
    env.pop("CARGO_ENCODED_RUSTFLAGS", None)
    env.pop("RUSTC_WRAPPER", None)
    receipt = {"source":SOURCE,"native":NATIVE,"account_access":False,
               "hardware_input":False,"apple_requests":False,"app_execution":"UNRUN"}
    directories, files = [], []
    code = 1
    def checked(name, args, seconds, cwd=source):
        print(json.dumps({"build_phase":name,"state":"started"}),flush=True)
        receipt[name] = command(args, cwd, out/(name+".log"), seconds, env)
        print(json.dumps({"build_phase":name,"state":"finished","exit":receipt[name]["exit"],
                          "seconds":receipt[name]["seconds"]}),flush=True)
        if receipt[name]["exit"]:
            raise RuntimeError(name + " failed; see bounded log")
    try:
        receipt["pins"] = verify_source(source)
        if shutil.disk_usage(source).free < 20*1024**3:
            raise RuntimeError("less than20GiB free for the single-ABI build")
        prototype = source/"tooling/cloud_sync/corten_mac_validation_probe"
        if prototype.exists():
            raise RuntimeError("prototype destination must be fresh")
        prototype.mkdir(parents=True)
        directories.append(prototype)
        shutil.copytree(TOOLS/"corten_mac_validation_probe", prototype, dirs_exist_ok=True)
        receipt["overlay_sha256"] = {p.name:digest(p) for p in OVERLAY.iterdir() if p.is_file()}
        receipt["prototype_build_sha256"] = digest(prototype/"build.rs")
        for suffix in ("crt", "pem"):
            for number in list(range(193,202))+[208]:
                path = source/f"rustpush/certs/fairplay/4056631661436364584235346952{number}.{suffix}"
                path.parent.mkdir(parents=True, exist_ok=True)
                with path.open("xb") as target:
                    files.append(path)
                    target.write((source/f"rustpush/certs/legacy-fairplay/fairplay.{suffix}").read_bytes())
        with overlay(source,out,env) as original_lock:
            receipt["application_source_hashes"] = verify_overlay_source(source)
            manifest = str(source/"rust/Cargo.toml")
            checked("resolve", ["cargo","fetch","--manifest-path",manifest], 300)
            receipt["added_pins"] = unchanged_registry_pins(original_lock,(source/"rust/Cargo.lock").read_bytes())
            override, receipt["android_dependency"] = prepare_android_dependency(prototype,temporary,source,env,out)
            checked("android-resolve", ["cargo","fetch","--offline","--manifest-path",manifest,"--config",override],90)
            receipt["android_lock_sha256"] = digest(source/"rust/Cargo.lock")
            shutil.copyfile(source/"rust/Cargo.lock",out/"android.Cargo.lock")
            compiler = Path(env["ANDROID_NDK_HOME"])/"toolchains/llvm/prebuilt/linux-x86_64/bin"
            env.update({"CARGO_TARGET_X86_64_LINUX_ANDROID_LINKER":str(compiler/"x86_64-linux-android24-clang"),
                "CC_x86_64_linux_android":str(compiler/"x86_64-linux-android24-clang"),
                "CXX_x86_64_linux_android":str(compiler/"x86_64-linux-android24-clang++"),
                "AR_x86_64_linux_android":str(compiler/"llvm-ar"),
                "RANLIB_x86_64_linux_android":str(compiler/"llvm-ranlib"),
                "CMAKE_TOOLCHAIN_FILE_x86_64_linux_android":str(Path(__file__).with_name("corten_android_x64.cmake")),
                "CARGO_TARGET_DIR":str(source/"build/rust_lib_bluebubbles/build")})
            env["PATH"] = str(compiler)+os.pathsep+env["PATH"]
            with build_overlay(source,override):
                checked("pub-get", ["flutter","pub","get","--enforce-lockfile"],300)
                checked("cargokit-patch", ["bash","tooling/android/patch_pub_cache_cargokit.sh"],60)
                with single_target_pub_plugins(source,Path(env["PUB_CACHE"])):
                    checked("apk-build", ["flutter","build","apk","--no-pub","--flavor","canary","--debug",
                        "--target-platform","android-x64","--split-per-abi", "--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SAMPLER=true",
                        "--dart-define=OPENBUBBLES_CLOUD_SYNC_V2_SEMANTIC_PULL=true",
                        "--dart-define=OPENBUBBLES_BUILD_COMMIT="+SOURCE],1800)
                apk = source/"build/app/outputs/flutter-apk/app-x86_64-canary-debug.apk"
                receipt["apk"] = check_apk(apk)
                checked("network-probe-build", ["cargo","build","--offline","--locked","--manifest-path",
                    str(prototype/"Cargo.toml"),"--config",override,"--target","x86_64-linux-android"],300)
                probe = Path(env["CARGO_TARGET_DIR"])/"x86_64-linux-android/debug/corten-mac-validation-probe"
                shutil.copyfile(apk,delivery/"app-canary-debug.apk")
                shutil.copyfile(probe,delivery/"corten-mac-validation-probe")
                bundle = temporary/"corten-android-login.zip"
                with zipfile.ZipFile(bundle,"x",compression=zipfile.ZIP_DEFLATED,compresslevel=1) as package:
                    for name in ("app-canary-debug.apk","corten-mac-validation-probe"):
                        package.write(delivery/name,name)
                receipt["private_bundle"] = seal(bundle,Path(__file__).with_name("corten_android_login_recipient.pem"),
                    out/"login.sealed",SOURCE,git(TOOLS.parent,"rev-parse","HEAD"),target=LOGIN_TARGET)
                bundle.unlink()
        code = 0
    except Exception as error:
        receipt["failure"] = str(error)
    finally:
        for group in list(OWNED_GROUPS):
            try: os.killpg(group,signal.SIGKILL)
            except ProcessLookupError: pass
        try:
            remove_owned_inputs(source,directories,files)
            receipt["owned_inputs_removed"] = True
            receipt["restored_pins"] = verify_source(source)
        except Exception as error:
            receipt["restoration_failure"] = str(error)
            code = 1
        receipt["seconds"] = round(time.monotonic()-started,3)
        receipt["result"] = "private_apk_built_not_logged_in" if code == 0 else "failed"
        (out/"receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
        print(json.dumps(receipt),flush=True)
    return code


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("source","out","delivery"):
        parser.add_argument("--"+name,type=Path,required=True)
    args = parser.parse_args()
    raise SystemExit(run(args.source.resolve(),args.out.resolve(),args.delivery.resolve()))
