#!/usr/bin/env python3
"""One bounded transfer of an immutable, already-qualified APK. No rebuild.

GitHub authorization is used only at api.github.com. The signed storage URL is
held in memory, is not logged, and receives no authorization header. Inherited
proxy and CA settings remain in force. No redirects or network retries.
"""
import hashlib
import json
import os
from pathlib import Path
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile

SOURCE = "802e92ded7035c1153e930c9b43e671fa9c400d5"
WORKFLOW_SHA = "1ff3a0cb837c52beaeef0a71059ca7e4888051e9"
RUN_ID = 37003889873
ARTIFACT_ID = 11226077330
ZIP_SIZE = 442331637
ZIP_HASH = "9d33f0490b24a1e20788b622b302c0d94d248f2423d1d4fadf31d93e70d0af14"
APK_SIZE = 454937123
APK_HASH = "2bec869d8611e5aa8ba4c667bae4b66884dbb1c53b7aeab23887382aff4bb967"
IMAGE_METADATA_URL = "https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-4.xml"
HERE = Path(__file__).resolve().parent


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def artifact_valid(item):
    run = item.get("workflow_run") or {}
    return (item.get("id") == ARTIFACT_ID and not item.get("expired", True)
            and item.get("size_in_bytes") == ZIP_SIZE
            and item.get("name") == f"GCE CloudKit V2 Canary APK {SOURCE} writer-true automatic-true"
            and run.get("id") == RUN_ID and run.get("head_sha") == WORKFLOW_SHA
            and run.get("head_branch") == "agent/gce-runner-pilot")


def storage_host(url):
    part = urllib.parse.urlsplit(url)
    require(part.scheme == "https" and not part.username and not part.password
            and part.port in (None, 443) and part.hostname
            and (part.hostname.endswith(".blob.core.windows.net")
                 or part.hostname.endswith(".actions.githubusercontent.com")),
            "unexpected artifact redirect host")
    return part.hostname


def only_apk(entries):
    files = [entry for entry in entries if not entry.is_dir()]
    require(len(files) == 1 and files[0].filename == "app-canary-debug.apk"
            and files[0].file_size == APK_SIZE and not files[0].flag_bits & 1,
            "unexpected artifact ZIP contents")
    return files[0]


def immutable(path, value):
    with path.open("x", encoding="utf-8") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *unused):
        return None


def run(report):
    require(os.environ.get("GITHUB_ACTIONS") == "true", "GCE Actions runtime only")
    require(os.environ.get("GITHUB_REPOSITORY") == "Xare123/openbubbles-app", "wrong repository")
    require(os.environ.get("SOURCE_REF") == SOURCE, "wrong source candidate")
    apk = Path(os.environ["OB_RUNTIME_APK"])
    metadata = Path(os.environ["OB_RUNTIME_METADATA"])
    require(apk.resolve() == apk and metadata.resolve() == metadata, "symlinked transfer target")
    require(not apk.parent.exists() and not metadata.exists(), "preserve existing artifact/metadata")
    token = os.environ["GITHUB_TOKEN"]
    require(bool(token), "missing job-scoped token")
    ca = os.environ.get("REQUESTS_CA_BUNDLE") or os.environ.get("SSL_CERT_FILE")
    context = ssl.create_default_context(cafile=ca)
    require(context.check_hostname and context.verify_mode == ssl.CERT_REQUIRED, "TLS verification disabled")
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=context), NoRedirect())
    auth = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"}
    api = f"https://api.github.com/repos/Xare123/openbubbles-app/actions/artifacts/{ARTIFACT_ID}"
    with opener.open(urllib.request.Request(api, headers=auth), timeout=30) as response:
        require(response.status == 200, "artifact metadata status")
        raw = response.read(1024*1024 + 1)
        require(len(raw) <= 1024*1024, "artifact metadata cap")
        item = json.loads(raw)
    require(artifact_valid(item), "artifact provenance mismatch")
    report["artifact_provenance_verified"] = True
    try:
        response = opener.open(urllib.request.Request(api + "/zip", headers=auth), timeout=30)
    except urllib.error.HTTPError as redirect:
        try:
            require(redirect.code == 302, "artifact API did not provide expected storage redirect")
            location = redirect.headers.get("Location", "")
        finally:
            redirect.close()
    else:
        response.close()
        raise RuntimeError("artifact API unexpectedly returned a body instead of a redirect")
    report["storage_host"] = storage_host(location)
    report["download_attempts"] = 1
    apk.parent.mkdir(parents=True, exist_ok=False)
    archive = apk.parent / "artifact.zip"
    deadline = time.monotonic() + 300
    digest, count = hashlib.sha256(), 0
    with opener.open(location, timeout=30) as response, archive.open("xb") as target:
        require(response.status == 200, "artifact storage status")
        length = response.headers.get("Content-Length")
        require(length is None or int(length) == ZIP_SIZE, "artifact declared size mismatch")
        while block := response.read(1024*1024):
            require(time.monotonic() < deadline, "artifact transfer deadline")
            count += len(block)
            report["download_bytes"] = count
            require(count <= ZIP_SIZE, "artifact transfer size cap")
            target.write(block)
            digest.update(block)
    require(count == ZIP_SIZE and digest.hexdigest() == ZIP_HASH, "whole ZIP hash/size mismatch")
    report.update(zip_bytes=count, zip_sha256=digest.hexdigest())
    digest, count = hashlib.sha256(), 0
    with zipfile.ZipFile(archive) as zipped:
        entry = only_apk(zipped.infolist())
        with zipped.open(entry) as source, apk.open("xb") as target:
            while block := source.read(1024*1024):
                count += len(block)
                require(count <= APK_SIZE, "APK expansion cap")
                target.write(block)
                digest.update(block)
    require(count == APK_SIZE and digest.hexdigest() == APK_HASH, "whole APK hash/size mismatch")
    report.update(apk_bytes=count, apk_sha256=digest.hexdigest(), zip_crc_verified=True)
    with opener.open(IMAGE_METADATA_URL, timeout=30) as response:
        require(response.status == 200, "official image metadata status")
        raw = response.read(2*1024*1024 + 1)
        require(len(raw) <= 2*1024*1024, "official image metadata cap")
    with metadata.open("xb") as target:
        target.write(raw)
    report.update(image_metadata_sha256=hashlib.sha256(raw).hexdigest(),
                  image_metadata_bytes=len(raw), result="materialized_not_installed")


def main():
    evidence = HERE / "run"
    evidence.mkdir(exist_ok=True)
    immutable(evidence / "materialize.attempt.json", {
        "request": f"OB-GCE-APK-802E92-{os.environ.get('GITHUB_RUN_ID', 'unknown')}-MATERIALIZE",
        "source": SOURCE, "artifact_id": ARTIFACT_ID, "attempts": 1,
        "helper_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    })
    started = time.monotonic()
    report = {"source": SOURCE, "artifact_id": ARTIFACT_ID, "result": "failed", "download_bytes": 0}
    try:
        run(report)
    except Exception as error:
        reason = getattr(error, "reason", None)
        report.update(error_type=type(error).__name__, http_status=getattr(error, "code", None),
                      errno=getattr(error, "errno", None), reason_type=type(reason).__name__,
                      reason_errno=getattr(reason, "errno", None))
    report["seconds"] = round(time.monotonic() - started, 3)
    immutable(evidence / "materialize.result.json", report)
    print(json.dumps(report, sort_keys=True))
    return 0 if report["result"] == "materialized_not_installed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
