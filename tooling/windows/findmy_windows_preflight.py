"""Local-only retained-profile checks. Invoked live only by the explicit launcher.

Standard-library plistlib handles both native binary keystores and XML state.
Never print parsed state, exceptions, credentials, or identity fingerprints.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat

DLL_SHA256 = "6c85d27e7f1dbe8d92aac7c7292f1b5676cb6911c4fd67fd7802ced8c627140e"
ANISETTE_ENDPOINT = "https://ani.sidestore.io"
MARKER = "openbubbles-cloud-sync-v2-windows-dev-profile:v1"
SOURCE_PINS = {
    "lib/src/rust/frb_generated.dart": "c717a3842e92f04c21242003cb25c176693ef9b53f14abc4da719174b776d6ab",
    "lib/src/rust/frb_generated.io.dart": "380a2dff2358a0d2ab8661c0faa38ad0e22d9c2644a709c7e38fd7e592170923",
    "lib/src/rust/api/api.dart": "ad1ea015c59c768aa7870e70300de2d9ae81eb4767bda3948390cd45059810a1",
    "lib/cloud_sync_v2_windows_findmy_probe.dart": "fa24e14eecd102bff39c7161c0625edd8cee6ca0ea3a7ef7d27528d7a940ca4a",
}


class Rejected(Exception):
    pass


def require(condition):
    if not condition:
        raise Rejected()


def plain(target):
    target = Path(target).absolute()
    for item in (target, *target.parents):
        info = item.lstat()  # Missing paths and reparse ancestors fail closed.
        require(not stat.S_ISLNK(info.st_mode))
        require(not (getattr(info, "st_file_attributes", 0) & 0x400))
    return target


def bounded(target, limit=4 * 1024 * 1024):
    target = plain(target)
    require(target.is_file() and 0 < target.stat().st_size <= limit)
    with target.open("rb") as stream:
        result = stream.read(limit + 1)
    require(0 < len(result) <= limit)
    return result


def digest(value):
    return hashlib.sha256(plistlib.dumps(value, fmt=plistlib.FMT_BINARY)).hexdigest()


def file_hash(target):
    with plain(target).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def retained_snapshot(profile):
    """Private comparison digests only; no decrypt, network, write, or repair."""
    profile = plain(profile)
    require(bounded(profile / ".openbubbles-cloud-sync-v2-windows-dev").decode() == MARKER)
    values = {}
    for name in ("hw_info.plist", "gsa.plist", "keystore.plist",
                 "sharedstreams.plist", "anisette_test/state.plist"):
        values[name] = plistlib.loads(bounded(profile / name, 64 * 1024 * 1024))
        require(isinstance(values[name], dict))
    hw, gsa, keys, streams, ani = (values[name] for name in (
        "hw_info.plist", "gsa.plist", "keystore.plist", "sharedstreams.plist",
        "anisette_test/state.plist"))
    data = lambda value: isinstance(value, bytes) and len(value) > 0
    string = lambda value: isinstance(value, str) and bool(value.strip())
    require(data(hw.get("identity")))
    require(isinstance(hw.get("os_config"), dict))
    require(hw["os_config"].get("type") in ("Relay", "MacOS"))
    push = hw["push"]
    require(data(push.get("token")) and len(push["token"]) == 32)
    pair = push["keypair"]
    require(data(pair.get("cert")) and string(pair.get("private")))
    require(gsa.get("postdata_done") is True and string(gsa.get("username")))
    require(data(gsa.get("encrypted_password")))
    require(type(keys.get("format_version")) is int and keys["format_version"] == 2)
    require(data(keys.get("protected_master_key")))
    require(isinstance(keys["state"]["secrets"], dict))
    for alias in ("gsa:password", "ids:identity-storage-key:openbubbles", pair["private"]):
        require(data(keys["state"]["keys"].get(alias)))
    require(string(streams.get("dsid")))
    require(data(ani.get("keychain_identifier")) and len(ani["keychain_identifier"]) == 16)
    # An existing identifier + exact service binding may renew missing/expired
    # ADI material. Never manufacture the identifier or adopt another endpoint.
    require("adi_pb" not in ani or data(ani["adi_pb"]))
    # Do not adopt a legacy endpoint, change servers, or create new ADI identity.
    require(ani.get("endpoint") == ANISETTE_ENDPOINT)
    if hw["os_config"]["type"] == "Relay":
        for field in ("host", "code", "dev_uuid"):
            require(string(hw["os_config"].get(field)))
    return {
        "configuration": digest(hw["os_config"]),
        "aps_keypair": digest(pair),
        "credentials": digest(gsa),
        "keystore": digest(keys),
        "streams": digest(streams),
        "anisette_identity_and_endpoint": digest([ani["keychain_identifier"], ani["endpoint"]]),
        # hw.identity is AES-GCM reserialized by setup_push with a fresh nonce.
        # Identity preservation there is established by the pinned native trace,
        # not by comparing ciphertext bytes. APS token and ADI renewal are allowed.
    }


def verify_sources(repository, library):
    require(file_hash(library) == DLL_SHA256)
    for relative, expected in SOURCE_PINS.items():
        require(file_hash(Path(repository) / relative) == expected)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("prepare", "verify"))
    parser.add_argument("--profile", required=True)
    parser.add_argument("--launch", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--library", required=True)
    args = parser.parse_args()
    try:
        require(os.name == "nt" and os.environ.get("OPENBUBBLES_RUN_FINDMY_WINDOWS_LIVE") == "1")
        require(re.fullmatch(r"[a-f0-9]{32}", args.launch) is not None)
        expected = Path(os.environ["APPDATA"]) / "OpenBubbles" / "cloudkit-v2-dev"
        require(Path(args.profile).absolute() == expected.absolute())
        profile = plain(expected)
        directory = plain(profile / "cloud-sync-v2" / "findmy-testhost" / args.launch)
        snapshot = retained_snapshot(profile)
        admission = directory / "admission.json"
        if args.mode == "prepare":
            verify_sources(args.repository, args.library)
            with admission.open("x", encoding="utf-8") as stream:
                json.dump({"version": 1, "launch_id": args.launch,
                           "native_sha256": DLL_SHA256, "before": snapshot}, stream)
        else:
            previous = json.loads(bounded(admission).decode("utf-8"))
            require(previous["launch_id"] == args.launch and previous["before"] == snapshot)
        return 0
    except Exception:
        # Native/private parser diagnostics must not enter terminal output.
        print("findmy_testhost_retained_preflight_rejected" if args.mode == "prepare"
              else "findmy_testhost_retained_state_changed_or_unreadable")
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
