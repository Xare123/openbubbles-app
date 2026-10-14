"""One bounded, blank-profile Android app launch. No accounts or private inputs."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time

from run_corten_android_login_build import check_apk

PACKAGE = "com.bluebubbles.messaging.cloudkitcanary"
SYSTEM_IMAGE = "system-images;android-30;google_apis;x86_64"
ADB_PORT, EMULATOR_PORT = 5039, 5558
TOTAL_SECONDS, BOOT_SECONDS = 900, 540
OUTPUT_LIMIT = 16 * 1024 * 1024


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def adb_command(sdk, *args, device=True):
    base = [str(sdk / "platform-tools/adb"), "-H", "127.0.0.1", "-P", str(ADB_PORT)]
    return base + (["-s", f"emulator-{EMULATOR_PORT}"] if device else []) + list(args)


def emulator_command(sdk, name, accel):
    require(accel in ("on", "off"), "acceleration must be explicit")
    return [str(sdk / "emulator/emulator"), "-avd", name, "-port", str(EMULATOR_PORT),
            "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot",
            "-gpu", "swiftshader", "-accel", accel, "-no-metrics", "-memory", "2048"]


def network_result(code, raw):
    events = []
    for line in raw.splitlines():
        try:
            event = json.loads(line)
            if isinstance(event, dict):
                events.append(event)
        except (ValueError, UnicodeDecodeError):
            pass
    public = next((x for x in events if x.get("step") == "public_network"), {})
    size = public.get("certificate_bytes")
    passed = (code == 0 and isinstance(size, int) and not isinstance(size, bool) and size > 0
              and any(x.get("step") == "complete" for x in events))
    return {"status": "PASS" if passed else "FAIL", "exit": code,
            "certificate_bytes": size, "executed_in_android": True,
            "account_access": False, "session_post": "UNRUN"}


def resolve_activity(raw):
    for line in raw.decode(errors="replace").splitlines():
        if re.fullmatch(re.escape(PACKAGE) + r"/[\w.$]+", line.strip()):
            return line.strip()
    raise RuntimeError("Canary launcher activity not resolved")


def app_result(maps, fds, db, logs, focused, stable):
    libraries = {name: name.encode() in maps for name in
                 ("libflutter.so", "librust_lib_bluebubbles.so", "libobjectbox-jni.so")}
    metadata = re.search(rb"objectbox/data\.mdb:(\d+):(\d+)", db)
    opened = b"objectbox/data.mdb" in maps or b"objectbox/data.mdb" in fds
    errors = bool(re.search(rb"FATAL EXCEPTION|UnsatisfiedLinkError|Unhandled Exception|"
                           rb"Failure during app initialization|SIGILL|dlopen failed|Failed to load dynamic library|"
                           rb"Failed to (?:open ObjectBox|setup ObjectBox|seed themes|"
                           rb"perform database migrations!|complete startup tasks!)", logs))
    ready = bool(metadata and int(metadata[1]) > 0 and opened)
    passed = bool(stable and focused and all(libraries.values()) and ready and not errors)
    return {"status": "PASS" if passed else "FAIL", "native_libraries": libraries,
            "objectbox_open": ready, "window_focused": focused, "pid_stable": stable,
            "startup_error_observed": errors, "authentication_tested": False}


def stop_owned(process):
    """Terminate only a group created with start_new_session, then verify exit."""
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, sig)
        except ProcessLookupError:
            break
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            continue
        # A parent may exit before descendants. Check the entire owned group.
        try:
            os.killpg(process.pid, 0)
        except ProcessLookupError:
            break
    process.poll()
    try:
        os.killpg(process.pid, 0)
        return False
    except ProcessLookupError:
        return process.returncode is not None


class Runner:
    def __init__(self, sdk, out, work):
        self.sdk, self.out, self.work = sdk, out, work
        self.deadline = time.monotonic() + TOTAL_SECONDS
        self.processes = []
        self.streams = []
        self.env = os.environ.copy()
        for var, name in (("ANDROID_USER_HOME", "android"), ("ANDROID_AVD_HOME", "avds"),
                          ("ANDROID_EMULATOR_HOME", "emulator"), ("TMPDIR", "tmp")):
            path = work / name
            path.mkdir()
            self.env[var] = str(path)
        self.env.update({"ANDROID_HOME": str(sdk), "ANDROID_SDK_ROOT": str(sdk),
                         "ANDROID_ADB_SERVER_PORT": str(ADB_PORT),
                         "ADB_SERVER_SOCKET": f"tcp:127.0.0.1:{ADB_PORT}",
                         "ADB_MDNS_AUTO_CONNECT": ""})

    def remaining(self, requested):
        seconds = min(requested, self.deadline - time.monotonic())
        require(seconds > 0, "15-minute runtime deadline exhausted")
        for _, path in self.streams:
            require(path.stat().st_size <= OUTPUT_LIMIT, "owned process log exceeded bound")
        return seconds

    def call(self, name, cmd, timeout=30, data=None, required=True):
        with tempfile.TemporaryFile(dir=self.work) as output:
            proc = subprocess.Popen([str(x) for x in cmd], env=self.env,
                stdin=subprocess.PIPE if data is not None else subprocess.DEVNULL,
                stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                proc.communicate(input=data, timeout=self.remaining(timeout))
            except BaseException:
                stop_owned(proc)
                raise
            output.seek(0)
            raw = output.read(OUTPUT_LIMIT + 1)
        require(len(raw) <= OUTPUT_LIMIT, (name or "command") + " output exceeded bound")
        if name:
            (self.out / (name + ".log")).write_bytes(raw)
        require(not required or proc.returncode == 0, f"{name or 'command'} exit {proc.returncode}")
        return proc.returncode, raw

    def adb(self, name, *args, **kwargs):
        return self.call(name, adb_command(self.sdk, *args), **kwargs)

    def spawn(self, name, cmd):
        path = self.out / (name + ".log")
        handle = path.open("wb")
        self.streams.append((handle, path))
        proc = subprocess.Popen(cmd, env=self.env, stdin=subprocess.DEVNULL,
                                stdout=handle, stderr=subprocess.STDOUT, start_new_session=True)
        self.processes.append(proc)
        return proc

    def cleanup(self):
        results = []
        for proc in reversed(self.processes):
            try:
                exited = stop_owned(proc)
                results.append({"pid": proc.pid, "exited": exited})
            except OSError as error:
                results.append({"pid": proc.pid, "exited": False, "error": str(error)})
        for handle, _ in self.streams:
            handle.close()
        return results


def qualify(args):
    require(sys.platform == "linux", "Linux runner required; no local emulator execution")
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    report = {"account_access": False, "hardware_input": False, "authentication": "UNRUN",
              "network": {"status": "UNRUN"}, "app": {"status": "UNRUN"}}
    start = time.monotonic()
    runner = None
    work_context = tempfile.TemporaryDirectory(prefix="ob-blank-android-", dir=os.environ["RUNNER_TEMP"])
    try:
        report["apk"] = check_apk(args.apk)
        require(args.network_probe.is_file() and not args.network_probe.is_symlink(), "network probe missing")
        sdk = args.sdk.resolve()
        require((sdk / "system-images/android-30/google_apis/x86_64").is_dir(), "pinned SDK image missing")
        avd = sdk / "cmdline-tools/latest/bin/avdmanager"
        require(avd.is_file(), "SDK latest avdmanager missing")
        for port in (ADB_PORT, EMULATOR_PORT, EMULATOR_PORT + 1):
            with socket.socket() as sock:
                sock.bind(("127.0.0.1", port))
        if args.accel == "on":
            require(os.access("/dev/kvm", os.R_OK | os.W_OK), "KVM unavailable; no software fallback")
        runner = Runner(sdk, out, Path(work_context.name))
        if args.accel == "on":
            runner.call("acceleration", [sdk / "emulator/emulator", "-accel-check"])
        runner.call("create-avd", [avd, "create", "avd", "-n", "ob-blank-login", "-p",
                    Path(runner.env["ANDROID_AVD_HOME"]) / "device", "-k", SYSTEM_IMAGE,
                    "-d", "pixel"], timeout=60, data=b"no\n")
        server = runner.spawn("adb-server", [str(sdk / "platform-tools/adb"), "-L",
                              f"tcp:localhost:{ADB_PORT}", "server", "nodaemon"])
        # Prove our loopback server is listening before a client can auto-start it.
        until = time.monotonic() + 10
        while True:
            require(server.poll() is None, "owned ADB server exited")
            try:
                with socket.create_connection(("127.0.0.1", ADB_PORT), timeout=1):
                    break
            except OSError:
                require(time.monotonic() < until, "owned ADB server failed to listen")
                time.sleep(0.2)
        emulator = runner.spawn("emulator", emulator_command(sdk, "ob-blank-login", args.accel))
        until = time.monotonic() + BOOT_SECONDS
        while True:
            require(server.poll() is None and emulator.poll() is None, "emulator or ADB exited during boot")
            try:
                code, raw = runner.adb(None, "shell", "getprop", "sys.boot_completed", timeout=10, required=False)
            except subprocess.TimeoutExpired:
                code, raw = 1, b""
            if code == 0 and raw.strip() == b"1":
                break
            require(time.monotonic() < until, "Android boot exceeded nine minutes")
            time.sleep(2)
        report["boot_seconds"] = round(time.monotonic() - start, 3)
        _, raw = runner.adb("guest-abi", "shell", "getprop", "ro.product.cpu.abi")
        require(raw.strip() == b"x86_64", "guest must be native x64, no ARM translation")
        # Boot property alone is insufficient. Binder and settings must respond.
        runner.adb("binder-packages", "shell", "cmd", "package", "list", "packages", timeout=20)
        runner.adb("binder-settings", "shell", "settings", "get", "global", "device_provisioned", timeout=20)
        runner.adb("install", "install", "--no-streaming", str(args.apk.resolve()), timeout=180)
        runner.adb("network-push", "push", str(args.network_probe.resolve()), "/data/local/tmp/ob-network", timeout=60)
        runner.adb("network-mode", "shell", "chmod", "700", "/data/local/tmp/ob-network")
        code, raw = runner.adb("android-public-network", "shell", "/data/local/tmp/ob-network", "network",
                               timeout=90, required=False)
        report["network"] = network_result(code, raw)
        # Continue app evidence even if the public network check failed.
        _, raw = runner.adb("activity", "shell", "cmd", "package", "resolve-activity", "--brief",
                            "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", PACKAGE)
        component = resolve_activity(raw)
        runner.adb("unlock-blank-emulator", "shell", "input", "keyevent", "82")
        runner.adb("launch", "shell", "am", "start", "-W", "-n", component, timeout=60)
        time.sleep(min(15, runner.remaining(15)))
        _, first = runner.adb("pid-first", "shell", "pidof", PACKAGE, required=False)
        time.sleep(min(5, runner.remaining(5)))
        _, second = runner.adb("pid-second", "shell", "pidof", PACKAGE, required=False)
        stable = bool(re.fullmatch(rb"\d+", second.strip()) and first.strip() == second.strip())
        require(stable, "Canary process absent or restarted")
        pid = second.strip().decode()
        _, windows = runner.adb("windows", "shell", "dumpsys", "window", "windows")
        focused = bool(re.search(rb"mCurrentFocus=[^\n]*" + PACKAGE.encode(), windows))
        _, maps = runner.adb("native-maps", "shell", "run-as", PACKAGE, "cat", f"/proc/{pid}/maps", required=False)
        _, fds = runner.adb("fds", "shell", "run-as", PACKAGE, "ls", "-l", f"/proc/{pid}/fd", required=False)
        _, db = runner.adb("database", "shell", "run-as", PACKAGE, "stat", "-c", "%n:%s:%b",
                            "app_flutter/objectbox/data.mdb", required=False)
        _, logs = runner.adb("startup-logcat", "logcat", "-d", "--pid=" + pid, "-v", "threadtime")
        report["app"] = app_result(maps, fds, db, logs, focused, stable)
        _, png = runner.adb(None, "exec-out", "screencap", "-p")
        require(png.startswith(b"\x89PNG\r\n\x1a\n"), "invalid screenshot")
        (out / "screen.png").write_bytes(png)
        code, _ = runner.adb("ui-dump", "shell", "uiautomator", "dump", "/data/local/tmp/ob-ui.xml", required=False)
        if code == 0:
            _, xml = runner.adb(None, "exec-out", "cat", "/data/local/tmp/ob-ui.xml", required=False)
            (out / "ui.xml").write_bytes(xml)
        report["visual_review"] = "PENDING"
        require(report["network"]["status"] == "PASS", "Android public Apple network failed")
        require(report["app"]["status"] == "PASS", "normal app startup not qualified; inspect evidence")
        report["result"] = "blank_app_qualified_not_authenticated"
    except Exception as error:
        report["result"], report["failure"] = "failed", str(error)
    finally:
        report["cleanup"] = runner.cleanup() if runner else []
        report["owned_processes_stopped"] = all(x["exited"] for x in report["cleanup"])
        if report["owned_processes_stopped"]:
            work_context.cleanup()
        else:
            report["result"] = "failed"
        report["seconds"] = round(time.monotonic() - start, 3)
        (out / "receipt.json").write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report), flush=True)
    return 0 if report["result"] == "blank_app_qualified_not_authenticated" else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("apk", "network-probe", "sdk", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--accel", choices=("on", "off"), required=True)
    raise SystemExit(qualify(parser.parse_args()))
