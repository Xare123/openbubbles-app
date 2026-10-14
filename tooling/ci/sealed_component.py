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

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

MAGIC = b"OB-CORTEN-SEALED-1\x00"
LIMIT = 256 * 1024 * 1024


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


def seal(binary, public_path, output, source, pilot):
    if not 0 < binary.stat().st_size <= LIMIT:
        raise ValueError("component size outside bound")
    public = serialization.load_pem_public_key(public_path.read_bytes())
    if not isinstance(public, rsa.RSAPublicKey) or public.key_size != 3072:
        raise ValueError("expected one-use RSA3072 public key")
    payload = binary.read_bytes()
    content_key = AESGCM.generate_key(bit_length=256)
    nonce = os.urandom(12)
    metadata = {"version":1,"application_sha":source,"pilot_sha":pilot,
        "target":"aarch64-linux-android","bytes":len(payload),
        "sha256":hashlib.sha256(payload).hexdigest(),
        "public_key_sha256":hashlib.sha256(public_bytes(public)).hexdigest(),
        "nonce":base64.b64encode(nonce).decode(),
        "wrapped_key":base64.b64encode(public.encrypt(content_key,oaep())).decode()}
    header = json.dumps(metadata,sort_keys=True,separators=(",",":")).encode()
    encrypted = AESGCM(content_key).encrypt(nonce,payload,header)
    with output.open("xb") as stream:
        stream.write(MAGIC + struct.pack(">I",len(header)) + header + encrypted)
    return {key:metadata[key] for key in ("bytes","sha256","public_key_sha256","target")}


def unseal(envelope, private_path, output, expected_sha, expected_pilot):
    if not 0 < envelope.stat().st_size <= LIMIT + 8192:
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
            or metadata.get("target") != "aarch64-linux-android"):
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
    if (payload[:6] != b"\x7fELF\x02\x01" or
            struct.unpack_from("<HH",payload,16) != (3,183)):
        raise ValueError("expected Android AArch64 PIE")
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
    args = parser.parse_args()
    result = prepare(args.key_dir) if args.mode == "prepare" else unseal(
        args.input,args.key_dir/"private.pem",args.out,args.sha256,args.pilot_sha)
    print(json.dumps(result))
