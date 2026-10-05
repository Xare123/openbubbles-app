#!/usr/bin/env python3
"""One reviewed preparation and one synthetic ARM64 application trial.

Adapted from reviewed cloud launcher AA for the existing ephemeral GCE runner.
Standard library only. No work at import time. Public subcommands require a
distinct request. No retries, reuse of an AVD, or receipt overwrite.
Resource monitoring is best-effort, not a filesystem quota.
"""
import argparse
import copy
import ctypes
import hashlib
import ipaddress
import json
import multiprocessing
import os
from pathlib import Path, PurePosixPath
import re
import resource
import signal
import socket
import stat
import subprocess
import threading
import time
import traceback
import urllib.error
import urllib.request
import ssl
import xml.etree.ElementTree as ET
import zipfile

HERE = Path(__file__).resolve().parent
SDK = Path(os.environ.get("OB_RUNTIME_SDK", "/workspace/toolchains/android-sdk"))
SOURCE = Path(os.environ.get("OB_RUNTIME_SOURCE", "/workspace/openbubbles-source-test"))
ROOT = Path(os.environ.get("OB_RUNTIME_ROOT", "/workspace/cache/runtime/ob-canary-802e92-GCE"))
RUN = HERE / "run"
AVD = "ob-canary-802e92-GCE"
SERIAL = "emulator-5556"
PKG = "com.bluebubbles.messaging.cloudkitcanary"
PACKAGE = "system-images;android-30;google_apis;x86_64"
IMAGE = SDK / "system-images/android-30/google_apis/x86_64"
ARCHIVE = Path(os.environ.get("OB_RUNTIME_IMAGE_ZIP", "/workspace/cache/downloads/x86_64-30_r16.zip"))
URL = "https://dl.google.com/android/repository/sys-img/google_apis/x86_64-30_r16.zip"
IMAGE_SIZE = 1438186618
IMAGE_SHA1 = "6ae21030eaadc041078444d3798e4b399f3e787d"
EXPANDED = 3442796119
METADATA = Path(os.environ.get("OB_RUNTIME_METADATA", "/workspace/cache/android-user/cache/sdkbin-1_706db414-sys-img2-4_xml"))
APK = Path(os.environ.get("OB_RUNTIME_APK", "/workspace/cache/artifacts/ob-802e92-artifact11226077330/openbubbles-canary-802e92-signed.apk"))
APK_SIZE = 454937123
APK_HASH = "2bec869d8611e5aa8ba4c667bae4b66884dbb1c53b7aeab23887382aff4bb967"
CERT = "0ea17c1b67581ca79660d33db45af0a36b71ea36a4cbafec5293d3ae80570d79"
SHA = "802e92ded7035c1153e930c9b43e671fa9c400d5"
PINS = {
    "rustpush": "5076fe684b8856886c295e99b623757d9cf6b754",
    "rustpush/apple-private-apis": "e2891c317e264dd0eb73e6bb87f0ef37714cc160",
    "rustpush/apple-private-apis/clearadi": "663f33f9d71b0df5436d04611755142df6db6a35",
    "rustpush/open-absinthe": "1f8dc73a311e7b4d94a868972a6816c8a2c14e44",
    "telephony_plus": "5210e940dd92ae371f8c74eaeb552d0704034244",
    "telephony_plus/android-smsmms": "36f34f482dd5546c929f448d746c3124875a4faa",
}
GiB = 1024**3
MiB = 1024**2
PORTS = {5038, 5556, 5557, 8554}


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def immutable(path, value):
    """O_EXCL is the attempt/replay boundary, including interrupted attempts."""
    with Path(path).open("x", encoding="utf-8") as f:
        json.dump(value, f, indent=2)
        f.write("\n")
        f.flush()
        os.fsync(f.fileno())


def clip(now, seconds, *deadlines):
    remaining = min([seconds] + [d - now for d in deadlines])
    require(remaining > 0, "deadline exhausted")
    return remaining


def resource_reasons(free, allocated, evidence, early=True):
    return [label for hit, label in [
        (free <= (6.5 if early else 6) * GiB, "free-space"),
        (allocated >= (7 if early else 8) * GiB, "AVD/TMP allocation"),
        (evidence >= (224 if early else 256) * MiB, "logs/evidence"),
    ] if hit]


def same_owner(saved, current):
    return bool(current) and all(saved.get(k) == current.get(k)
                                 for k in ("pid", "start", "uid", "pgid"))


def live_owner(owner):
    current = identity(owner["pid"])
    return same_owner(owner, current) and current["state"] != "Z"


def identity(pid):
    try:
        p = Path("/proc") / str(pid)
        fields = (p / "stat").read_text().rsplit(")", 1)[1].split()
        return dict(pid=int(pid), ppid=int(fields[1]), pgid=int(fields[2]),
                    start=int(fields[19]), uid=p.stat().st_uid, state=fields[0])
    except (FileNotFoundError, ProcessLookupError):
        return None


def descendants(owners):
    result = {p["pid"]: p for p in owners}
    candidates = []
    for p in Path("/proc").iterdir():
        if p.name.isdigit():
            try:
                item = identity(int(p.name))
                if item and item["uid"] == os.getuid():
                    candidates.append(item)
            except PermissionError:
                pass
    changed = True
    while changed:
        changed = False
        for item in candidates:
            parent = result.get(item["ppid"])
            if (item["pid"] not in result and parent
                    and same_owner(parent, identity(parent["pid"]))
                    and item["start"] >= parent["start"]):
                result[item["pid"]] = item
                changed = True
    return list(result.values())


