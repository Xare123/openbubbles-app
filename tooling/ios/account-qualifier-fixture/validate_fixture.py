"""Validate frozen parent-supplied bytes. Never synthesize a login request."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import stat
import sys
import xml.etree.ElementTree as ET

MAX_BODY = 8192
MAX_METADATA = 2048
MANIFEST_KEYS = {"schema", "run_id", "client_id", "body_sha256"}


class FixtureError(ValueError):
    pass


def _object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise FixtureError("duplicate-json-key")
        result[key] = value
    return result


def _invalid_constant(_value):
    raise FixtureError("invalid-json-number")


def _keys(value, expected):
    return type(value) is dict and set(value) == expected


def validate_bytes(metadata, body):
    if not 0 < len(metadata) <= MAX_METADATA or not 0 < len(body) <= MAX_BODY:
        raise FixtureError("fixture-size")
    try:
        info = json.loads(metadata.decode("utf-8"), object_pairs_hook=_object,
                          parse_constant=_invalid_constant)
        if not _keys(info, MANIFEST_KEYS) or type(info["schema"]) is not int or info["schema"] != 1:
            raise FixtureError("manifest-schema")
        for name, pattern in [("run_id", r"[0-9a-f]{32}"),
                              ("client_id", r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}"),
                              ("body_sha256", r"[0-9a-f]{64}")]:
            if type(info[name]) is not str or not re.fullmatch(pattern, info[name]):
                raise FixtureError("manifest-value")
        if hashlib.sha256(body).hexdigest() != info["body_sha256"]:
            raise FixtureError("body-hash")
        # The Rust producer supplies XML plist bytes. Reject entities and duplicate
        # dictionary keys before plistlib/Foundation can silently collapse them.
        if b"<!ENTITY" in body or body.startswith(b"bplist"):
            raise FixtureError("body-format")
        tree = ET.fromstring(body)
        for dictionary in tree.iter("dict"):
            children = list(dictionary)
            keys = [node.text for node in children[::2]]
            if len(children) % 2 or any(node.tag != "key" for node in children[::2]) or len(set(keys)) != len(keys):
                raise FixtureError("duplicate-or-invalid-plist-key")
        value = plistlib.loads(body)
        if not _keys(value, {"protocolVersion", "userInfo", "delegates"}) or value["protocolVersion"] != "1.0":
            raise FixtureError("body-schema")
        user = value["userInfo"]
        if not _keys(user, {"client-id", "language", "timezone"}) or user["client-id"] != info["client_id"]:
            raise FixtureError("user-info")
        for field, maximum in [("language", 64), ("timezone", 128)]:
            text = user[field]
            if type(text) is not str or not 0 < len(text) <= maximum or any(not 0x20 <= ord(char) <= 0x7e for char in text):
                raise FixtureError("user-info-value")
        delegates = value["delegates"]
        if not _keys(delegates, {"com.apple.private.ids", "com.apple.mobileme"}):
            raise FixtureError("delegates")
        if delegates["com.apple.mobileme"] != {} or not _keys(delegates["com.apple.private.ids"], {"protocol-version"}):
            raise FixtureError("delegate-schema")
        if delegates["com.apple.private.ids"]["protocol-version"] != "4":
            raise FixtureError("ids-version")
    except FixtureError:
        raise
    except (ValueError, TypeError, KeyError, ET.ParseError, plistlib.InvalidFileException, OverflowError):
        raise FixtureError("invalid-fixture") from None
    return info


def normalize_source_body(metadata, body):
    """Allow only one patch-added final LF, and only under the production SHA.

    This source-only accommodation is never used for staged/runtime validation.
    Exact matching bytes, including a legitimate final LF, are kept unchanged.
    """
    try:
        validate_bytes(metadata, body)
        return body
    except FixtureError:
        if not body.endswith(b"\n"):
            raise
    candidate = body[:-1]  # Exactly one byte. Never rstrip/reformat XML.
    validate_bytes(metadata, candidate)
    return candidate


def _read_regular(directory, name, maximum):
    path = directory / name
    item = path.lstat()
    if not stat.S_ISREG(item.st_mode) or not 0 < item.st_size <= maximum:
        raise FixtureError("fixture-file")
    with path.open("rb") as stream:
        data = stream.read(maximum + 1)
    if len(data) != item.st_size:
        raise FixtureError("fixture-file-changed")
    return data


def load_fixture(directory, source=False):
    metadata = _read_regular(directory, "fixture.json", MAX_METADATA)
    body = _read_regular(directory, "body.plist", MAX_BODY + (1 if source else 0))
    if source:
        body = normalize_source_body(metadata, body)
    info = validate_bytes(metadata, body)
    return metadata, body, info


def stage_fixture(directory, destination):
    """Generate only new output files from validated parent bytes during build."""
    metadata, body, _info = load_fixture(directory, source=True)
    # Build creates a NEW app directory. Never overwrite files on rerun/failure.
    if not destination.is_dir() or destination.is_symlink() or any(destination.iterdir()):
        raise FixtureError("new-empty-stage-directory-required")
    with (destination / "body.plist").open("xb") as stream:
        stream.write(body)
    with (destination / "fixture.json").open("xb") as stream:
        stream.write(metadata)
    # Reopen staged bytes with strict validation: NO final-LF accommodation.
    staged_metadata, staged_body, info = load_fixture(destination)
    if staged_metadata != metadata or staged_body != body:
        raise FixtureError("staged-fixture-changed")
    return staged_metadata, staged_body, info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--source", action="store_true", help="Validate source with one hash-verified patch LF accommodation")
    mode.add_argument("--stage", type=pathlib.Path, help="Generate exact bytes in a NEW empty output app directory")
    parser.add_argument("directory", type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.stage is not None:
            metadata, _body, info = stage_fixture(args.directory, args.stage)
        else:
            metadata, _body, info = load_fixture(args.directory, source=args.source)
        # Only public fixture hashes and the fixed run identifier reach the build.
        print(info["run_id"], info["body_sha256"], hashlib.sha256(metadata).hexdigest())
    except (OSError, FixtureError):
        print("Frozen qualifier fixture invalid or unavailable", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
