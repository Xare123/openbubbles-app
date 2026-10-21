"""Inspect only the APS identity factory in public iOS15 firmware, never run it.

This follows one real installed-app NULL result. No Ghidra/LLM, key reads,
entitlement changes, app build, device operation or Apple service request.
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
import tempfile
import time

import inspect_iphone_activation_native as owned

IMAGE = "/System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService"
ORIGINAL_FACTORY = "+[APSConnection copyIdentity]"
# Observed as addressed block pointers in run39524670643, not guessed selectors.
BLOCKS = {
    "___29+[APSConnection copyIdentity]_block_invoke": 0x1a2f43848,
    "___29+[APSConnection copyIdentity]_block_invoke.202": 0x1a2f43978,
}
EXPECTED_CACHE_SHA256 = "feb18dafcc76f6583b68575b34414f233749100430608624336c7112fbab39d7"
CACHE_PATHS = (
    "System/Library/Caches/com.apple.dyld/dyld_shared_cache_arm64",
    "System/Library/dyld/dyld_shared_cache_arm64",
)


def require_mode(environ):
    if (environ.get("NATIVE_APS_FACTORY_ANALYSIS", "false") != "true"
            or environ.get("NATIVE_CONTRACT_ANALYSIS", "false") != "false"
            or any(environ.get(key, "false") != "false"
                   for key in ("OUTBOUND_WRITER", "AUTOMATIC_UPLOADS"))):
        raise ValueError("isolated-aps-factory-mode-required")


def metadata_command(tool, cache):
    return [str(tool), "dyld", "macho", str(cache), IMAGE, "--objc"]


def factory_command(tool, cache, work, symbol):
    if symbol not in BLOCKS:
        raise ValueError("only-observed-aps-factory-blocks-permitted")
    # Only previously observed addresses after exact cache hash equality. This
    # avoids guessing local-symbol spellings or repeating the factory body.
    return [str(tool), "dyld", "disass", str(cache), "--vaddr", hex(BLOCKS[symbol]),
            "--cache", str(work / "aps-symbols.a2s")]


def select_metadata(raw):
    text = owned.ANSI_SEQUENCE.sub("", raw.decode("utf-8"))
    lines = text.splitlines()
    selected = []
    for i, line in enumerate(lines):
        if "copyIdentity" in line or re.search(r"@interface\s+APSConnection\b", line):
            selected.append({"line": i + 1, "text": line[:600]})
    if len(selected) > 24:
        raise ValueError("ambiguous-aps-method-metadata")
    return selected


def parse_factory(raw, symbol):
    if symbol not in BLOCKS:
        raise ValueError("only-observed-aps-factory-blocks-permitted")
    if len(raw) > 300000:
        raise ValueError("aps-factory-output-limit")
    text = owned.ANSI_SEQUENCE.sub("", raw.decode("utf-8"))
    rows = []
    for line in text.splitlines():
        match = owned.INSTRUCTION_LINE.fullmatch(line)
        if match:
            # This is public static code, not live account/device values.
            address = int(match[1], 16)
            if not 0x100000000 < address < 0x300000000 or len(match[4]) > 800:
                raise ValueError("aps-instruction-address-or-comment-limit")
            rows.append({"address": hex(address), "bytes": "".join(match[2].split()),
                         "mnemonic": match[3], "operands": match[4]})
    if not 1 <= len(rows) <= 1024:
        raise ValueError("bounded-aps-factory-instructions-required")
    if int(rows[0]["address"], 16) != BLOCKS[symbol]:
        raise ValueError("observed-block-entry-required")
    if any(int(b["address"], 16) != int(a["address"], 16) + 4 for a, b in zip(rows, rows[1:])):
        raise ValueError("contiguous-single-factory-required")
    return {"symbol_from_prior_reference": symbol, "instruction_count": len(rows), "instructions": rows,
            "executed": False, "cause_of_runtime_null_proved": False}


def cache_identity(cache, mount):
    if (cache.is_symlink() or not cache.is_file() or mount.resolve() not in cache.resolve().parents
            or not 32 * 1024**2 <= cache.stat().st_size <= 4 * 1024**3):
        raise ValueError("owned-bounded-regular-arm64-cache-required")
    digest = hashlib.sha256()
    with cache.open("rb") as stream:
        header = stream.read(16)
        if not header.startswith(b"dyld_v1") or header.rstrip(b"\x00 ").split()[-1] != b"arm64":
            raise ValueError("arm64-dyld-cache-header-required")
        digest.update(header)
        while block := stream.read(1024 * 1024):
            digest.update(block)
    if digest.hexdigest() != EXPECTED_CACHE_SHA256:
        raise ValueError("previously-observed-aps-cache-mismatch")
    return {"sha256": digest.hexdigest(), "bytes": cache.stat().st_size,
            "architecture": "arm64", "full_firmware_checksum_verified": False}


def inspect_on_mac(out):
    require_mode(os.environ)
    if platform.system() != "Darwin" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise ValueError("owned-github-macos-runner-required")
    temp = Path(os.environ["RUNNER_TEMP"]).resolve()
    out = owned.validate_out_root(out, temp)
    out.mkdir()
    work = Path(tempfile.mkdtemp(prefix="ob-aps-factory-", dir=temp)).resolve()
    (work / "tmp").mkdir()
    report = {"schema": 1, "status": "failed", "source_sha": os.environ.get("GITHUB_SHA"),
              "firmware": owned.FIRMWARE, "expected_version": "15.7.9", "expected_build": "19H365",
              "image": IMAGE, "targets": list(BLOCKS), "previous_factory_body_not_repeated": True,
              "prior_factory_run": 39524670643, "accounts": 0, "activation_requests": 0,
              "phone_operations": 0, "native_private_keys_read": False, "binary_artifact_retained": False,
              "runtime_null_cause_or_access_proved": False, "entitlements_changed": False}
    start = time.monotonic()
    try:
        if shutil.disk_usage(temp).free < 14 * 1024**3:
            raise ValueError("insufficient-owned-runner-disk")
        tool = owned.download_tool(work)
        images = work / "images"
        images.mkdir()
        owned.run_owned(owned.extract_command(tool, images), work, "extract-rootfs", 600)
        candidates = list(images.rglob("*.dmg"))
        if (len(candidates) != 1 or candidates[0].is_symlink()
                or images.resolve() not in candidates[0].resolve().parents):
            raise ValueError("single-rootfs-image-required")
        mount = work / "mount"
        mount.mkdir()
        owned.run_owned(owned.readonly_attach_command(candidates[0], mount), work, "attach-readonly", 120)
        report["mount_readonly_verified"] = bool(os.statvfs(mount).f_flag & os.ST_RDONLY)
        if not report["mount_readonly_verified"]:
            raise ValueError("readonly-mount-not-observed")
        version = plistlib.loads((mount / "System/Library/CoreServices/SystemVersion.plist").read_bytes())
        if (version.get("ProductVersion"), version.get("ProductBuildVersion")) != ("15.7.9", "19H365"):
            raise ValueError("rootfs-release-mismatch")
        report["rootfs_release_verified"] = True
        caches = [mount / path for path in CACHE_PATHS if (mount / path).is_file()]
        if len(caches) != 1:
            raise ValueError("single-arm64-cache-required")
        cache = caches[0]
        report["cache"] = cache_identity(cache, mount)
        _, metadata, _ = owned.run_owned(metadata_command(tool, cache), work, "aps-objc", 180)
        report["selected_objc_metadata"] = select_metadata(metadata)
        report["blocks"] = []
        for index, symbol in enumerate(BLOCKS):
            entry = {"symbol_from_prior_reference": symbol}
            report["blocks"].append(entry)
            code, assembly, error = owned.run_owned(factory_command(tool, cache, work, symbol),
                work, f"aps-block-{index}", 180, check=False)
            entry["disassembly_exit"] = code
            entry["stdout_bytes"] = len(assembly)
            entry["stdout_sha256"] = hashlib.sha256(assembly).hexdigest()
            if code != 0:
                raise owned.CommandFailure(f"aps-block-{index}", code, error)
            try:
                entry["code"] = parse_factory(assembly, symbol)
            except ValueError:
                entry["public_output_preview"] = [line[:400] for line in
                    owned.ANSI_SEQUENCE.sub("", assembly.decode(errors="replace")).splitlines()[:24]]
                raise
        report["status"] = "aps-factory-static-inspection-completed"
    except Exception as error:
        report["error_type"] = type(error).__name__
        if isinstance(error, (ValueError, RuntimeError)) and re.fullmatch(r"[a-z0-9-]+", str(error)):
            report["reason"] = str(error)
        if isinstance(error, owned.CommandFailure):
            report["public_command_diagnostic"] = error.diagnostic
    finally:
        try:
            if not all([owned.stop_owned(process) for process in owned.OWNED_PROCESSES]):
                raise RuntimeError("owned-process-group-remains")
            for i, device in enumerate(owned.owned_images(owned.disk_info(work, "cleanup-inventory"), work)):
                current = owned.owned_images(owned.disk_info(work, f"detach-check-{i}"), work)
                if device in current:
                    owned.run_owned(["/usr/bin/hdiutil", "detach", device], work, f"detach-{i}", 45)
            report["owned_images_detached"] = not owned.owned_images(owned.disk_info(work, "cleanup-final"), work)
            report["owned_process_groups_reaped"] = all([owned.stop_owned(p) for p in owned.OWNED_PROCESSES])
            if not report["owned_images_detached"] or not report["owned_process_groups_reaped"]:
                raise RuntimeError("owned-image-or-process-remains")
            if temp not in work.parents or not work.name.startswith("ob-aps-factory-"):
                raise RuntimeError("cleanup-root-ownership-lost")
            shutil.rmtree(work)
            report["owned_work_removed"] = not work.exists()
        except Exception as error:
            report["cleanup_error_type"] = type(error).__name__
            report["status"] = "cleanup-failed"
        report["seconds"] = round(time.monotonic() - start, 3)
        (out / "inspection.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({key: report[key] for key in ("status", "seconds", "accounts", "activation_requests")}))
    return 0 if report["status"] == "aps-factory-static-inspection-completed" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    raise SystemExit(inspect_on_mac(parser.parse_args().out))