def session_owners(parent, excluded, owners):
    # A process-local subreaper retains ancestry of daemonized SDK children.
    return [p for p in descendants([parent, *owners])
            if p["pid"] != parent["pid"] and p["pid"] not in excluded]


def terminate(owners, sig):
    # Individual validated PIDs avoid signaling an unverified/reused group.
    for owner in reversed(owners):
        current = identity(owner["pid"])
        if same_owner(owner, current) and current["state"] != "Z":
            try:
                os.kill(owner["pid"], sig)
            except ProcessLookupError:
                pass


def tree_bytes(path):
    """Allocated blocks, counting hardlinks once, never following symlinks."""
    total, seen = 0, set()
    if not path.exists():
        return 0
    for base, dirs, files in os.walk(path, followlinks=False):
        for p in [Path(base)] + [Path(base) / f for f in files]:
            try:
                st = p.lstat()
            except FileNotFoundError:
                continue
            key = (st.st_dev, st.st_ino)
            if key not in seen:
                seen.add(key)
                total += st.st_blocks * 512
        dirs[:] = [d for d in dirs if not (Path(base) / d).is_symlink()]
    return total


def free_bytes():
    v = os.statvfs("/workspace")
    return v.f_bavail * v.f_frsize


def check_file(path, size, algorithm, expected):
    require(path.is_file() and not path.is_symlink(), "missing or symlinked artifact")
    require(path.stat().st_size == size, "artifact size mismatch")
    h = hashlib.new(algorithm)
    with path.open("rb") as f:
        while block := f.read(MiB):
            h.update(block)
    require(h.hexdigest() == expected, "artifact hash mismatch")
    return h.hexdigest()


def zip_plan(entries, expected_total):
    seen, total = set(), 0
    for item in entries:
        p = PurePosixPath(item.filename)
        mode = item.external_attr >> 16
        require(not p.is_absolute() and "\\" not in item.filename
                and ".." not in p.parts and p.parts
                and p.parts[0] == "x86_64", "unsafe ZIP path")
        require(str(p) not in seen, "duplicate ZIP path")
        seen.add(str(p))
        kind = stat.S_IFMT(mode)
        require(kind in (0, stat.S_IFREG, stat.S_IFDIR)
                and not mode & 0o7000 and not item.flag_bits & 1, "unsafe ZIP mode/encryption")
        require(not item.is_dir() or kind in (0, stat.S_IFDIR), "ZIP type mismatch")
        total += item.file_size
        require(total <= expected_total, "ZIP expansion exceeds bound")
    require(total == expected_total, "ZIP expansion mismatch")


def redact(text):
    text = re.sub(r"(https?://)[^/\s@]+@", r"\1[redacted]@", text)
    text = re.sub(r"(https?://[^\s?]+)\?[^\s]+", r"\1?[redacted]", text)
    return re.sub(r"(?i)((?:proxy-)?authorization|password|secret|access_token)\s*[:=]\s*\S+",
                  r"\1=[redacted]", text)


def listeners():
    rows = []
    for name, ipv6 in (("tcp", False), ("tcp6", True)):
        for line in (Path("/proc/net") / name).read_text().splitlines()[1:]:
            f = line.split()
            if f[3] != "0A":
                continue
            addr, port = f[1].split(":")
            b = bytes.fromhex(addr)
            b = b"".join(b[i:i+4][::-1] for i in range(0, len(b), 4))
            rows.append(dict(address=str(ipaddress.ip_address(b)), port=int(port, 16),
                             inode=f[9], uid=int(f[7])))
    return rows


def socket_inodes(owner):
    if not same_owner(owner, identity(owner["pid"])):
        return set()
    result = set()
    for f in (Path("/proc") / str(owner["pid"]) / "fd").iterdir():
        try:
            link = os.readlink(f)
            if link.startswith("socket:["):
                result.add(link[8:-1])
        except FileNotFoundError:
            pass
    return result


def owned_listeners(owners):
    inodes = set()
    for p in owners:
        try:
            inodes.update(socket_inodes(p))
        except (FileNotFoundError, ProcessLookupError):
            pass
    return [r for r in listeners() if r["inode"] in inodes]


def outside_writable_bytes(owners):
    """Count writable regular FDs outside our trees, including unlinked files."""
    total, seen = 0, set()
    for owner in owners:
        if not live_owner(owner):
            continue
        proc = Path("/proc") / str(owner["pid"])
        try:
            fds = list((proc/"fd").iterdir())
        except FileNotFoundError:
            continue
        for fd in fds:
            try:
                info = (proc/"fdinfo"/fd.name).read_text()
                flags = int(re.search(r"(?m)^flags:\s+([0-7]+)", info)[1], 8)
                st = fd.stat()
                if not flags & 3 or not stat.S_ISREG(st.st_mode):
                    continue
                target = os.readlink(fd)
                if st.st_nlink and any(target.startswith(str(p)+"/") for p in (ROOT, HERE)):
                    continue  # Already charged to the AVD or evidence tree.
                key = (st.st_dev, st.st_ino)
                if key not in seen:
                    seen.add(key)
                    total += st.st_blocks * 512
            except FileNotFoundError:
                pass
    return total


