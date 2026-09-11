import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:bluebubbles/cloud_sync_v2_windows_attachment_fixture.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  group('fromId', () {
    test('rejects unknown ids', () {
      for (final id in <String>['', 'text-v2', 'TEXT-V1', ' png-v1', '../escape']) {
        expect(
          () => CloudSyncWindowsAttachmentFixture.fromId(id),
          throwsStateError,
        );
      }
    });

    test('text-v1 is tiny human-readable nonsecret content', () {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('text-v1');
      expect(fixture.id, 'text-v1');
      expect(fixture.filename, 'qualification.txt');
      expect(fixture.mimeType, 'text/plain');
      expect(fixture.uti, 'public.plain-text');
      expect(
        utf8.decode(fixture.bytes),
        'OpenBubbles CloudKit attachment qualification\n',
      );
      expect(fixture.sha256Hex, sha256.convert(fixture.bytes).toString());
      expect(() => fixture.bytes[0] = 0, throwsUnsupportedError);
    });

    test('png-v1 is a valid small PNG with a stable digest', () {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('png-v1');
      expect(fixture.id, 'png-v1');
      expect(fixture.filename, 'qualification.png');
      expect(fixture.mimeType, 'image/png');
      expect(fixture.uti, 'public.png');
      expect(
        fixture.bytes.sublist(0, 8),
        <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
      );
      expect(fixture.bytes.length, lessThan(1024));
      expect(fixture.sha256Hex, sha256.convert(fixture.bytes).toString());
      expect(
        CloudSyncWindowsAttachmentFixture.fromId('png-v1').sha256Hex,
        fixture.sha256Hex,
      );
    });

    test('png-v1 decodes to a real 1x1 image', () async {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('png-v1');
      final codec = await ui.instantiateImageCodec(fixture.bytes);
      final frame = await codec.getNextFrame();
      try {
        expect(frame.image.width, 1);
        expect(frame.image.height, 1);
      } finally {
        frame.image.dispose();
        codec.dispose();
      }
    });
  });

  group('materialize', () {
    late Directory profile;
    setUp(() {
      profile = Directory.systemTemp.createTempSync('obx-windows-attach-fixture-');
    });
    tearDown(() {
      if (profile.existsSync()) profile.deleteSync(recursive: true);
    });

    test('writes the stable private path with exact bytes and digest', () async {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('text-v1');
      final file = await fixture.materialize(profile, 'qual-1');
      expect(
        file.path,
        path.join(profile.path, 'cloud-sync-v2', 'windows-write-fixtures', 'qual-1', 'qualification.txt'),
      );
      final onDisk = await file.readAsBytes();
      expect(onDisk, fixture.bytes);
      expect(sha256.convert(onDisk).toString(), fixture.sha256Hex);
    });

    test('reuses byte-identical files without rewriting', () async {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('png-v1');
      final first = await fixture.materialize(profile, 'reuse-1');
      final second = await fixture.materialize(profile, 'reuse-1');
      expect(second.path, first.path);
      expect(await second.readAsBytes(), fixture.bytes);
    });

    test('refuses to overwrite drifted content and leaves it untouched', () async {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('text-v1');
      final file = await fixture.materialize(profile, 'drift-1');
      await file.writeAsBytes(utf8.encode('tampered'), flush: true);
      await expectLater(fixture.materialize(profile, 'drift-1'), throwsStateError);
      expect(await file.readAsString(), 'tampered');
    });

    test('refuses oversized foreign files without loading them', () async {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('text-v1');
      final dir = Directory(path.join(profile.path, 'cloud-sync-v2', 'windows-write-fixtures', 'bulky-1'));
      await dir.create(recursive: true);
      final bulky = File(path.join(dir.path, 'qualification.txt'));
      await bulky.writeAsBytes(List.filled(1024 * 1024, 65), flush: true);
      await expectLater(fixture.materialize(profile, 'bulky-1'), throwsStateError);
      expect(await bulky.length(), 1024 * 1024);
    });

    test('refuses to overwrite pre-created foreign files', () async {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('text-v1');
      final dir = Directory(path.join(profile.path, 'cloud-sync-v2', 'windows-write-fixtures', 'foreign-1'));
      await dir.create(recursive: true);
      final foreign = File(path.join(dir.path, 'qualification.txt'));
      await foreign.writeAsString('foreign');
      await expectLater(fixture.materialize(profile, 'foreign-1'), throwsStateError);
      expect(await foreign.readAsString(), 'foreign');
    });

    test('rejects invalid request ids and missing profiles', () async {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('text-v1');
      final long = List.filled(65, 'x').join();
      for (final bad in <String>['', 'ABC', '../escape', 'a/b', 'has space', 'under_score', long]) {
        await expectLater(fixture.materialize(profile, bad), throwsStateError);
      }
      await expectLater(
        fixture.materialize(Directory(path.join(profile.path, 'no-such-profile')), 'ok-1'),
        throwsStateError,
      );
    });

    test('rejects a profile that is itself a link', () async {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('text-v1');
      final outer = Directory.systemTemp.createTempSync('obx-windows-attach-link-');
      final real = Directory(path.join(outer.path, 'real'))..createSync();
      final rootLink = Link(path.join(outer.path, 'linked-profile'));
      addTearDown(() {
        if (rootLink.existsSync()) rootLink.deleteSync();
        if (outer.existsSync()) outer.deleteSync(recursive: true);
      });
      try {
        await rootLink.create(real.path);
      } on FileSystemException {
        markTestSkipped('Host forbids link creation, so profile-link coverage cannot run here.');
        return;
      }
      await expectLater(
        fixture.materialize(Directory(rootLink.path), 'link-1'),
        throwsStateError,
      );
    });

    test('rejects symlink escape where the host permits links', () async {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('text-v1');
      final outside = Directory.systemTemp.createTempSync('obx-windows-attach-outside-');
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      });
      try {
        await Link(path.join(profile.path, 'cloud-sync-v2')).create(outside.path);
      } on FileSystemException {
        markTestSkipped('Host forbids link creation, so link-escape coverage cannot run here.');
        return;
      }
      await expectLater(fixture.materialize(profile, 'link-1'), throwsStateError);
    });
  });

  group('materializeForAttachment', () {
    late Directory profile;
    setUp(() {
      profile = Directory.systemTemp.createTempSync('obx-windows-attach-guid-');
    });
    tearDown(() {
      if (profile.existsSync()) profile.deleteSync(recursive: true);
    });

    const guid = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';

    test('writes the canonical attachments destination with exact bytes', () async {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('png-v1');
      final file = await fixture.materializeForAttachment(profile, '${guid}_0');
      expect(
        file.path,
        path.join(profile.path, 'attachments', '${guid}_0', 'qualification.png'),
      );
      final onDisk = await file.readAsBytes();
      expect(onDisk, fixture.bytes);
      expect(sha256.convert(onDisk).toString(), fixture.sha256Hex);
      final again = await fixture.materializeForAttachment(profile, '${guid}_0');
      expect(again.path, file.path);
    });

    test('accepts a bare v4 guid and rejects the rest', () async {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('text-v1');
      final bare = await fixture.materializeForAttachment(profile, guid);
      expect(bare.existsSync(), isTrue);
      for (final bad in <String>[
        '',
        'not-a-uuid',
        '${guid}_1',
        '${guid}_00',
        '${guid}x',
        '6ec0bd7f-11c0-11e3-8f5e-111111111111',
        'zzzzzzzz-58cc-4372-a567-0e02b2c3d479',
      ]) {
        await expectLater(fixture.materializeForAttachment(profile, bad), throwsStateError);
      }
    });

    test('refuses to overwrite drifted attachment content', () async {
      final fixture = CloudSyncWindowsAttachmentFixture.fromId('text-v1');
      final file = await fixture.materializeForAttachment(profile, '${guid}_0');
      await file.writeAsBytes(utf8.encode('tampered'), flush: true);
      await expectLater(fixture.materializeForAttachment(profile, '${guid}_0'), throwsStateError);
      expect(await file.readAsString(), 'tampered');
    });
  });
}
