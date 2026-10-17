"""Bounded, credential-free static iOS 15 activation inspection on an owned Mac.

Never executes Apple code, contacts an account/activation endpoint, accesses a
phone, reads a native private key, or retains firmware in the evidence artifact.
The only image attach is explicitly read-only. Output is hashes and selected
symbol/import facts, not Apple binaries or arbitrary data strings.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import tarfile
import tempfile
import time
import urllib.parse
import urllib.request


FIRMWARE = (
    "https://updates.cdn-apple.com/2023WinterFCS/fullrestores/042-45465/"
    "C67B609C-7B93-4607-8C82-DCBED1045EA1/"
    "iPhone_4.7_P3_15.7.9_19H365_Restore.ipsw"
)
IPSW_VERSION = "3.1.739"
ARCHIVES = {
    "arm64": ("ipsw_3.1.739_macOS_arm64.tar.gz",
              "c09e8eba02c332f5b50d15f94383e59dd35646d70f6ea9e78d185e9afda6abc2"),
    "x86_64": ("ipsw_3.1.739_macOS_x86_64.tar.gz",
               "7121fce3ff630077d7de0e3e6ff15f49876494b5d54b01f92a3c1787ebe23c0e"),
}
NATIVE_PATH = Path("usr/libexec/mobileactivationd")
INTERESTING = re.compile(
    r"wyjYwk|FairPlay|[Cc]reate.*[Aa]ctivation|[Ii]ssueClientCertificate|"
    r"[Cc]reate.*[Cc]ert.*[Rr]equest|NACSign|[Cc]ertifyDevice|[Rr]ecertify"
)
OWNED_PROCESSES = []


class CommandFailure(RuntimeError):
    def __init__(self, name, code, diagnostic):
        super().__init__(name + "-exit-" + str(code))
        text = diagnostic.decode(errors="replace")[-4096:]
        text = re.sub(r"https?://\S+", "[public-download-url]", text)
        text = re.sub(r"[A-Za-z0-9+/=_-]{60,}", "[redacted-long-token]", text)
        self.diagnostic = "\n".join(line[:180] for line in text.splitlines()[-8:])


def select_archive(machine):
    machine = {"aarch64": "arm64", "amd64": "x86_64"}.get(machine, machine)
    if machine not in ARCHIVES:
        raise ValueError("unsupported-host-architecture")
    return ARCHIVES[machine]


def validate_out_root(out, runner_temp):
    if not out.is_absolute() or not runner_temp.is_absolute():
        raise ValueError("absolute-owned-path-required")
    root, resolved = runner_temp.resolve(), out.resolve()
    if resolved == root or root not in resolved.parents or out.exists() or out.is_symlink():
        raise ValueError("fresh-output-under-runner-temp-required")
    return resolved


def extract_command(tool, output):
    # Extract the filesystem image only. Do not use ipsw's automatic mount path:
    # its pinned Darwin helper does not explicitly request a read-only attach.
    return [str(tool), "extract", "--remote", "--dmg", "fs", "--flat",
            "--output", str(output), FIRMWARE]


def readonly_attach_command(image, mount):
    return ["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
            "-plist", "-mountpoint", str(mount), str(image)]


def owned_images(raw_plist, work):
    root = work.resolve()
    devices = []
    for image in plistlib.loads(raw_plist).get("images", []):
        image_path = image.get("image-path")
        if not isinstance(image_path, str) or root not in Path(image_path).resolve().parents:
            continue
        for entry in image.get("system-entities", []):
            device = entry.get("dev-entry", "")
            if re.fullmatch(r"/dev/disk[0-9]+(?:s[0-9]+)*", device):
                devices.append(device)
    # Detach the whole image once, rather than its individual APFS containers.
    return sorted(set(devices), key=lambda value: (len(value), value))


def inspect_macho(path):
    if path.is_symlink() or not path.is_file() or not 32 <= path.stat().st_size <= 16 * 1024**2:
        raise ValueError("bounded-regular-native-file-required")
    data = path.read_bytes()
    magic, cpu = struct.unpack_from("<II", data)
    if magic != 0xFEEDFACF or cpu != 0x0100000C:
        raise ValueError("native-arm64-macho-required")
    return {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data),
            "architecture": "arm64", "executed": False}


class PublicRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        url = urllib.parse.urlparse(newurl)
        if url.scheme != "https" or url.hostname not in {
                "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"}:
            raise ValueError("unexpected-public-tool-redirect")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def download_tool(work):
    name, expected = select_archive(platform.machine())
    url = f"https://github.com/blacktop/ipsw/releases/download/v{IPSW_VERSION}/{name}"
    archive = work / name
    digest, size = hashlib.sha256(), 0
    opener = urllib.request.build_opener(PublicRedirects())
    with opener.open(url, timeout=30) as response, archive.open("xb") as output:
        while block := response.read(1024 * 1024):
            size += len(block)
            if size > 40 * 1024**2:
                raise ValueError("tool-download-size-limit")
            digest.update(block)
            output.write(block)
    if digest.hexdigest() != expected:
        raise ValueError("pinned-tool-checksum-mismatch")
    target = work / "ipsw"
    with tarfile.open(archive, "r:gz") as package:
        candidates = [entry for entry in package if entry.isfile()
                      and Path(entry.name).name == "ipsw" and 0 < entry.size < 128 * 1024**2]
        if len(candidates) != 1:
            raise ValueError("single-tool-executable-required")
        with package.extractfile(candidates[0]) as source, target.open("xb") as output:
            shutil.copyfileobj(source, output)
    target.chmod(0o700)
    return target


def run_owned(command, work, name, timeout, check=True):
    # Files avoid descendants holding captured stdout pipes open after exit.
    out, err = work / (name + ".out"), work / (name + ".err")
    env = os.environ.copy()
    env["TMPDIR"] = str(work / "tmp")
    with out.open("xb") as stdout, err.open("xb") as stderr:
        process = subprocess.Popen(command, cwd=work, env=env, stdin=subprocess.DEVNULL,
                                   stdout=stdout, stderr=stderr, start_new_session=True)
        OWNED_PROCESSES.append(process)
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError(name + "-timeout")
        finally:
            if not stop_owned(process):
                raise RuntimeError(name + "-owned-group-not-reaped")
    if out.stat().st_size + err.stat().st_size > 32 * 1024**2:
        raise RuntimeError(name + "-output-limit")
    if check and code != 0:
        raise CommandFailure(name, code, err.read_bytes())
    return code, out.read_bytes(), err.read_bytes()


def stop_owned(process):
    """Reap only a process group that this module created with start_new_session."""
    if process not in OWNED_PROCESSES or process.pid in (os.getpid(), os.getpgrp()):
        return False
    if getattr(process, "_ob_group_reaped", False):
        return process.returncode is not None

    def gone():
        process.poll()
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            if process.returncode is not None:
                process._ob_group_reaped = True
                return True
        return False

    if gone():
        return True
    for sig, grace in ((signal.SIGTERM, 25), (signal.SIGKILL, 5)):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + grace
        while time.monotonic() < deadline:
            if gone():
                return True
            time.sleep(0.1)
    return gone()


def disk_info(work, name):
    return run_owned(["/usr/bin/hdiutil", "info", "-plist"], work, name, 20)[1]


def inspect_on_mac(out):
    if platform.system() != "Darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("owned-github-macos-runner-required")
    if any(os.environ.get(key, "false") != "false" for key in ("OUTBOUND_WRITER", "AUTOMATIC_UPLOADS")):
        raise RuntimeError("inspection-requires-write-flags-off")
    temp = Path(os.environ["RUNNER_TEMP"]).resolve()
    out = validate_out_root(out, temp)
    out.mkdir(parents=True)
    work = Path(tempfile.mkdtemp(prefix="ob-iphone15-native-", dir=temp)).resolve()
    (work / "tmp").mkdir()
    report = {"schema": 1, "status": "failed", "goal": "iphone-relay-activation",
              "workflow_sha": os.environ.get("GITHUB_SHA"), "firmware": FIRMWARE,
              "expected_product": "iPhone9,1", "expected_version": "15.7.9",
              "expected_build": "19H365", "full_ipsw_sha256_verified": False,
              "accounts": 0, "activation_requests": 0, "phone_operations": 0,
              "native_private_keys_read": False, "binary_artifact_retained": False}
    started = time.monotonic()
    try:
        if shutil.disk_usage(temp).free < 14 * 1024**3:
            raise RuntimeError("insufficient-owned-runner-disk")
        tool = download_tool(work)
        images = work / "images"
        images.mkdir()
        run_owned(extract_command(tool, images), work, "extract-rootfs", 900)
        # --flat flattens ZIP members, but ipsw still adds its release folder.
        candidates = list(images.rglob("*.dmg"))
        if (len(candidates) != 1 or candidates[0].is_symlink()
                or images.resolve() not in candidates[0].resolve().parents):
            raise RuntimeError("single-rootfs-image-required")
        mount = work / "mount"
        mount.mkdir()
        run_owned(readonly_attach_command(candidates[0], mount), work, "attach-readonly", 120)
        report["mount_readonly_verified"] = bool(os.statvfs(mount).f_flag & os.ST_RDONLY)
        if not report["mount_readonly_verified"]:
            raise RuntimeError("readonly-mount-not-observed")
        # Verify the inspected filesystem belongs to the expected exact release.
        version_path = mount / "System/Library/CoreServices/SystemVersion.plist"
        version = plistlib.loads(version_path.read_bytes())
        if (version.get("ProductVersion"), version.get("ProductBuildVersion")) != ("15.7.9", "19H365"):
            raise RuntimeError("rootfs-release-mismatch")
        report["rootfs_release_verified"] = True
        native = mount / NATIVE_PATH
        if mount.resolve() not in native.resolve().parents:
            raise RuntimeError("native-path-escaped-owned-mount")
        report["native"] = inspect_macho(native)
        # Inspect a private copy only. No component is executed or exported.
        copied = work / "mobileactivationd"
        shutil.copyfile(native, copied)
        _, loads, _ = run_owned(["/usr/bin/otool", "-L", str(copied)], work, "native-loads", 60)
        nm_code, symbols, _ = run_owned(["/usr/bin/nm", "-nm", str(copied)], work, "native-symbols", 60,
                                        check=False)
        report["symbol_inventory_exit"] = nm_code
        report["loads"] = [line.strip() for line in loads.decode(errors="replace").splitlines()[1:80]]
        report["selected_symbols"] = [line for line in symbols.decode(errors="replace").splitlines()
                                      if INTERESTING.search(line)][:120]
        code, signature, signature_error = run_owned(
            ["/usr/bin/codesign", "--verify", "--strict", str(copied)], work, "signature-verify", 60,
            check=False)
        report["code_signature_verification_exit"] = code
        _, details, detail_error = run_owned(
            ["/usr/bin/codesign", "--display", "--verbose=4", str(copied)], work, "signature-details", 60)
        report["code_signature_facts"] = [line for line in (details + detail_error).decode(errors="replace").splitlines()
                                          if line.startswith(("Identifier=", "Format=", "CodeDirectory ",
                                                              "CDHash=", "Platform identifier=", "Authority="))]
        _, assembly, _ = run_owned(["/usr/bin/otool", "-tvV", str(copied)], work, "native-disassembly", 120)
        lines = assembly.decode(errors="replace").splitlines()
        windows = []
        for index, line in enumerate(lines):
            if "wyjYwk" in line and len(windows) < 8:
                windows.append(lines[max(0, index - 12):index + 5])
        report["fairplay_callsite_windows"] = windows
        report["status"] = "static-inspection-completed"
        report["signer_runtime_or_external_csr_proved"] = False
    except Exception as error:
        report["error_type"] = type(error).__name__
        # Only errors created by this file are retained, never arbitrary child output.
        if isinstance(error, (ValueError, RuntimeError)) and re.fullmatch(r"[a-z0-9-]+", str(error)):
            report["reason"] = str(error)
        if isinstance(error, CommandFailure):
            report["public_command_diagnostic"] = error.diagnostic
    finally:
        try:
            if not all(stop_owned(process) for process in OWNED_PROCESSES):
                raise RuntimeError("owned-process-group-remains")
            for index, device in enumerate(owned_images(disk_info(work, "cleanup-inventory"), work)):
                # First whole-image detach can also remove its child device entries.
                current = owned_images(disk_info(work, f"detach-check-{index}"), work)
                if device in current:
                    run_owned(["/usr/bin/hdiutil", "detach", device], work, f"detach-{index}", 45)
            remaining = owned_images(disk_info(work, "cleanup-final"), work)
            report["owned_images_detached"] = not remaining
            report["owned_process_groups_reaped"] = all(stop_owned(process) for process in OWNED_PROCESSES)
            if remaining or not report["owned_process_groups_reaped"]:
                raise RuntimeError("owned-image-remains-attached")
            # work was created uniquely beneath the actual RUNNER_TEMP; never delete out.
            if temp not in work.parents or not work.name.startswith("ob-iphone15-native-"):
                raise RuntimeError("cleanup-root-ownership-lost")
            shutil.rmtree(work)
            report["owned_work_removed"] = not work.exists()
        except Exception as error:
            report["cleanup_error_type"] = type(error).__name__
            report["status"] = "cleanup-failed"
        report["seconds"] = round(time.monotonic() - started, 3)
        (out / "inspection.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({key: report[key] for key in ("status", "seconds", "accounts", "activation_requests")}))
    return 0 if report["status"] == "static-inspection-completed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    raise SystemExit(inspect_on_mac(parser.parse_args().out))