def watchdog_error_detail(stage, exc):
    def clean(value, limit):
        text = re.sub(r"(?im)((?:proxy-)?authorization|password|secret|access_token)\s*[:=][^\r\n]*",
                      r"\1=[redacted]", str(value))
        return redact(text)[:limit]

    filename = getattr(exc, "filename", None)
    return dict(stage=clean(stage, 128), type=type(exc).__name__,
                errno=getattr(exc, "errno", None),
                filename=clean(filename, 2048) if filename is not None else None,
                error=clean(exc, 1000),
                traceback=clean("".join(traceback.format_exception(
                    type(exc), exc, exc.__traceback__, limit=8, chain=False)), 8192))


def watchdog(parent, conn, phase, work_end, hard_end, stop):
    """Independent process: can stop children even if the main thread hangs."""
    os.setsid()
    stage, fatal_error = "initial_free_bytes", None
    owners, peaks, reason = [], dict(avd=0, evidence=0, free_min=free_bytes()), None
    stopping_at = None
    try:
        while True:
            stage = "receipt_messages"
            while conn.poll():
                message = conn.recv()
                if message == "finished":
                    return
                owners.append(message)
            stage = "session_owners"
            owners = session_owners(parent, {os.getpid()}, owners)
            stage = "monotonic"
            now = time.monotonic()
            stage = "outside_writable_bytes"
            outside = outside_writable_bytes([parent, *owners])
            stage = "tree_bytes.runtime"
            avd = tree_bytes(ROOT)+outside
            stage = "tree_bytes.evidence"
            evidence = tree_bytes(HERE)
            stage = "free_bytes"
            sizes = dict(avd=avd, evidence=evidence, free=free_bytes())
            peaks["outside_writable_files"] = max(peaks.get("outside_writable_files", 0), outside)
            peaks["avd"] = max(peaks["avd"], sizes["avd"])
            peaks["evidence"] = max(peaks["evidence"], sizes["evidence"])
            peaks["free_min"] = min(peaks["free_min"], sizes["free"])
            stage = "resource_reasons"
            issues = resource_reasons(sizes["free"], sizes["avd"], sizes["evidence"])
            stage = "stop_flag"
            if stop.is_set() and stopping_at is None:
                issues.append("bounded sink or command stop")
            stage = "owned_listeners"
            live = owned_listeners(owners)
            stage = "listener_loopback"
            if any(not ipaddress.ip_address(r["address"]).is_loopback for r in live):
                issues.append("non-loopback owned TCP listener")
            stage = "work_deadline"
            if now >= work_end:
                issues.append("work deadline")
            stage = "parent_identity"
            if not same_owner(parent, identity(parent["pid"])):
                issues.append("parent gone")
            if issues and stopping_at is None:
                reason = "; ".join(issues)
                stopping_at = now
                stop.set()
                stage = "terminate_owned_TERM"
                terminate(owners, signal.SIGTERM)
            stage = "cleanup_deadline"
            if stopping_at is not None and now >= stopping_at + 5:
                stage = "terminate_owned_KILL"
                terminate(owners, signal.SIGKILL)
            stage = "parent_and_owned_liveness"
            if not same_owner(parent, identity(parent["pid"])) and not any(live_owner(p) for p in owners):
                return
            stage = "hard_deadline"
            if now >= hard_end:
                stage = "hard_stop_owned_KILL"
                terminate(owners, signal.SIGKILL)
                stage = "hard_stop_parent_identity"
                if same_owner(parent, identity(parent["pid"])):
                    stage = "hard_stop_parent_KILL"
                    os.kill(parent["pid"], signal.SIGKILL)
                return
            stage = "poll_interval"
            time.sleep(.25)
    except BaseException as e:
        fatal_error = watchdog_error_detail(stage, e)
        reason = "watchdog error: " + type(e).__name__
        stop.set()
        terminate(descendants(owners), signal.SIGKILL)
        # Loss of observability must not remove the hard lifetime guard.
        while time.monotonic() < hard_end and same_owner(parent, identity(parent["pid"])):
            if conn.poll() and conn.recv() == "finished":
                break
            time.sleep(.1)
        if time.monotonic() >= hard_end and same_owner(parent, identity(parent["pid"])):
            os.kill(parent["pid"], signal.SIGKILL)
    finally:
        immutable(RUN / (phase + ".watchdog.json"),
                  dict(phase=phase, peaks=peaks, stop_reason=reason,
                       fatal_error=fatal_error, last_stage=stage,
                       overshoot=resource_reasons(peaks["free_min"], peaks["avd"], peaks["evidence"], False),
                       owners=owners))


