"""Bounded credential-free Linux transport and/or ARM64 Android console build.

The immutable application's dependency graph is used, not rustpush/Cargo.lock.
Only temporary diagnostic exports are added. Tracked bytes are restored even
when a compiler or probe fails. This does not build or launch an APK.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import time

SOURCE = "ad05e2136a9f722aab74d3381a65483e49f5d1dc"
PINS = {
    "rustpush": "5076fe684b8856886c295e99b623757d9cf6b754",
    "rustpush/apple-private-apis": "e2891c317e264dd0eb73e6bb87f0ef37714cc160",
    "rustpush/apple-private-apis/clearadi": "663f33f9d71b0df5436d04611755142df6db6a35",
    "rustpush/open-absinthe": "1f8dc73a311e7b4d94a868972a6816c8a2c14e44",
    "telephony_plus": "5210e940dd92ae371f8c74eaeb552d0704034244",
    "telephony_plus/android-smsmms": "36f34f482dd5546c929f448d746c3124875a4faa",
}
HASHES = {
    "rust/Cargo.lock": "ec39e1d3bfd6ddfc2b33e8ac19a6831047056b4bd174979141ba31e845081a93",
    "rust/Cargo.toml": "8a78feb48654da43aca5a734c6e855745c449d7e56dde52a56e499ad1dc0d219",
    "rustpush/src/lib.rs": "6f3660c473272c8675a5e0a4a26951896f4d266fac4b144b3b8349f0120f4e35",
    "rustpush/src/util.rs": "4b65f9d77ce830a66ae082ff3da7981ff0d61c952ee150bb651fee3e8f04ce76",
    "rustpush/apple-private-apis/icloud-auth/src/lib.rs": "37350a7995e93835f5c2e93a0ae59e8283fb99a632d8086593ec7001de6defc2",
    "rustpush/apple-private-apis/icloud-auth/src/client.rs": "7666143bd4da1b1e8ad6ac1c41795f76ac1680aeb4521f0c05130ee977889546",
    "rustpush/certs/root/profileidentity.ess.apple.com.cert": "0c0daaff3aaf1be8d257a1948c98aa469b476ab26fd9a51b597d38004cfbd63e",
    "rustpush/certs/root/init.ess.apple.com.cert": "f83c5c9357eebba5d70331640b4b9f15790a251f1f7424914840ccc51db16046",
    "rustpush/apple-private-apis/icloud-auth/src/apple_root.der": "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
}
BIN = "rust/src/bin/ob_strict_tls_probe.rs"
TARGET = "aarch64-linux-android"
TEMPLATES = Path(__file__).resolve().parent / "transport_probe"


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def verify_source(root: Path) -> dict:
    if git(root, "rev-parse", "HEAD") != SOURCE:
        raise RuntimeError("Source differs from exact reviewed ad05 candidate")
    states = {}
    for relative, expected in {".": SOURCE, **PINS}.items():
        directory = root / relative
        states[relative] = git(directory, "status", "--porcelain")
        if git(directory, "rev-parse", "HEAD") != expected or states[relative]:
            raise RuntimeError(f"Unqualified or dirty source: {relative}")
    for relative, expected in HASHES.items():
        if sha(root / relative) != expected:
            raise RuntimeError(f"Source fingerprint differs: {relative}")
    return {"source": SOURCE, "pins": PINS, "sha256": HASHES, "clean": True}


@contextmanager
def overlay(root: Path):
    binary_source = root / BIN
    if binary_source.exists():
        raise RuntimeError("Refusing to replace an existing diagnostic source")
    additions = {
        "rustpush/src/lib.rs": b"\npub use reqwest as OB_STRICT_TLS_REQWEST;\npub use util::REQWEST_NO_REDIRECT as OB_STRICT_TLS_IDS_CLIENT;\npub use icloud_auth::ob_strict_tls_account_client;\n",
        "rustpush/apple-private-apis/icloud-auth/src/lib.rs": b"\npub use client::ob_strict_tls_account_client;\n",
        "rustpush/apple-private-apis/icloud-auth/src/client.rs": b"\n" + (TEMPLATES / "account_client.rs").read_bytes(),
    }
    originals = {relative: (root / relative).read_bytes() for relative in additions}
    try:
        for relative, extra in additions.items():
            (root / relative).write_bytes(originals[relative] + extra)
        binary_source.parent.mkdir(parents=True, exist_ok=True)
        binary_source.write_bytes((TEMPLATES / "main.rs").read_bytes())
        yield {relative: sha(root / relative) for relative in additions}
    finally:
        for relative, original in originals.items():
            (root / relative).write_bytes(original)
        if binary_source.exists():
            binary_source.unlink()  # Exact fixture created above, never a directory.


def command(argv: list[str], cwd: Path, out: Path, name: str, timeout: int) -> dict:
    began = time.monotonic()
    log = out / f"{name}.log"
    result = {"argv": argv, "timeout_seconds": timeout, "timed_out": False}
    with log.open("wb") as stream:
        process = subprocess.Popen(argv, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        result["pid"] = process.pid
        try:
            result["exit_code"] = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            result["timed_out"] = True
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=5)
            result["exit_code"] = process.returncode
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                result["process_group_reaped"] = True
            else:
                os.killpg(process.pid, signal.SIGKILL)
                result["process_group_reaped"] = False
            stream.flush()
            result["seconds"] = round(time.monotonic() - began, 3)
            result["log_sha256"] = sha(log)
            (out / f"{name}.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def elf(path: Path, machine: int) -> dict:
    with path.open("rb") as stream:
        header = stream.read(20)
    if (len(header) != 20 or header[:6] != b"\x7fELF\x02\x01" or
            struct.unpack_from("<H", header, 18)[0] != machine):
        raise RuntimeError("Unexpected console-binary ABI")
    return {"bytes": path.stat().st_size, "sha256": sha(path), "elf_machine": machine}


def observations(path: Path) -> list[dict]:
    entries = [json.loads(line) for line in path.read_text().splitlines() if line.startswith("{")]
    if len(entries) != 4 or entries[-1].get("anisette_provider_calls") != 0:
        raise RuntimeError("Unexpected probe count or Anisette invocation")
    if entries[-1].get("credentials_loaded") is not False:
        raise RuntimeError("Credential-free invariant missing")
    expected = ["www.google.com", "init.ess.apple.com", "gsa.apple.com"]
    if [entry.get("original_host") for entry in entries[:3]] != expected:
        raise RuntimeError("Unexpected probe host or ordering")
    return entries


def build_android_probe(root: Path, out: Path, target: Path, base: list[str]) -> dict:
    android = command(base + ["--target", TARGET], root, out, "android-build", 900)
    if android["exit_code"] != 0 or not android["process_group_reaped"]:
        raise RuntimeError("Android console build failed; inspect before retry")
    artifact = out / "ob_strict_tls_probe_android_arm64"
    shutil.copyfile(target / TARGET / "debug/ob_strict_tls_probe", artifact)
    binary = elf(artifact, 183)
    ndk_bin = Path(os.environ["CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER"]).parent
    inspect = command([str(ndk_bin / "llvm-readelf"), "-h", "-l", "-d", str(artifact)], root, out, "android-elf", 15)
    elf_text = (out / "android-elf.log").read_text()
    if (inspect["exit_code"] != 0 or not inspect["process_group_reaped"] or
            "/system/bin/linker64" not in elf_text or "libc.so.6" in elf_text):
        raise RuntimeError("Android interpreter or native dependencies not qualified")
    return {"android_binary": binary, "android_interpreter": "/system/bin/linker64"}


def run_platforms(root: Path, out: Path, target: Path, base: list[str],
                  receipt: dict, *, android_only: bool = False) -> int:
    receipt["linux_probe_executed"] = False
    if not android_only:
        host = command(base, root, out, "linux-build", 600)
        if host["exit_code"] != 0 or not host["process_group_reaped"]:
            raise RuntimeError("Linux build failed; inspect evidence before retry")
        host_binary = target / "debug/ob_strict_tls_probe"
        receipt["linux_binary"] = elf(host_binary, 62)
        run = command([str(host_binary)], root, out, "linux-probe", 30)
        receipt["linux_probe_executed"] = True
        receipt["linux_observations"] = observations(out / "linux-probe.log")
        receipt["linux_transport_passed"] = run["exit_code"] == 0 and run["process_group_reaped"]
        receipt["public_services_not_5xx"] = all(
            entry.get("strict_https") is True and 200 <= entry.get("http_status", 0) < 500
            for entry in receipt["linux_observations"][:3]
        )
        if receipt["linux_observations"][0].get("strict_https") is not True:
            raise RuntimeError("Direct-network Google control failed; skip ARM64 work")
    receipt.update(build_android_probe(root, out, target, base))
    if android_only:
        receipt["result"] = "android_artifact_ready_transport_unrun"
        return 0
    receipt["result"] = ("probe_and_artifact_ready" if receipt["linux_transport_passed"]
                         else "linux_transport_failed_android_artifact_ready")
    return 0 if receipt["linux_transport_passed"] else 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--android-only", action="store_true",
                        help="Build the ARM64 console only; no Linux binary or HTTPS request")
    args = parser.parse_args()
    root, out = args.source.resolve(), args.out.resolve()
    if os.name != "posix" or out.exists() or out == root or root in out.parents:
        raise RuntimeError("Requires Linux and a fresh evidence directory outside source")
    out.mkdir(parents=True)
    def interrupted(signum, _frame):
        raise RuntimeError(f"Diagnostic interrupted by signal {signum}")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    receipt = {"account_loaded": False, "apk_built": False, "android_executed": False,
               "android_build_only": args.android_only, "linux_probe_executed": False}
    began = time.monotonic()
    exit_code = 1
    try:
        receipt["before"] = verify_source(root)
        if shutil.disk_usage(root).free < 15 * 1024**3:
            raise RuntimeError("Disk below 15GiB guard")
        receipt["rustc"] = subprocess.check_output(["rustc", "--version"], text=True).strip()
        for name in ("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"):
            if os.environ.get(name):
                raise RuntimeError("Inherited proxy present; this lane is not direct-network")
        target = Path(os.environ.get("CARGO_TARGET_DIR", root / "rust/target")).resolve()
        fetch = command(["cargo", "fetch", "--locked", "--manifest-path", "rust/Cargo.toml"], root, out, "fetch", 300)
        if fetch["exit_code"] != 0 or not fetch["process_group_reaped"]:
            raise RuntimeError("Locked preparation failed; do not retry automatically")
        with overlay(root) as overlay_hashes:
            receipt["overlay_sha256"] = overlay_hashes
            for name in ("main.rs", "account_client.rs"):
                shutil.copyfile(TEMPLATES / name, out / name)
            base = ["cargo", "build", "--offline", "--locked", "--manifest-path", "rust/Cargo.toml", "--bin", "ob_strict_tls_probe"]
            exit_code = run_platforms(root, out, target, base, receipt,
                                      android_only=args.android_only)
        receipt["after"] = verify_source(root)
    except Exception as error:
        receipt["result"] = "failed"
        receipt["error"] = str(error)
        exit_code = 1
    finally:
        try:
            receipt["restored"] = verify_source(root)
        except Exception as error:
            receipt["restoration_error"] = str(error)
            exit_code = 1
        receipt["seconds"] = round(time.monotonic() - began, 3)
        receipt["free_bytes"] = shutil.disk_usage(root).free
        (out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        print(json.dumps(receipt))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
