import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

void main() {
  late Directory testRoot;
  late AttachmentDownloadService service;
  late _ControlledBackend fakeBackend;

  setUp(() async {
    Get.testMode = true;
    Get.reset();
    ss.settings = Settings();
    ss.settings.autoSave.value = false;
    testRoot = await Directory.systemTemp.createTemp(
      'attachment-download-service-v2-queue-',
    );
    fs.appDocDir = testRoot;
    fakeBackend = _ControlledBackend();
    backend = fakeBackend;
    service = AttachmentDownloadService();
    attachmentDownloader = service;
    Get.put<AttachmentDownloadService>(service);
  });

  tearDown(() async {
    fakeBackend.failAllPending();
    await _waitUntil(() => service.downloaders.isEmpty);
    Get.reset();
    if (await testRoot.exists()) {
      await testRoot.delete(recursive: true);
    }
  });

  test('two queued V2 downloads serialize', () async {
    final first = _attachment('v2-first', _v2Metadata());
    final second = _attachment('v2-second', _v2Metadata());

    service.startDownload(first);
    first.metadata!
      ..clear()
      ..['cloud'] = 'mutated-after-admission';
    service.startDownload(second);

    expect(fakeBackend.calledGuids, <String>['v2-first']);
    expect(service.downloaders, <String>['v2-first', 'v2-second']);

    fakeBackend.failCall(0);
    await _waitUntil(() => fakeBackend.calledGuids.length == 2);

    expect(fakeBackend.calledGuids, <String>['v2-first', 'v2-second']);
    fakeBackend.failCall(1);
    await _waitUntil(() => service.downloaders.isEmpty);
  });

  test('missing projected size uses the transport progress total', () async {
    final attachment = _attachment('v2-progress-without-size', _v2Metadata())
      ..totalBytes = null;
    final controller = service.startDownload(attachment);

    await _waitUntil(() => fakeBackend.calledGuids.isNotEmpty);
    fakeBackend.reportProgress(0, 4, 8);

    expect(controller.progress.value, 0.5);
    fakeBackend.failCall(0);
    await _waitUntil(() => service.downloaders.isEmpty);
  });

  test('a profile gallery can join one in-flight download', () async {
    final attachment = _attachment('v2-profile-shared-download', _v2Metadata());
    final original = service.getOrStartDownload(attachment);
    PlatformFile? completed;

    final joined = service.getOrStartDownload(
      attachment,
      onComplete: (file) => completed = file,
      prioritized: true,
    );

    expect(identical(joined, original), isTrue);
    expect(fakeBackend.calledGuids, <String>['v2-profile-shared-download']);

    fakeBackend.succeedCall(0, <int>[1, 2, 3, 4]);
    await _waitUntil(() => completed != null);
    await _waitUntil(() => service.downloaders.isEmpty);

    expect(completed!.path, attachment.path);
    expect(await File(attachment.path).readAsBytes(), <int>[1, 2, 3, 4]);
    expect(service.getController(attachment.guid), isNull);
  });

  test('fullscreen redownload joins the active transfer without deleting its target', () async {
    final attachment = _attachment('v2-fullscreen-redownload', _v2Metadata());
    final target = File(attachment.path);
    await target.create(recursive: true);
    await target.writeAsBytes(<int>[9, 9, 9], flush: true);
    service.startDownload(attachment);
    PlatformFile? completed;

    await AttachmentsService().redownloadAttachment(
      attachment,
      onComplete: (file) => completed = file,
    );

    expect(fakeBackend.calledGuids, <String>['v2-fullscreen-redownload']);
    expect(await target.readAsBytes(), <int>[9, 9, 9]);
    fakeBackend.succeedCall(0, <int>[4, 3, 2, 1]);
    await _waitUntil(() => completed != null);
    await _waitUntil(() => service.downloaders.isEmpty);
    expect(await target.readAsBytes(), <int>[4, 3, 2, 1]);
  });

  test('a temporary attachment cannot strand the shared queue', () async {
    final attachment = _attachment('temp-profile-download', _v2Metadata());
    var failed = false;

    service.startDownload(attachment, onError: () => failed = true);
    await _waitUntil(() => service.downloaders.isEmpty);

    expect(failed, isTrue);
    expect(fakeBackend.calledGuids, isEmpty);
    expect(service.getController(attachment.guid), isNull);
  });

  test('legacy download can run beside one active V2 download', () async {
    final v2 = _attachment('v2-with-legacy', _v2Metadata());
    final legacy = _attachment('legacy-with-v2', <String, dynamic>{
      'cloud': 'legacy-source',
    });

    service.startDownload(v2);
    service.startDownload(legacy);

    expect(fakeBackend.calledGuids, <String>[
      'v2-with-legacy',
      'legacy-with-v2',
    ]);
    fakeBackend.failCall(0);
    fakeBackend.failCall(1);
    await _waitUntil(() => service.downloaders.isEmpty);
  });

  test('failed first V2 download is removed and admits the next', () async {
    final first = _attachment('v2-failing', _v2Metadata());
    final second = _attachment('v2-after-failure', _v2Metadata());

    service.startDownload(first);
    service.startDownload(second);
    expect(fakeBackend.calledGuids, <String>['v2-failing']);

    fakeBackend.failCall(0);
    await _waitUntil(() => fakeBackend.calledGuids.length == 2);

    expect(service.getController(first.guid), isNull);
    expect(service.downloaders, <String>['v2-after-failure']);
    expect(fakeBackend.calledGuids, <String>['v2-failing', 'v2-after-failure']);

    fakeBackend.failCall(1);
    await _waitUntil(() => service.downloaders.isEmpty);
  });

  test('existing V2 final target is preserved on failure', () async {
    final attachment = _attachment('v2-preserve-target', _v2Metadata());
    final target = File(attachment.path);
    const existingBytes = <int>[0x50, 0x52, 0x45, 0x53, 0x45, 0x52, 0x56, 0x45];
    await target.create(recursive: true);
    await target.writeAsBytes(existingBytes, flush: true);

    service.startDownload(attachment);
    attachment.metadata!
      ..clear()
      ..['cloud'] = 'mutated-after-admission';
    fakeBackend.failCall(0);
    await _waitUntil(() => service.downloaders.isEmpty);

    expect(await target.exists(), isTrue);
    expect(await target.readAsBytes(), existingBytes);
  });

  test(
    'malformed V2-like provenance never deletes an existing target',
    () async {
      final attachment = _attachment('v2-malformed-target', <String, dynamic>{
        cloudAttachmentV2MetadataKey: true,
        'cloud': 'legacy-source',
        'rustpush': 'ids-source',
      });
      final target = File(attachment.path);
      const existingBytes = <int>[0x53, 0x41, 0x46, 0x45];
      await target.create(recursive: true);
      await target.writeAsBytes(existingBytes, flush: true);

      service.startDownload(attachment);
      fakeBackend.failCall(0);
      await _waitUntil(() => service.downloaders.isEmpty);

      expect(await target.exists(), isTrue);
      expect(await target.readAsBytes(), existingBytes);
    },
  );

  test('an unavailable transport never deletes an existing target', () async {
    final attachment = _attachment(
      'unavailable-preserve-target',
      <String, dynamic>{},
    );
    final target = File(attachment.path);
    const existingBytes = <int>[0x4b, 0x45, 0x45, 0x50];
    await target.create(recursive: true);
    await target.writeAsBytes(existingBytes, flush: true);

    service.startDownload(attachment);
    fakeBackend.failCall(0);
    await _waitUntil(() => service.downloaders.isEmpty);

    expect(await target.exists(), isTrue);
    expect(await target.readAsBytes(), existingBytes);
  });

  test('legacy and IDS generic failures still delete failed targets', () async {
    final cases = <({String guid, Map<String, dynamic> metadata})>[
      (
        guid: 'legacy-delete-target',
        metadata: <String, dynamic>{'cloud': 'legacy'},
      ),
      (
        guid: 'ids-delete-target',
        metadata: <String, dynamic>{'rustpush': 'ids'},
      ),
    ];

    for (final testCase in cases) {
      final attachment = _attachment(testCase.guid, testCase.metadata);
      final target = File(attachment.path);
      await target.create(recursive: true);
      await target.writeAsBytes(<int>[1, 2, 3], flush: true);

      service.startDownload(attachment);
      final callIndex = fakeBackend.calledGuids.length - 1;
      fakeBackend.failCall(callIndex);
      await _waitUntil(() => service.downloaders.isEmpty);

      expect(await target.exists(), isFalse, reason: testCase.guid);
    }
  });
}