class Session:
    def __init__(self, phase, request):
        for p in (ROOT, RUN, IMAGE, ARCHIVE):
            require(p.resolve() == p, "symlinked output root")
        RUN.mkdir(exist_ok=True)
        immutable(RUN / (phase + ".attempt.json"),
                  dict(phase=phase, request=request, pid=os.getpid(), source=SHA,
                       helper_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                       started_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())))
        self.phase, self.start = phase, time.monotonic()
        self.hard = self.start + (1500 if phase == "trial" else 900)
        self.work = self.hard - 30
        self.owners, self.jobs, self.commands = [], [], []
        self.observations = {}
        require(ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0) == 0,
                "Linux process-local child-subreaper unavailable")
        self.parent = identity(os.getpid())
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))  # No unbounded host core files.
        self.stop = multiprocessing.Event()
        self.send, receive = multiprocessing.Pipe()
        self.watch = multiprocessing.Process(target=watchdog,
            args=(identity(os.getpid()), receive, phase, self.work, self.hard, self.stop))
        self.watch.start()
        self.watch_owner = identity(self.watch.pid)
        self.lock, self.written = threading.Lock(), tree_bytes(HERE)
        self.counter = 0
        self.env = os.environ.copy()
        self.env.update(ANDROID_HOME=str(SDK), ANDROID_SDK_ROOT=str(SDK),
            JAVA_HOME=os.environ.get("JAVA_HOME", "/workspace/toolchains/jdk-21.0.12.1"), ANDROID_USER_HOME=str(ROOT / "user"),
            ANDROID_AVD_HOME=str(ROOT / "avd-index"), ANDROID_EMULATOR_HOME=str(ROOT / "emulator-home"),
            TMPDIR=str(ROOT / "tmp"), XDG_CACHE_HOME=str(ROOT / "cache"),
            XDG_CONFIG_HOME=str(ROOT / "config"), ANDROID_ADB_SERVER_PORT="5038",
            ADB_SERVER_SOCKET="tcp:127.0.0.1:5038", ADB_MDNS_AUTO_CONNECT="",
            GIT_OPTIONAL_LOCKS="0")
        # Emulator documents lowercase http_proxy; preserve the inherited route.
        if not self.env.get("http_proxy") and self.env.get("HTTP_PROXY"):
            self.env["http_proxy"] = self.env["HTTP_PROXY"]
        self.adb_server = None

    def check(self):
        require(not self.stop.is_set() and self.watch.is_alive(), "watchdog stopped work")
        clip(time.monotonic(), 1, self.work)
        require(not resource_reasons(free_bytes(), tree_bytes(ROOT), tree_bytes(HERE)), "resource early stop")

    def write(self, f, block):
        with self.lock:
            if self.written + len(block) > 224 * MiB:
                self.stop.set()
                raise RuntimeError("bounded evidence sink reached early cap")
            f.write(block)
            self.written += len(block)

    def spawn(self, cmd, label, binary=False, input_bytes=None, limit=8*MiB):
        self.check()
        self.counter += 1
        paths = [RUN / f"{self.phase}-{self.counter:02d}-{label}.{suffix}"
                 for suffix in ("bin" if binary else "out", "err")]
        p = subprocess.Popen([str(x) for x in cmd], env=self.env, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, stdin=subprocess.PIPE if input_bytes else subprocess.DEVNULL,
                             start_new_session=True)
        owner = identity(p.pid)
        require(owner and owner["pgid"] == p.pid and owner["uid"] == os.getuid(), "unexpected process ownership")
        self.owners.append(owner)
        self.send.send(owner)
        buffers = [bytearray(), bytearray()]

        def drain(pipe, path, buf, is_binary):
            try:
                with path.open("xb") as f:
                    while block := pipe.read(4096) if is_binary else pipe.readline(65537):
                        if not is_binary:
                            block = (b"[oversize line redacted]\n" if len(block) > 65536
                                     else redact(block.decode("utf-8", "replace")).encode())
                        if len(buf) + len(block) > limit:
                            self.stop.set()
                            raise RuntimeError("command output cap")
                        self.write(f, block)
                        buf.extend(block)
            except BaseException:
                self.stop.set()
            finally:
                pipe.close()

        threads = [threading.Thread(target=drain, args=(pipe, path, buf, binary and i == 0), daemon=True)
                   for i, (pipe, path, buf) in enumerate(zip((p.stdout, p.stderr), paths, buffers))]
        for t in threads:
            t.start()
        if input_bytes:
            try:
                p.stdin.write(input_bytes)
            except BrokenPipeError:
                pass
            finally:
                p.stdin.close()
        job = (p, owner, threads, buffers)
        self.jobs.append(job)
        self.commands.append(dict(command=[str(x) for x in cmd], label=label, owner=owner,
                                  output=[str(x) for x in paths], started=time.monotonic()-self.start))
        return job

    def command(self, cmd, label, seconds=30, deadline=None, ok=True, **kw):
        end = time.monotonic() + clip(time.monotonic(), seconds, self.work, deadline or self.work)
        job = self.spawn(cmd, label, **kw)
        p, owner, threads, buffers = job
        while p.poll() is None:
            if self.stop.is_set() or time.monotonic() >= end:
                terminate(descendants([owner]), signal.SIGTERM)
                try:
                    p.wait(timeout=min(2, max(.01, self.hard-time.monotonic())))
                except subprocess.TimeoutExpired:
                    terminate(descendants([owner]), signal.SIGKILL)
                raise RuntimeError("command deadline or watchdog stop: " + label)
            time.sleep(.1)
        for t in threads:
            t.join(timeout=1)
        require(not any(t.is_alive() for t in threads), "output drain incomplete")
        self.check()
        self.commands[-1].update(exit_code=p.returncode, finished=time.monotonic()-self.start)
        require(not ok or p.returncode == 0, "command failed: " + label)
        return p.returncode, bytes(buffers[0])

    def adb(self, args, label, **kw):
        require(self.adb_server and self.adb_server[0].poll() is None
                and same_owner(self.adb_server[1], identity(self.adb_server[0].pid)), "owned ADB server not alive")
        require(any(r["port"] == 5038 for r in owned_listeners([self.adb_server[1]])), "ADB socket not owned")
        return self.command([SDK/"platform-tools/adb", "-H", "127.0.0.1", "-P", "5038",
                             "-s", SERIAL, *args], label, **kw)

    def finish(self, report):
        owners = session_owners(self.parent, {self.watch.pid}, self.owners)
        terminate(owners, signal.SIGTERM)
        end = min(time.monotonic() + 5, self.hard-2)
        while time.monotonic() < end and any(p.poll() is None for p, *_ in self.jobs):
            time.sleep(.1)
        owners = session_owners(self.parent, {self.watch.pid}, owners)
        terminate(owners, signal.SIGKILL)
        for p, _, threads, _ in self.jobs:
            try:
                p.wait(timeout=max(.01, min(1, self.hard-time.monotonic())))
            except subprocess.TimeoutExpired:
                pass
            for t in threads:
                t.join(timeout=.1)
        for owner in owners:
            try:
                os.waitpid(owner["pid"], os.WNOHANG)
            except ChildProcessError:
                pass
        self.send.send("finished")
        self.watch.join(timeout=max(.01, min(2, self.hard-time.monotonic())))
        if self.watch.is_alive():
            terminate([self.watch_owner], signal.SIGTERM)
            self.watch.join(timeout=.5)
        monitor_path = RUN / (self.phase + ".watchdog.json")
        monitor = json.loads(monitor_path.read_text()) if monitor_path.exists() else {}
        remaining = [x for x in owners if live_owner(x)]
        final_ports = [r for r in listeners() if r["port"] in PORTS]
        report.update(commands=self.commands, monitor=monitor, remaining_owned_processes=remaining,
                      observations=self.observations,
                      final_listeners=final_ports,
                      elapsed_seconds=round(time.monotonic()-self.start, 3), free_bytes=free_bytes(),
                      allocated_avd_bytes=tree_bytes(ROOT), evidence_bytes=tree_bytes(HERE),
                      cleanup_verified=bool(monitor) and not remaining and not self.watch.is_alive()
                          and (self.phase != "trial" or not final_ports))
        if (not report["cleanup_verified"] or monitor.get("stop_reason")
                or resource_reasons(report["free_bytes"], report["allocated_avd_bytes"], report["evidence_bytes"], False)):
            report["outcome_before_final_guards"] = report["result"]
            report["result"] = "stopped_by_watchdog_or_cleanup_guard"
        immutable(RUN / (self.phase + ".result.json"), report)


