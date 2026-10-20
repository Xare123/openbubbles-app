#!/usr/bin/env python3
"""Fetch two fixed public Theos SDK assets, with no credentials or latest route."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import urllib.request

THEOS_PIN = "cfba89a53a05b4a1b822121158acc3669c20602f"
SDKS = [(137098923, "iPhoneOS14.5", 12747236), (137098925, "iPhoneOS16.5", 17446920)]


def request(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={
        "Accept":"application/vnd.github+json", "User-Agent":"OpenBubbles-USB-control-build/1"}), timeout=60)


def fetch(theos, evidence):
    theos, evidence = theos.resolve(strict=True), evidence.resolve(strict=True)
    head = subprocess.check_output(["git","-C",str(theos),"rev-parse","HEAD"],text=True).strip()
    if head != THEOS_PIN:
        raise ValueError("pinned-theos-checkout-required")
    sdk_root = theos / "sdks"
    sdk_root.mkdir(exist_ok=True)
    results = []
    for asset_id, name, size in SDKS:
        destination = sdk_root / (name+".sdk")
        if destination.exists():
            raise ValueError("new-sdk-directory-required")
        with request(f"https://api.github.com/repos/theos/sdks/releases/assets/{asset_id}") as response:
            asset = json.loads(response.read(65537))
        url = f"https://github.com/theos/sdks/releases/download/master-146e41f/{name}.sdk.tar.xz"
        if asset.get("id") != asset_id or asset.get("name") != name+".sdk.tar.xz" or asset.get("size") != size or asset.get("browser_download_url") != url:
            raise ValueError("public-sdk-asset-metadata-changed")
        archive = evidence / (name+".sdk.tar.xz")
        with request(url) as response, archive.open("xb") as output:
            if response.url.split(":",1)[0] != "https":
                raise ValueError("https-sdk-download-required")
            data = response.read(size+1)
            if len(data) != size:
                raise ValueError("sdk-size-mismatch")
            digest = hashlib.sha256(data).hexdigest()
            expected = asset.get("digest")
            if expected is not None and expected != "sha256:"+digest:
                raise ValueError("sdk-digest-mismatch")
            output.write(data)
        with tarfile.open(archive,"r:xz") as bundle:
            members = bundle.getmembers()
            if any(PurePosixPath(entry.name).is_absolute() or ".." in PurePosixPath(entry.name).parts
                   or not PurePosixPath(entry.name).parts or PurePosixPath(entry.name).parts[0] != name+".sdk"
                   for entry in members):
                raise ValueError("unexpected-sdk-root")
            bundle.extractall(sdk_root, members=members, filter="data")
        if not destination.is_dir():
            raise ValueError("sdk-root-not-created")
        results.append({"asset_id":asset_id,"name":name,"bytes":size,"sha256_observed":digest,
            "upstream_digest_available":expected is not None})
    (evidence/"SDK_PROVENANCE.json").write_text(json.dumps(results,indent=2)+"\n",encoding="utf-8")
    print(json.dumps({"sdk_assets":len(results),"credential_input":False,"account_requests":0}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--theos",required=True,type=Path)
    parser.add_argument("--evidence",required=True,type=Path)
    args=parser.parse_args()
    fetch(args.theos,args.evidence)
