import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:tuple/tuple.dart';

String encryptAESCryptoJS(Uint8List plainText, String passphrase) {
  try {
    final salt = genRandomWithNonZero(8);
    var keyndIV = deriveKeyAndIV(passphrase, salt);
    final encrypted = _processAesCbcPkcs7(
      forEncryption: true,
      input: plainText,
      key: keyndIV.item1,
      iv: keyndIV.item2,
    );
    Uint8List encryptedBytesWithSalt = Uint8List.fromList(
      createUint8ListFromString("Salted__") + salt + encrypted,
    );
    return base64.encode(encryptedBytesWithSalt);
  } catch (error) {
    rethrow;
  }
}

List<int> decryptAESCryptoJS(String encrypted, String passphrase) {
  try {
    Uint8List encryptedBytesWithSalt = base64.decode(encrypted);

    Uint8List encryptedBytes = encryptedBytesWithSalt.sublist(
      16,
      encryptedBytesWithSalt.length,
    );
    final salt = encryptedBytesWithSalt.sublist(8, 16);
    var keyndIV = deriveKeyAndIV(passphrase, salt);
    return _processAesCbcPkcs7(
      forEncryption: false,
      input: encryptedBytes,
      key: keyndIV.item1,
      iv: keyndIV.item2,
    );
  } catch (error) {
    rethrow;
  }
}

Uint8List _processAesCbcPkcs7({
  required bool forEncryption,
  required Uint8List input,
  required Uint8List key,
  required Uint8List iv,
}) {
  final cipher = PaddedBlockCipher('AES/CBC/PKCS7')
    ..init(
      forEncryption,
      PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>, Null>(
        ParametersWithIV<KeyParameter>(KeyParameter(key), iv),
        null,
      ),
    );
  return cipher.process(input);
}

Tuple2<Uint8List, Uint8List> deriveKeyAndIV(String passphrase, Uint8List salt) {
  var password = createUint8ListFromString(passphrase);
  Uint8List concatenatedHashes = Uint8List(0);
  Uint8List currentHash = Uint8List(0);
  bool enoughBytesForKey = false;
  Uint8List preHash = Uint8List(0);

  while (!enoughBytesForKey) {
    // int preHashLength = currentHash.length + password.length + salt.length;
    if (currentHash.isNotEmpty) {
      preHash = Uint8List.fromList(currentHash + password + salt);
    } else {
      preHash = Uint8List.fromList(password + salt);
    }

    currentHash = md5.convert(preHash).bytes as Uint8List;
    concatenatedHashes = Uint8List.fromList(concatenatedHashes + currentHash);
    if (concatenatedHashes.length >= 48) enoughBytesForKey = true;
  }

  var keyBtyes = concatenatedHashes.sublist(0, 32);
  var ivBtyes = concatenatedHashes.sublist(32, 48);
  return Tuple2(keyBtyes, ivBtyes);
}

Uint8List createUint8ListFromString(String s) {
  var ret = Uint8List(s.length);
  for (var i = 0; i < s.length; i++) {
    ret[i] = s.codeUnitAt(i);
  }
  return ret;
}

Uint8List genRandomWithNonZero(int seedLength) {
  final random = Random.secure();
  const int randomMax = 245;
  final Uint8List uint8list = Uint8List(seedLength);
  for (int i = 0; i < seedLength; i++) {
    uint8list[i] = random.nextInt(randomMax) + 1;
  }
  return uint8list;
}