def properties(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines()
                if "=" in line and not line.startswith("#"))


def validate_image(path):
    p = properties(path / "source.properties")
    require(all(p.get(k) == v for k, v in {"Pkg.Revision":"16", "AndroidVersion.ApiLevel":"30",
                "SystemImage.Abi":"x86_64", "SystemImage.TagId":"google_apis"}.items()), "image identity mismatch")


def preflight(s):
    require(os.environ.get("GITHUB_ACTIONS") == "true", "GCE Actions runtime only")
    _, head = s.command(["git", "-C", SOURCE, "rev-parse", "HEAD"], "source")
    require(head.decode().strip() == SHA, "source mismatch")
    _, dirty = s.command(["git", "-C", SOURCE, "status", "--porcelain", "--untracked-files=no"], "source-status")
    require(not dirty.strip(), "tracked source changes")
    _, pins = s.command(["git", "-C", SOURCE, "submodule", "status", "--recursive"], "pins")
    actual = {}
    for line in pins.decode().splitlines():
        require(line.startswith(" "), "uninitialized or changed submodule")
        sha, name, *_ = line.split()
        actual[name] = sha
    require(actual == PINS, "submodule pins mismatch")
    check_file(APK, APK_SIZE, "sha256", APK_HASH)
    _, cert = s.command([SDK/"build-tools/35.0.0/apksigner", "verify", "--verbose", "--print-certs", APK], "signature")
    require(CERT in cert.decode() and "v2): true" in cert.decode() and "v3): true" in cert.decode(), "signature mismatch")
    _, manifest = s.command([SDK/"build-tools/35.0.0/aapt", "dump", "badging", APK], "apk-manifest")
    package = re.search(rb"package: name='([^']+)' versionCode='([^']+)' versionName='([^']*)'", manifest)
    require(package and package[1].decode() == PKG, "APK manifest identity mismatch")
    return dict(version_code=package[2].decode(), version_name=package[3].decode())


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *unused):
        return None


