import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'OABS hardware transfer stays memory-only and is cleared on success',
    () {
      final setup = File(
        'lib/app/layouts/setup/setup_view.dart',
      ).readAsStringSync();
      final cacheStart = setup.indexOf('Future<void> cacheCode(String code)');
      final cacheEnd = setup.indexOf('\n  }', cacheStart);
      expect(cacheStart, greaterThanOrEqualTo(0));
      expect(cacheEnd, greaterThan(cacheStart));
      final cache = setup.substring(cacheStart, cacheEnd);
      final hardwareCheck = cache.indexOf('isOpenAbsintheTransfer(myData)');
      final transientRetain = cache.indexOf(
        'retainTransientHardwareTransfer(code, myData)',
      );
      final earlyReturn = cache.indexOf('return;', transientRetain);
      final persistentWrite = cache.indexOf('ss.settings.cachedCodes[code]');
      expect(hardwareCheck, greaterThanOrEqualTo(0));
      expect(transientRetain, greaterThan(hardwareCheck));
      expect(earlyReturn, greaterThan(transientRetain));
      expect(persistentWrite, greaterThan(earlyReturn));

      final publishCall =
          setup.indexOf('if (!publishLoginSuccess(attempt: attempt)) return;');
      expect(publishCall, greaterThanOrEqualTo(0));
      final clear = setup.indexOf('clearHardwareTransferMaterial', publishCall);
      final successLog = setup.indexOf('Success registered!', publishCall);
      expect(clear, greaterThan(publishCall));
      expect(successLog, greaterThan(clear));
      expect(setup, contains('_transientHardwareTransfers.remove(code)'));
    },
  );

  test('hardware input never logs a transfer code or decoded payload', () {
    final input = File(
      'lib/app/layouts/setup/pages/rustpush/hw_inp.dart',
    ).readAsStringSync();
    expect(input, isNot(contains('Logger.debug("Here \$text")')));
    expect(input, contains('Logger.debug("Checking hardware setup input")'));
    expect(input, contains('consumeTransientHardwareTransfer(code)'));
    expect(input, contains('ss.settings.cachedCodes.remove(code)'));
    expect(input, isNot(contains('ss.settings.cachedCodes[code] =')));
  });
}
