// This test exercises the existing locked Windows plugin's real JSON engine.
// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

import 'windows_backend_harness_storage.dart';

final class _OrdinaryPaths extends PathProviderWindows {
  _OrdinaryPaths(this.directory);
  final Directory directory;
  var supportCalls = 0;

  @override
  Future<String?> getApplicationSupportPath() async {
    supportCalls++;
    return directory.path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory fixture;
  late String fixtureResolved;
  late Directory profile;
  late Directory ordinary;
  late _OrdinaryPaths ordinaryPaths;
  late PathProviderPlatform previousPaths;
  late SharedPreferencesStorePlatform previousPreferences;

  setUp(() {
    previousPaths = PathProviderPlatform.instance;
    previousPreferences = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    fixture = Directory.systemTemp.createTempSync(
      'openbubbles-backend-profile-',
    );
    fixtureResolved = fixture.resolveSymbolicLinksSync();
    profile = Directory(path.join(fixture.path, 'private'))..createSync();
    ordinary = Directory(path.join(fixture.path, 'ordinary-control'))
      ..createSync();
    ordinaryPaths = _OrdinaryPaths(ordinary);
    PathProviderPlatform.instance = ordinaryPaths;
    SharedPreferencesStorePlatform.instance = SharedPreferencesWindows()
      ..pathProvider = ordinaryPaths;
  });

  tearDown(() {
    SharedPreferences.resetStatic();
    PathProviderPlatform.instance = previousPaths;
    SharedPreferencesStorePlatform.instance = previousPreferences;
    // Delete only the exact synthetic directory this test created.
    expect(fixture.resolveSymbolicLinksSync(), fixtureResolved);
    expect(
      path.basename(fixture.path),
      startsWith('openbubbles-backend-profile-'),
    );
    expect(
      FileSystemEntity.typeSync(fixture.path, followLinks: false),
      FileSystemEntityType.directory,
    );
    fixture.deleteSync(recursive: true);
  });

  test(
    'real preferences persist under the same private support root',
    () async {
      BackendHarnessWindowsStorage.bindExistingDirectory(() => profile);
      expect((await getApplicationSupportDirectory()).path, profile.path);
      expect((await getApplicationDocumentsDirectory()).path, profile.path);
      expect(
        (await getApplicationCacheDirectory()).path,
        path.join(profile.path, 'cache'),
      );
      expect(
        (await getTemporaryDirectory()).path,
        path.join(profile.path, 'tmp'),
      );
      expect(
        (await getDownloadsDirectory())!.path,
        path.join(profile.path, 'downloads'),
      );
      final preferences = await SharedPreferences.getInstance();
      expect(
        await preferences.setString('backendProfileProbe', 'synthetic'),
        isTrue,
      );
      final saved = File(path.join(profile.path, 'shared_preferences.json'));
      expect(jsonDecode(saved.readAsStringSync()), {
        'flutter.backendProfileProbe': 'synthetic',
      });

      SharedPreferences.resetStatic();
      BackendHarnessWindowsStorage.bindExistingDirectory(() => profile);
      final reloaded = await SharedPreferences.getInstance();
      expect(reloaded.getString('backendProfileProbe'), 'synthetic');
      expect(ordinaryPaths.supportCalls, 0);
      expect(ordinary.listSync(), isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test(
    'already-loaded preferences refuse rebinding without a reset',
    () async {
      await SharedPreferences.getInstance();
      final loadedStore = SharedPreferencesStorePlatform.instance;
      final callsBefore = ordinaryPaths.supportCalls;
      expect(
        () => BackendHarnessWindowsStorage.bindExistingDirectory(() => profile),
        throwsStateError,
      );
      expect(identical(PathProviderPlatform.instance, ordinaryPaths), isTrue);
      expect(
        identical(SharedPreferencesStorePlatform.instance, loadedStore),
        isTrue,
      );
      expect(ordinaryPaths.supportCalls, callsBefore);
      expect(profile.listSync(), isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test(
    'changed profile refuses native paths and persistent preference writes',
    () async {
      var selected = profile;
      BackendHarnessWindowsStorage.bindExistingDirectory(() => selected);
      final preferences = await SharedPreferences.getInstance();
      expect(
        await preferences.setString('backendProfileProbe', 'original'),
        isTrue,
      );
      final saved = File(path.join(profile.path, 'shared_preferences.json'));
      final before = saved.readAsStringSync();
      selected = ordinary;
      await expectLater(getApplicationSupportDirectory(), throwsStateError);
      expect(
        await preferences.setString('backendProfileProbe', 'changed'),
        isFalse,
      );
      expect(saved.readAsStringSync(), before);
      expect(ordinary.listSync(), isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test(
    'marked-profile installation is closed in the default build',
    () {
      expect(
        BackendHarnessWindowsStorage.installMarkedProfile,
        throwsStateError,
      );
      expect(identical(PathProviderPlatform.instance, ordinaryPaths), isTrue);
      expect(profile.listSync(), isEmpty);
    },
    skip: !Platform.isWindows,
  );
}