def prepare(s):
    require(not ROOT.exists() and not IMAGE.exists() and not ARCHIVE.exists(), "preserve existing runtime/image/archive; no overwrite")
    require(free_bytes() > 6*GiB + 14007954554, "preparation disk budget unavailable")
    for name in ("user", "avd-index", "emulator-home", "tmp", "cache", "config"):
        (ROOT/name).mkdir(parents=True, exist_ok=False)
    candidate = preflight(s)
    xml = ET.parse(METADATA).getroot()
    remote = next(p for p in xml.findall("remotePackage") if p.get("path") == PACKAGE)
    complete = remote.find("archives/archive/complete")
    require(remote.findtext("revision/major") == "16"
            and int(complete.findtext("size")) == IMAGE_SIZE
            and complete.findtext("checksum") == IMAGE_SHA1
            and complete.find("checksum").get("type") == "sha1"
            and complete.findtext("url") == "x86_64-30_r16.zip"
            and "arm64-v8a" in [e.text for e in remote.findall("type-details/abis")], "cached official metadata mismatch")
    # GCE's normal route need not have a managed proxy. Never unset a configured
    # proxy or CA: urllib and create_default_context preserve the host's route.
    ca = os.environ.get("REQUESTS_CA_BUNDLE") or os.environ.get("SSL_CERT_FILE")
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=ca)),
                                        NoRedirect())
    partial = ARCHIVE.with_suffix(".zip.partial-GCE")
    require(not partial.exists(), "preserve previous partial archive")
    sha1, sha256, count = hashlib.sha1(), hashlib.sha256(), 0
    download_start = time.monotonic()
    download = dict(url=URL, attempts=1, bytes=0, whole_hash_verified=False)
    s.observations["image_download"] = download
    # Exactly one request; no alternate redirects/endpoints or retries.
    with opener.open(URL, timeout=30) as response, partial.open("xb") as dst:
        download.update(http_status=response.status, declared_bytes=response.headers.get("Content-Length"))
        require(response.status == 200 and int(response.headers.get("Content-Length", -1)) == IMAGE_SIZE, "image HTTP status/size mismatch")
        while block := response.read(MiB):
            s.check()
            count += len(block)
            require(count <= IMAGE_SIZE, "download size cap")
            dst.write(block)
            sha1.update(block)
            sha256.update(block)
            download.update(bytes=count, seconds=round(time.monotonic()-download_start, 3))
    download.update(sha1=sha1.hexdigest(), sha256=sha256.hexdigest())
    require(count == IMAGE_SIZE and sha1.hexdigest() == IMAGE_SHA1, "whole image ZIP verification failed")
    download["whole_hash_verified"] = True
    require(not ARCHIVE.exists(), "archive destination appeared")
    partial.rename(ARCHIVE)
    stage = ROOT/"tmp/image-stage"
    stage.mkdir()
    files = []
    with zipfile.ZipFile(ARCHIVE) as z:
        zip_plan(z.infolist(), EXPANDED)
        for item in z.infolist():
            s.check()
            target = stage / item.filename
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            digest = hashlib.sha256()
            with z.open(item) as src, target.open("xb") as dst:
                while block := src.read(MiB):  # Reading to EOF validates CRC.
                    s.check()
                    digest.update(block)
                    dst.write(block)
            mode = (item.external_attr >> 16) & 0o755 or 0o644
            target.chmod(mode)
            files.append(dict(name=item.filename.removeprefix("x86_64/"), bytes=item.file_size,
                              sha256=digest.hexdigest(), mode=mode))
    new = stage/"x86_64"
    validate_image(new)
    local = copy.deepcopy(remote)
    local.tag = "localPackage"
    for tag in ("archives", "channelRef"):
        element = local.find(tag)
        if element is not None:
            local.remove(element)
    # Preserve official license/type metadata; do not touch other registrations.
    repo = ET.Element("common:repository", {
        "xmlns:common":"http://schemas.android.com/repository/android/common/02",
        "xmlns:sys-img":"http://schemas.android.com/sdk/android/repo/sys-img2/04"})
    license_id = local.find("uses-license").get("ref")
    repo.append(copy.deepcopy(next(e for e in xml.findall("license") if e.get("id") == license_id)))
    repo.append(local)
    (new/"package.xml").write_bytes(ET.tostring(repo, encoding="utf-8", xml_declaration=True))
    require(not IMAGE.exists(), "new image destination appeared; stop")
    IMAGE.parent.mkdir(parents=True, exist_ok=True)
    new.rename(IMAGE)
    s.command([SDK/"cmdline-tools/latest/bin/avdmanager", "create", "avd", "-n", AVD,
               "-p", ROOT/"avd", "-k", PACKAGE, "-d", "pixel"], "avd-create", seconds=60, input_bytes=b"no\n")
    config = ROOT/"avd/config.ini"
    old = dict((k.strip(), v.strip()) for k, v in properties(config).items())
    require(old.get("tag.id") == "google_apis" and old.get("abi.type") == "x86_64", "AVD identity mismatch")
    old.update({"hw.cpu.ncore":"2", "hw.ramSize":"2048", "hw.lcd.width":"480", "hw.lcd.height":"800",
                "hw.lcd.density":"240", "disk.dataPartition.size":"2G", "hw.sdCard":"no",
                "showDeviceFrame":"no", "fastboot.forceColdBoot":"yes", "fastboot.forceFastBoot":"no",
                "hw.gpu.enabled":"yes", "hw.gpu.mode":"swiftshader"})
    config.write_text("".join(f"{k}={v}\n" for k, v in old.items()))
    s.check()
    return dict(result="prepared_not_booted", candidate=candidate, image_zip_sha1=sha1.hexdigest(),
                image_zip_sha256=sha256.hexdigest(), image_files=files, zip_crc_verified=True,
                package_xml_sha256=hashlib.sha256((IMAGE/"package.xml").read_bytes()).hexdigest(),
                config_sha256=hashlib.sha256(config.read_bytes()).hexdigest())