Map<String, dynamic> _v2Metadata() => <String, dynamic>{
  cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
  cloudAttachmentV2BodyCapabilityKey:
      CloudAttachmentBodyCapability.materializable.metadataValue,
};

Attachment _attachment(String guid, Map<String, dynamic> metadata) =>
    Attachment(
      guid: guid,
      transferName: 'attachment.bin',
      totalBytes: 8,
      metadata: metadata,
    );

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('Timed out waiting for asynchronous download service state');
}

final class _ControlledBackend implements BackendService {
  final List<String> calledGuids = <String>[];
  final List<Completer<PlatformFile>> _calls = <Completer<PlatformFile>>[];
  final List<void Function(int, int)?> _progressCallbacks = <void Function(int, int)?>[];

  @override
  Future<PlatformFile> downloadAttachment(
    Attachment attachment, {
    void Function(int, int)? onReceiveProgress,
    bool original = false,
    CancelToken? cancelToken,
  }) {
    calledGuids.add(attachment.guid!);
    final completer = Completer<PlatformFile>();
    _calls.add(completer);
    _progressCallbacks.add(onReceiveProgress);
    return completer.future;
  }

  void reportProgress(int index, int received, int total) {
    _progressCallbacks[index]?.call(received, total);
  }

  void failCall(int index) {
    final call = _calls[index];
    if (!call.isCompleted) {
      call.completeError(StateError('synthetic download failure'));
    }
  }

  void succeedCall(int index, List<int> bytes) {
    final call = _calls[index];
    if (!call.isCompleted) {
      call.complete(PlatformFile(
        name: 'attachment.bin',
        size: bytes.length,
        bytes: Uint8List.fromList(bytes),
      ));
    }
  }

  void failAllPending() {
    for (var index = 0; index < _calls.length; index++) {
      failCall(index);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
