"""One credential-free native Windows machine handshake, with redacted receipts.

Uses the pinned apple-crates provider and its reference provisioning contract.
No password, verification code, account lookup, OTP request or app login exists.
Opaque handshake buffers and actual host identity remain in private pipes/RAM.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import queue
import re
import socket
import ssl
import subprocess
import threading
import urllib.error
import urllib.parse
import urllib.request

MAX_BODY = 1024 * 1024
LOOKUP = "https://gsa.apple.com/grandslam/GsService2/lookup"


class ProbeError(Exception):
    pass


def apple_tls():
    # Same public Apple roots as the application's authentication/provisioning
    # client, not a private/interception CA. Leave hostname and chain checks on.
    pem = (Path(__file__).parent / "windows_adi_machine" / "apple-roots.pem").read_text(encoding="ascii")
    certificates = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S)
    digests = {hashlib.sha256(ssl.PEM_cert_to_DER_cert(item)).hexdigest() for item in certificates}
    if digests != {
        "b0b1730ecbc7ff4505142c49f1295e6eda6bcaed7e2c68c5be91b5a11001f024",
        "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179",
    } or len(certificates) != 2:
        raise ProbeError("apple-root-fingerprint")
    context = ssl.create_default_context()
    context.load_verify_locations(cadata=pem)
    return context


def network_failure(stage, error):
    reason = error.reason if isinstance(error, urllib.error.URLError) else error
    if isinstance(reason, ssl.SSLCertVerificationError):
        report(stage, failure="tls-certificate", verify_code=getattr(reason, "verify_code", None))
    elif isinstance(reason, ssl.SSLError):
        report(stage, failure="tls", errno=reason.errno)
    elif isinstance(reason, socket.gaierror):
        report(stage, failure="dns", errno=reason.errno)
    elif isinstance(reason, TimeoutError):
        report(stage, failure="timeout")
    else:
        report(stage, failure="connection", errno=getattr(reason, "errno", None))


def apple_url(url):
    if not isinstance(url, str):
        raise ProbeError("endpoint-type")
    try:
        parsed = urllib.parse.urlsplit(url)
        allowed = (parsed.scheme == "https" and parsed.hostname in ("gsa.apple.com", "gsd.apple.com")
                   and parsed.port in (None, 443) and not parsed.username and not parsed.password
                   and parsed.path.startswith("/grandslam/") and not parsed.query and not parsed.fragment)
    except ValueError:
        allowed = False
    if not allowed:
        raise ProbeError("endpoint-not-admitted")
    return url


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def report(stage, **values):
    print(json.dumps({"stage": stage, **values}, sort_keys=True), flush=True)


def response_dict(value):
    if not isinstance(value, dict) or not isinstance(value.get("Response"), dict):
        raise ProbeError("response-shape")
    response = value["Response"]
    status = response.get("Status", {})
    if not isinstance(status, dict) or type(status.get("ec", 0)) is not int:
        raise ProbeError("status-shape")
    if status.get("ec", 0) != 0:
        report("apple-rejection", ec=status["ec"])
        raise ProbeError("apple-rejection")
    return response


def binary_string(value, key):
    raw = value.get(key)
    if not isinstance(raw, str) or not raw or len(raw) > MAX_BODY // 2:
        raise ProbeError("binary-shape")
    try:
        decoded = base64.b64decode(raw, validate=True)
    except ValueError:
        raise ProbeError("binary-encoding") from None
    if not decoded:
        raise ProbeError("binary-empty")
    return raw


def request(opener, stage, url, headers, body=None):
    data = None if body is None else plistlib.dumps(body)
    req = urllib.request.Request(apple_url(url), data=data, headers=headers)
    try:
        with opener.open(req, timeout=20) as response:
            report(stage, http=response.status)
            raw = response.read(MAX_BODY + 1)
    except urllib.error.HTTPError as error:
        report(stage, http=error.code)
        error.close()
        raise ProbeError("http-rejected") from None
    except (urllib.error.URLError, OSError) as error:
        network_failure(stage, error)
        raise ProbeError("network-or-tls") from None
    if len(raw) > MAX_BODY:
        raise ProbeError("response-bound")
    try:
        return plistlib.loads(raw)
    except Exception:
        raise ProbeError("response-not-plist") from None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", required=True)
    parser.add_argument("--library", required=True)
    args = parser.parse_args()
    if (os.name != "nt" or os.environ.get("GITHUB_ACTIONS") != "true"
            or os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted"):
        raise ProbeError("host-not-admitted")
    context = apple_tls()
    opener = urllib.request.build_opener(NoRedirect(), urllib.request.HTTPSHandler(context=context))
    child = subprocess.Popen([args.probe, args.library], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             text=True, encoding="utf-8", creationflags=subprocess.CREATE_NO_WINDOW)
    inbox = queue.Queue(maxsize=16)

    def collect():
        while True:
            line = child.stdout.readline(MAX_BODY + 1)
            if not line:
                inbox.put(None)
                return
            inbox.put(line)

    threading.Thread(target=collect, daemon=True).start()

    def receive(expected):
        try:
            line = inbox.get(timeout=10)
        except queue.Empty:
            raise ProbeError("pipe-timeout") from None
        if not line or len(line) > MAX_BODY:
            raise ProbeError("pipe-closed-or-bound")
        try:
            value = json.loads(line)
        except (ValueError, TypeError):
            raise ProbeError("pipe-json") from None
        if not isinstance(value, dict):
            raise ProbeError("pipe-shape")
        if type(value.get("native_error")) is int:
            report("native-error", code=value["native_error"])
        if value.get("stage") != expected:
            raise ProbeError("native-stage")
        return value

    def send(value):
        child.stdin.write(json.dumps(value) + "\n")
        child.stdin.flush()

    try:
        ready = receive("ready")
        identifier = ready.get("device_id")
        if not isinstance(identifier, str) or not re.fullmatch(r"[0-9A-F]{8}(?:\.[0-9A-F]{8}){6}", identifier):
            raise ProbeError("host-identity-shape")
        report("native-ready", account_access=False, otp_requested=False)
        headers = {
            "User-Agent": "OpenBubblesProvisionProbe/0.1",
            "X-Mme-Client-Info": f"<PC> <Windows; {platform.version()}> <com.apple.AuthKit/1 (com.openbubbles.provision-probe/0.1)>",
            "X-Mme-Device-Id": identifier,
            "X-Apple-Client-App-Name": "OpenBubblesProvisionProbe",
            "X-Apple-I-Client-Time": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
            "Content-Type": "application/x-www-form-urlencoded",
        }
        bag = request(opener, "lookup", LOOKUP, headers)
        if not isinstance(bag, dict) or not isinstance(bag.get("urls"), dict):
            raise ProbeError("bag-shape")
        start_url = apple_url(bag["urls"].get("midStartProvisioning"))
        finish_url = apple_url(bag["urls"].get("midFinishProvisioning"))
        spim = binary_string(response_dict(request(opener, "start", start_url, headers)), "spim")
        send({"action": "start", "spim": spim})
        cpim = binary_string(receive("started"), "cpim")
        finished = response_dict(request(opener, "finish", finish_url, headers, {"Request": {"cpim": cpim}}))
        routing = finished.get("X-Apple-I-MD-RINFO")
        if not isinstance(routing, (str, int)) or isinstance(routing, bool) or not re.fullmatch(r"[0-9]{1,20}", str(routing)):
            raise ProbeError("routing-shape")
        routing = int(routing)
        if not 0 <= routing <= 2**64 - 1:
            raise ProbeError("routing-bound")
        send({"action": "finish", "ptm": binary_string(finished, "ptm"),
              "tk": binary_string(finished, "tk"), "routing": routing})
        if receive("provisioned").get("provisioned") is not True:
            raise ProbeError("provisioning-not-proven")
        if receive("cleanup").get("machine_state_removed") is not True:
            raise ProbeError("machine-cleanup-not-proven")
        child.stdin.close()
        if child.wait(timeout=10) != 0:
            raise ProbeError("native-exit")
        report("complete", machine_provisioning=True, machine_state_removed=True,
               account_access=False, otp_requested=False, sms_requested=False)
    finally:
        if not child.stdin.closed:
            child.stdin.close()
        try:
            child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=5)
        child.stdout.close()
        report("child-cleanup", exited=child.poll() is not None)


if __name__ == "__main__":
    try:
        main()
    except ProbeError as error:
        report("failed", reason=str(error))
        raise SystemExit(1)
    except Exception:
        report("failed", reason="unexpected-local-error")
        raise SystemExit(1)