def startup_log_assessment(logs):
    later = b"Startup tasks completed" in logs
    errors = bool(re.search(
        rb"Failed to (?:open ObjectBox|setup ObjectBox|seed themes|perform database migrations!|complete startup tasks!)"
        rb"|Failure during app initialization|FATAL EXCEPTION|SIGILL|UnsatisfiedLinkError|dlopen failed|Failed to load dynamic library", logs))
    return later, errors


def trial(s):
    prepared = json.loads((RUN/"prepare.result.json").read_text())
    require(prepared.get("result") == "prepared_not_booted" and prepared.get("cleanup_verified"), "preparation not complete")
    require(not any(r["port"] in PORTS for r in listeners()), "selected TCP ports already in use")
    for p in Path("/proc").iterdir():
        if p.name.isdigit():
            try:
                name = (p/"comm").read_text().strip()
                require(name != "adb" and name != "emulator" and not name.startswith("qemu-system"), "existing Android process")
            except FileNotFoundError:
                pass
    validate_image(IMAGE)
    require(hashlib.sha256((IMAGE/"package.xml").read_bytes()).hexdigest() == prepared["package_xml_sha256"], "image registration changed")
    require(hashlib.sha256((ROOT/"avd/config.ini").read_bytes()).hexdigest() == prepared["config_sha256"], "AVD config changed")
    check_file(ARCHIVE, IMAGE_SIZE, "sha1", IMAGE_SHA1)
    for row in prepared["image_files"]:
        check_file(IMAGE/row["name"], row["bytes"], "sha256", row["sha256"])
        require(stat.S_IMODE((IMAGE/row["name"]).stat().st_mode) == row["mode"], "image permissions changed")
    require(preflight(s) == prepared["candidate"], "candidate version changed")
    s.adb_server = s.spawn([SDK/"platform-tools/adb", "-L", "tcp:127.0.0.1:5038", "server", "nodaemon"], "adb-server", limit=16*MiB)
    until = min(time.monotonic()+10, s.work)
    while not any(r["port"] == 5038 for r in owned_listeners([s.adb_server[1]])):
        s.check()
        require(s.adb_server[0].poll() is None and time.monotonic() < until, "ADB did not bind owned loopback socket")
        time.sleep(.1)
    emulator = s.spawn([SDK/"emulator/emulator", "-avd", AVD, "-port", "5556", "-accel", "off",
        "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot", "-gpu", "swiftshader",
        "-cores", "2", "-memory", "2048", "-camera-back", "none",
        "-camera-front", "none", "-no-metrics", "-feature", "-Vulkan"], "emulator", limit=96*MiB)
    boot_end = min(s.start+900, s.work)
    while True:
        require(emulator[0].poll() is None, "emulator exited during boot")
        code, value = s.adb(["shell", "getprop", "sys.boot_completed"], "boot", seconds=5, deadline=boot_end, ok=False)
        if code == 0 and value.strip() == b"1":
            break
        s.check()
        time.sleep(min(2, clip(time.monotonic(), 2, boot_end)))
    report = dict(boot_seconds=round(time.monotonic()-s.start, 3), gates={})
    props = {}
    for key in ["ro.build.version.sdk", "ro.build.fingerprint", "ro.product.cpu.abilist",
                "ro.product.cpu.abilist64", "ro.dalvik.vm.native.bridge", "ro.dalvik.vm.isa.arm64"]:
        _, value = s.adb(["shell", "getprop", key], "guest-property", seconds=5)
        props[key] = value.decode().strip()
    report["guest_properties"] = props
    require(props["ro.build.version.sdk"] == "30" and "arm64-v8a" in props["ro.product.cpu.abilist64"].split(",")
            and props["ro.dalvik.vm.isa.arm64"] == "x86_64", "guest ARM64 admission not established")
    bridge = props["ro.dalvik.vm.native.bridge"]
    require(re.fullmatch(r"lib[\w.-]+\.so", bridge), "official native bridge not selected")
    code, path = s.adb(["shell", "ls", "-l", "/system/lib64/"+bridge], "native-bridge", ok=False)
    require(code == 0, "official 64-bit bridge file unavailable")
    _, avd_name = s.adb(["emu", "avd", "name"], "avd-identity")
    require(avd_name.decode().splitlines()[0] == AVD, "wrong AVD")
    s.adb(["shell", "cat", "/proc/cpuinfo"], "guest-cpu", limit=MiB)
    s.adb(["get-state"], "device-state")
    _, packages = s.adb(["shell", "pm", "list", "packages", PKG], "package-absence")
    require(not packages.strip(), "Canary/harness package already present")
    s.adb(["install", "--abi", "arm64-v8a", "--no-streaming", str(APK)], "install",
          seconds=300, deadline=min(s.start+1200, s.work))
    _, package = s.adb(["shell", "dumpsys", "package", PKG], "package-selection")
    version = re.search(rb"\bversionCode=(\d+)\b", package)
    require(b"primaryCpuAbi=arm64-v8a" in package and version
            and version[1].decode() == prepared["candidate"]["version_code"], "selected ABI/version mismatch")
    _, activity = s.adb(["shell", "cmd", "package", "resolve-activity", "--brief",
        "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", PKG], "resolve-activity")
    component = next((l.strip() for l in activity.decode().splitlines() if l.strip().startswith(PKG+"/")), "")
    require(re.fullmatch(re.escape(PKG)+r"/[\w.$]+", component), "launch activity unresolved")
    s.spawn([SDK/"platform-tools/adb", "-H", "127.0.0.1", "-P", "5038", "-s", SERIAL,
             "logcat", "-v", "threadtime"], "logcat", limit=96*MiB)
    s.adb(["shell", "am", "start", "-W", "-n", component], "launch", seconds=60)
    pids = []
    for sample in range(2):
        _, pid = s.adb(["shell", "pidof", PKG], "live-pid")
        require(re.fullmatch(rb"\d+", pid.strip()), "app live PID unavailable")
        pids.append(pid.strip().decode())
        if sample == 0:
            time.sleep(clip(time.monotonic(), 15, s.work))
    require(pids[0] == pids[1], "app PID changed")
    _, windows = s.adb(["shell", "dumpsys", "window", "windows"], "window")
    _, shot = s.adb(["exec-out", "screencap", "-p"], "screen", binary=True)
    require(shot.startswith(b"\x89PNG\r\n\x1a\n"), "screenshot invalid")
    s.adb(["shell", "uiautomator", "dump", "/data/local/tmp/ob-S-ui.xml"], "ui-dump", ok=False)
    s.adb(["exec-out", "cat", "/data/local/tmp/ob-S-ui.xml"], "ui-hierarchy", ok=False)
    mc, maps = s.adb(["shell", "run-as", PKG, "cat", "/proc/"+pids[0]+"/maps"], "app-maps", ok=False)
    fc, fds = s.adb(["shell", "run-as", PKG, "ls", "-l", "/proc/"+pids[0]+"/fd"], "app-fd-metadata", ok=False)
    dc, db = s.adb(["shell", "run-as", PKG, "stat", "-c", "%n:%s:%b",
        "app_flutter/objectbox/data.mdb"], "objectbox-file-metadata", ok=False)
    _, logs = s.adb(["logcat", "-d", "--pid="+pids[0], "-v", "threadtime"], "app-logcat", limit=16*MiB)
    library_names = ["libflutter.so", "librust_lib_bluebubbles.so", "libobjectbox-jni.so"]
    later, errors = startup_log_assessment(logs)
    opened = (mc == 0 and b"objectbox/data.mdb" in maps) or (fc == 0 and b"objectbox/data.mdb" in fds)
    metadata = re.search(rb"app_flutter/objectbox/data\.mdb:([0-9]+):([0-9]+)", db)
    report.update(result="evidence_collected_not_app_qualification", live_pid=pids[0],
        gates=dict(primary_abi=True, stable_live_pid=True,
            app_window=bool(re.search(rb"mCurrentFocus=[^\n]*" + re.escape(PKG.encode()), windows)),
            actual_first_screen="requires parent visual review of screenshot/UI; no automatic screen pass",
            loaded_libraries={n:mc == 0 and n.encode() in maps for n in library_names},
            later_startup=later, objectbox=bool(dc == 0 and metadata and int(metadata[1]) > 0
                and opened and later and not errors and b"libobjectbox-jni.so" in maps),
            startup_error_observed=errors, host_tls_not_app_tls=True, apple_cloudkit="unrun"))
    return report


