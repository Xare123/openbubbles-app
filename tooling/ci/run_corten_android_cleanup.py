"""Real Android owned-process cleanup only. No APK, account or Apple request."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import time

import run_corten_android_login_runtime as runtime


def qualified(booted, cleanup):
    return (booted is True and len(cleanup) == 3
            and len({item.get("pid") for item in cleanup}) == 3
            and all(type(item.get("pid")) is int and item["pid"] > 1
                    and item.get("exited") is True for item in cleanup))


def run(sdk, out):
    runtime.require(sys.platform == "linux", "Linux hosted runner required")
    out.mkdir(parents=True, exist_ok=False)
    report = {"app_tested": False, "account_access": False, "apple_requests": False,
              "booted": False, "runtime_sha256": hashlib.sha256(
                  Path(runtime.__file__).read_bytes()).hexdigest()}
    root = Path(os.environ["RUNNER_TEMP"]).resolve()
    work = Path(tempfile.mkdtemp(prefix="ob-android-cleanup-", dir=root)).resolve()
    runtime.require(work.parent == root, "owned work directory escaped runner temp")
    started = time.monotonic()
    runner = None
    try:
        runner = runtime.Runner(sdk.resolve(), out, work)
        server, emulator = runtime.boot_owned_runtime(runner, "on", True)
        logcat = runner.spawn("guest-log-stream", runtime.adb_command(
            sdk.resolve(), "logcat", "-v", "brief", "-T", "1", "AndroidRuntime:E", "*:S"))
        runner.adb("binder-final", "shell", "settings", "get", "global", "device_provisioned")
        runtime.require(all(p.poll() is None for p in (server, emulator, logcat)),
                        "owned runtime exited before cleanup")
        report["booted"] = True
        report["boot_seconds"] = round(time.monotonic() - started, 3)
    except Exception as error:
        report["failure"] = str(error)
    finally:
        before = time.monotonic()
        report["cleanup"] = runner.cleanup() if runner else []
        report["cleanup_seconds"] = round(time.monotonic() - before, 3)
        report["passed"] = qualified(report["booted"], report["cleanup"])
        # Retain a failed runtime's owned files if any process might still use
        # them. Never scan for or signal unrelated processes.
        if all(item["exited"] for item in report["cleanup"]):
            shutil.rmtree(work)
        report["owned_work_removed"] = not work.exists()
        report["seconds"] = round(time.monotonic() - started, 3)
        (out / "receipt.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report), flush=True)
    return 0 if report["passed"] and report["owned_work_removed"] else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    raise SystemExit(run(args.sdk, args.out.resolve()))
