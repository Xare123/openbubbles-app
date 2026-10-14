import hashlib
from pathlib import Path
import struct
import tempfile
import unittest
from cryptography.exceptions import InvalidTag
import sealed_component as S


class SealedComponentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.keys = self.root / "keys"
        S.prepare(self.keys)
        self.data = bytearray(128)
        self.data[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<HH",self.data,16,3,183)
        self.binary = self.root / "fixture"
        self.binary.write_bytes(self.data)
        self.envelope = self.root / "sealed"
        self.output = self.root / "restored"
        self.sha = hashlib.sha256(self.data).hexdigest()
        S.seal(self.binary,self.keys/"public.pem",self.envelope,"a"*40,"b"*40)

    def tearDown(self):
        self.tmp.cleanup()

    def test_round_trip_restores_only_exact_reviewed_elf(self):
        result = S.unseal(self.envelope,self.keys/"private.pem",self.output,self.sha,"b"*40)
        self.assertTrue(result["authenticated"])
        self.assertEqual(self.output.read_bytes(),self.data)
        self.assertNotIn(b"PRIVATE KEY",self.envelope.read_bytes())

    def test_modified_ciphertext_is_rejected_without_output(self):
        raw=bytearray(self.envelope.read_bytes()); raw[-1]^=1
        self.envelope.write_bytes(raw)
        with self.assertRaises(InvalidTag):
            S.unseal(self.envelope,self.keys/"private.pem",self.output,self.sha,"b"*40)
        self.assertFalse(self.output.exists())

    def test_wrong_candidate_is_rejected(self):
        with self.assertRaisesRegex(ValueError,"reviewed"):
            S.unseal(self.envelope,self.keys/"private.pem",self.output,self.sha,"c"*40)

    def test_never_overwrites_existing_output(self):
        self.output.write_bytes(b"preserve")
        with self.assertRaises(FileExistsError):
            S.unseal(self.envelope,self.keys/"private.pem",self.output,self.sha,"b"*40)
        self.assertEqual(self.output.read_bytes(),b"preserve")


if __name__ == "__main__":
    unittest.main()
