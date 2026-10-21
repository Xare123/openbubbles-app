import 'package:bluebubbles/services/backend/settings/client_update_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('client update build comparison', () {
    test('ignores the observed desktop release tag without throwing', () {
      expect(isNewerClientUpdateBuild('desktop.94', '2227'), isFalse);
    });

    test('accepts a higher numeric build', () {
      expect(isNewerClientUpdateBuild('2228', '2227'), isTrue);
    });

    test('ignores an equal build', () {
      expect(isNewerClientUpdateBuild('2227', '2227'), isFalse);
    });

    test('ignores an older build', () {
      expect(isNewerClientUpdateBuild('2226', '2227'), isFalse);
    });

    test('ignores a missing release build', () {
      expect(isNewerClientUpdateBuild('', '2227'), isFalse);
    });

    test('does not compare an unrecognized installed build', () {
      expect(isNewerClientUpdateBuild('2228', 'unknown'), isFalse);
    });

    test('ignores a release code outside the integer range', () {
      expect(
        isNewerClientUpdateBuild('99999999999999999999999999999999', '2227'),
        isFalse,
      );
    });

    test('rejects a signed installed code instead of announcing an update', () {
      expect(isNewerClientUpdateBuild('2228', '-1'), isFalse);
    });

    test('does not interpret an entire version as its build suffix', () {
      expect(isNewerClientUpdateBuild('1.15.0+2228', '2227'), isFalse);
    });

    test('compares numeric values rather than text ordering', () {
      expect(isNewerClientUpdateBuild('10', '9'), isTrue);
    });

    test('rejects trailing line terminators', () {
      expect(isNewerClientUpdateBuild('2228\n', '2227'), isFalse);
    });
  });
}
