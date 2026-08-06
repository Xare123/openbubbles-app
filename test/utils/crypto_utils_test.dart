import 'dart:convert';
import 'dart:typed_data';

import 'package:bluebubbles/utils/crypto_utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'decrypts ciphertext produced by encrypt 5.0.3 and PointyCastle 3.9.1',
    () {
      const legacyCiphertext = 'U2FsdGVkX18BAgMEBQYHCMKHfN98FBlrgpFZzZ/ppiE=';

      final plaintext = decryptAESCryptoJS(
        legacyCiphertext,
        'migration-passphrase',
      );

      expect(utf8.decode(plaintext), 'Cloud Sync V2');
    },
  );

  test('decrypts the existing CryptoJS and OpenSSL salted golden vector', () {
    const legacyCiphertext =
        'U2FsdGVkX18BAgMEBQYHCFYcZ44sOba1yw50QCJrq2wgOdqrSkV9DGT+RexENXMJ';

    final plaintext = decryptAESCryptoJS(legacyCiphertext, 'test-passphrase');

    expect(utf8.decode(plaintext), 'OpenBubbles Cloud Sync V2');
  });

  test(
    'PointyCastle 4 implementation round-trips the existing wire format',
    () {
      final plaintext = Uint8List.fromList(
        utf8.encode('OpenBubbles ObjectBox 5 migration probe'),
      );

      final ciphertext = encryptAESCryptoJS(plaintext, 'probe-passphrase');
      final decrypted = decryptAESCryptoJS(ciphertext, 'probe-passphrase');

      expect(decrypted, plaintext);
      expect(base64Decode(ciphertext).sublist(0, 8), ascii.encode('Salted__'));
    },
  );
}