def failure_diagnostics(error, phase):
    detail = {"failure_detail": watchdog_error_detail("main_" + phase, error)}
    reason = getattr(error, "reason", None)
    if isinstance(reason, BaseException):
        detail["reason_detail"] = watchdog_error_detail("network_reason", reason)
    return detail


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("phase", choices=("prepare", "trial"))
    parser.add_argument("--request-id", required=True, help="Distinct supervisor-approved T request; S is implementation only")
    args = parser.parse_args()
    require(re.fullmatch(r"OB-[A-Z0-9-]+-T", args.request_id), "a distinct reviewed T request is required; S does not authorize execution")
    s = Session(args.phase, args.request_id)
    report = dict(result="interrupted_or_failed", phase=args.phase, request=args.request_id)
    def interrupted(*unused):
        raise RuntimeError("termination requested")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        report.update(prepare(s) if args.phase == "prepare" else trial(s))
    except BaseException as e:
        # urllib errors may embed URLs/queries; no raw network exception dumps.
        report.update(error_type=type(e).__name__,
                      error=redact(str(e))[:1000] if type(e) is RuntimeError else "details withheld; inspect bounded command evidence")
        report.update(failure_diagnostics(e, args.phase))
        if isinstance(e, urllib.error.HTTPError):
            report["http_status"] = e.code
    finally:
        s.finish(report)
    print(json.dumps({k:report[k] for k in ("result", "phase", "cleanup_verified", "elapsed_seconds", "free_bytes")}))
    return 0 if report["result"] in ("prepared_not_booted", "evidence_collected_not_app_qualification") and report["cleanup_verified"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
