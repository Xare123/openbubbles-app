import 'dart:async';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const network = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const permissions = MethodChannel('flutter.baseflow.com/permissions/methods');
  var permissionRequests = 0;
  var networkChecks = 0;

  setUp(() {
    Get.testMode = true;
    ss.settings = Settings();
    permissionRequests = 0;
    networkChecks = 0;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(permissions, (
      _,
    ) async {
      permissionRequests++;
      throw PlatformException(code: 'no_storage_permission');
    });
    binding.defaultBinaryMessenger.setMockMethodCallHandler(network, (_) async {
      networkChecks++;
      return <String>['wifi'];
    });
  });

  tearDown(() {
    expect(
      permissionRequests,
      0,
      reason: 'Private downloads need no storage permission',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(network, null);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(permissions, null);
    Get.reset();
  });

  test(
    'disabled auto-download does not query network or permissions',
    () async {
      ss.settings.autoDownload.value = false;
      expect(await AttachmentsService().canAutoDownload(), isFalse);
      expect(networkChecks, 0);
    },
  );

  test(
    'unrestricted private auto-download needs no platform permission',
    () async {
      expect(await AttachmentsService().canAutoDownload(), isTrue);
      expect(networkChecks, 0);
    },
  );

  for (final transport in ['wifi', 'mobile', 'none', 'ethernet']) {
    test('Wi-Fi-only checks $transport', () async {
      ss.settings.onlyWifiDownload.value = true;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        network,
        (_) async => <String>[transport],
      );
      expect(await AttachmentsService().canAutoDownload(), transport == 'wifi');
    });
  }

  test('Wi-Fi-only fails closed if connectivity is unavailable', () async {
    ss.settings.onlyWifiDownload.value = true;
    binding.defaultBinaryMessenger.setMockMethodCallHandler(network, (_) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await AttachmentsService().canAutoDownload(), isFalse);
  });

  test(
    'turning auto-download off during network check prevents admission',
    () async {
      ss.settings.onlyWifiDownload.value = true;
      final reply = Completer<List<String>>();
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        network,
        (_) => reply.future,
      );
      final allowed = AttachmentsService().canAutoDownload();
      ss.settings.autoDownload.value = false;
      reply.complete(<String>['wifi']);
      expect(await allowed, isFalse);
    },
  );
}
