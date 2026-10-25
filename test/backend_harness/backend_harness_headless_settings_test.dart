import 'dart:io';

import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ObservedSettingsService extends SettingsService {
  final startupCalls = <(bool, bool)>[];

  @override
  Future<bool> setupLaunchAtStartup(bool enabled, bool minimized) async {
    startupCalls.add((enabled, minimized));
    return enabled;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SettingsService previous;
  late _ObservedSettingsService service;
  var localAuthCalls = 0;
  const channel = MethodChannel('plugins.flutter.io/local_auth');

  setUp(() {
    previous = ss;
    service = _ObservedSettingsService();
    ss = service;
    localAuthCalls = 0;
    SharedPreferences.setMockInitialValues({
      'launchAtStartup': true,
      'launchAtStartupMinimized': true,
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async {
          localAuthCalls++;
          return false;
        });
  });

  tearDown(() {
    ss = previous;
    SharedPreferences.resetStatic();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'headless settings preserve preferences without desktop setup',
    () async {
      await service.init(headless: true);
      expect(service.initCompleted.isCompleted, isTrue);
      expect(service.settings.launchAtStartup.value, isTrue);
      expect(service.settings.launchAtStartupMinimized.value, isTrue);
      expect(service.startupCalls, isEmpty);
      expect(localAuthCalls, 0);
      expect(service.prefs.getBool('launchAtStartup'), isTrue);
    },
    skip: !Platform.isWindows,
  );

  test(
    'interactive Windows settings retain desktop startup setup',
    () async {
      await service.init();
      expect(service.initCompleted.isCompleted, isTrue);
      expect(service.startupCalls, [(true, true)]);
      expect(service.settings.launchAtStartup.value, isTrue);
    },
    skip: !Platform.isWindows,
  );
}
