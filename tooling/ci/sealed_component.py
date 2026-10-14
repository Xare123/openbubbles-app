"""Private component delivery, not a credential or public binary artifact.

Only a per-run public RSA key goes to the builder. AES-256-GCM authenticates
the binary and its metadata; RSA-OAEP/SHA256 wraps the random one-use AES key.
The private key stays in the local evidence directory and is never printed.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import io
import zipfile

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"OB-CORTEN-SEALED-1\x00"
LIMIT = 256 * 1024 * 1024
LOGIN_TARGET = "android-x64-login-zip"
LOGIN_LIMIT = 512 * 1024 * 1024


def target_limit(target):
    if target == "aarch64-linux-android":
        return LIMIT
    if target == LOGIN_TARGET:
        return LOGIN_LIMIT
    raise ValueError("unknown private artifact target")


def validate_payload(payload, target):
    if target == LOGIN_TARGET:
        with zipfile.ZipFile(io.BytesIO(payload)) as bundle:
            names = bundle.namelist()
            if sorted(names) != ["app-canary-debug.apk", "corten-mac-validation-probe"]:
                raise ValueError("unexpected login bundle members")
            if sum(i.file_size for i in bundle.infolist()) > LOGIN_LIMIT:
                raise ValueError("expanded login bundle exceeds bound")
            with zipfile.ZipFile(io.BytesIO(bundle.read("app-canary-debug.apk"))) as apk:
                native = [n.split("/")[1] for n in apk.namelist() if n.startswith("lib/") and n.endswith(".so")]
                if not native or set(native) != {"x86_64"}:
                    raise ValueError("expected only real Android x64 libraries")
            probe = bundle.read("corten-mac-validation-probe")
            if len(probe) < 20 or probe[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<HH", probe, 16) != (3, 62):
                raise ValueError("expected Android x64 PIE")
    elif len(payload) < 20 or payload[:6] != b"\x7fELF\x02\x01" or struct.unpack_from("<HH", payload, 16) != (3, 183):
        raise ValueError("expected Android AArch64 PIE")


def public_bytes(key):
    return key.public_bytes(serialization.Encoding.PEM,
                            serialization.PublicFormat.SubjectPublicKeyInfo)


def oaep():
    return padding.OAEP(mgf=padding.MGF1(hashes.SHA256()),
                        algorithm=hashes.SHA256(), label=None)


def prepare(directory):
    directory.mkdir(parents=True, exist_ok=False)
    key = rsa.generate_private_key(public_exponent=65537, key_size=3072)
    # The directory is local evidence on the user's machine, never an artifact.
    private = key.private_bytes(serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    with (directory / "private.pem").open("xb") as stream:
        stream.write(private)
    with (directory / "public.pem").open("xb") as stream:
        stream.write(public_bytes(key.public_key()))
    return {"public_key_sha256": hashlib.sha256(public_bytes(key.public_key())).hexdigest()}


def seal(binary, public_path, output, source, pilot, target="aarch64-linux-android"):
    if not 0 < binary.stat().st_size <= target_limit(target):
        raise ValueError("component size outside bound")
    public = serialization.load_pem_public_key(public_path.read_bytes())
    if not isinstance(public, rsa.RSAPublicKey) or public.key_size != 3072:
        raise ValueError("expected one-use RSA3072 public key")
    payload = binary.read_bytes()
    content_key = AESGCM.generate_key(bit_length=256)
    nonce = os.urandom(12)
    metadata = {"version":1,"application_sha":source,"pilot_sha":pilot,
        "target":target,"bytes":len(payload),
        "sha256":hashlib.sha256(payload).hexdigest(),
        "public_key_sha256":hashlib.sha256(public_bytes(public)).hexdigest(),
        "nonce":base64.b64encode(nonce).decode(),
        "wrapped_key":base64.b64encode(public.encrypt(content_key,oaep())).decode()}
    header = json.dumps(metadata,sort_keys=True,separators=(",",":")).encode()
    encrypted = AESGCM(content_key).encrypt(nonce,payload,header)
    with output.open("xb") as stream:
        stream.write(MAGIC + struct.pack(">I",len(header)) + header + encrypted)
    return {key:metadata[key] for key in ("bytes","sha256","public_key_sha256","target")}


def unseal(envelope, private_path, output, expected_sha, expected_pilot, expected_target="aarch64-linux-android"):
    if not 0 < envelope.stat().st_size <= target_limit(expected_target) + 8192:
        raise ValueError("sealed artifact size outside bound")
    raw = envelope.read_bytes()
    if raw[:len(MAGIC)] != MAGIC:
        raise ValueError("unknown sealed artifact format")
    start = len(MAGIC)+4
    length = struct.unpack(">I",raw[len(MAGIC):start])[0]
    if not 0 < length <= 4096:
        raise ValueError("sealed header outside bound")
    header = raw[start:start+length]
    metadata = json.loads(header)
    if (metadata.get("version") != 1 or metadata.get("sha256") != expected_sha
            or metadata.get("pilot_sha") != expected_pilot
            or metadata.get("target") != expected_target):
        raise ValueError("sealed artifact differs from reviewed receipt")
    private = serialization.load_pem_private_key(private_path.read_bytes(),password=None)
    if not isinstance(private,rsa.RSAPrivateKey) or private.key_size != 3072:
        raise ValueError("expected local RSA3072 private key")
    if hashlib.sha256(public_bytes(private.public_key())).hexdigest() != metadata["public_key_sha256"]:
        raise ValueError("artifact public-key identity differs")
    key = private.decrypt(base64.b64decode(metadata["wrapped_key"],validate=True),oaep())
    nonce = base64.b64decode(metadata["nonce"],validate=True)
    payload = AESGCM(key).decrypt(nonce,raw[start+length:],header)
    if len(payload) != metadata["bytes"] or hashlib.sha256(payload).hexdigest() != expected_sha:
        raise ValueError("decrypted artifact identity differs")
    validate_payload(payload, expected_target)
    with output.open("xb") as stream:
        stream.write(payload)
    return {"bytes":len(payload),"sha256":expected_sha,"authenticated":True}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode",required=True)
    make = sub.add_parser("prepare")
    make.add_argument("--key-dir",type=Path,required=True)
    extract = sub.add_parser("unseal")
    extract.add_argument("--key-dir",type=Path,required=True)
    extract.add_argument("--input",type=Path,required=True)
    extract.add_argument("--out",type=Path,required=True)
    extract.add_argument("--sha256",required=True)
    extract.add_argument("--pilot-sha",required=True)
    extract.add_argument("--target", default="aarch64-linux-android",
                         choices=["aarch64-linux-android", LOGIN_TARGET])
    args = parser.parse_args()
    result = prepare(args.key_dir) if args.mode == "prepare" else unseal(
        args.input,args.key_dir/"private.pem",args.out,args.sha256,args.pilot_sha,args.target)
    print(json.dumps(result))
