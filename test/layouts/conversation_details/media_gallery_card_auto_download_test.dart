import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bluebubbles/app/layouts/conversation_details/widgets/conversation_media_section.dart';
import 'package:bluebubbles/app/layouts/conversation_details/widgets/media_gallery_card.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/ScLbtAAAAABJRU5ErkJggg==',
);

Attachment _photo(
  String guid, {
  String type = 'image/png',
  String name = 'photo.png',
}) => Attachment(
  guid: guid,
  mimeType: type,
  transferName: name,
  totalBytes: _png.length,
  metadata: {
    cloudAttachmentV2MetadataKey: cloudAttachmentV2MetadataVersion,
    cloudAttachmentV2BodyCapabilityKey:
        CloudAttachmentBodyCapability.materializable.metadataValue,
  },
);

Widget _card(Attachment attachment) => GetMaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 220,
        height: 220,
        child: MediaGalleryCard(
          key: ValueKey(attachment.guid),
          attachment: attachment,
        ),
      ),
    ),
  ),
);

void main() {
  late Directory root;
  late _ControlledBackend fake;
  late AttachmentDownloadService downloads;
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const network = MethodChannel('dev.fluttercommunity.plus/connectivity');

  setUp(() async {
    Get.testMode = true;
    Get.reset();
    ss.settings = Settings();
    ss.settings.autoSave.value = false;
    root = await Directory.systemTemp.createTemp('gallery-auto-download-');
    fs.appDocDir = root;
    as = _TestAttachmentsService();
    fake = _ControlledBackend();
    backend = fake;
    downloads = AttachmentDownloadService();
    attachmentDownloader = downloads;
    Get.put<AttachmentDownloadService>(downloads);
  });

  tearDown(() async {
    expect(downloads.downloaders, isEmpty);
    binding.defaultBinaryMessenger.setMockMethodCallHandler(network, null);
    Get.reset();
    await root.delete(recursive: true);
  });

  void galleryTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await _settleDownloads(
          tester,
          downloads,
          failPending: fake.failPending,
        );
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
        // Image.file may still be releasing its read handle after unmount on
        // Windows. Flush both zones before the test-owned directory is removed.
        for (var i = 0; i < 5; i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump();
        }
      }
    });
  }

  galleryTest('photo downloads without a tap and renders the completed image', (
    tester,
  ) async {
    final photo = _photo('automatic-photo');
    await tester.pumpWidget(_card(photo));
    await tester.pump();
    expect(fake.guids, ['automatic-photo']);
    expect(downloads.getController(photo.guid)!.prioritized, isFalse);
    fake.calls.first.complete(
      PlatformFile(name: 'photo.png', size: _png.length, bytes: _png),
    );
    await _settleDownloads(tester, downloads);
    await tester.pumpAndSettle();
    expect(find.byType(ImageDisplay), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(fake.guids, ['automatic-photo']);
    await tester.pumpWidget(const SizedBox());
  });

  galleryTest(
    'failure stays manual with no automatic retry or toast on rebuild',
    (tester) async {
      final photo = _photo('failed-photo');
      await tester.pumpWidget(_card(photo));
      await tester.pump();
      fake.failPending();
      await _settleDownloads(tester, downloads);
      await tester.pumpWidget(_card(photo));
      await tester.pumpAndSettle();
      expect(fake.guids, ['failed-photo']);
      expect(find.text('Failed to download attachment!'), findsNothing);
      await tester.tap(find.byType(InkWell).first);
      await tester.pump();
      expect(fake.guids, ['failed-photo', 'failed-photo']);
      expect(downloads.getController(photo.guid)!.prioritized, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  galleryTest('disabled auto-download still permits an explicit tap', (
    tester,
  ) async {
    ss.settings.autoDownload.value = false;
    await tester.pumpWidget(_card(_photo('manual-photo')));
    await tester.pump();
    expect(fake.guids, isEmpty);
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    expect(fake.guids, ['manual-photo']);
    await tester.pumpWidget(const SizedBox());
  });

  for (final type in ['image/gif', 'video/quicktime', 'application/pdf']) {
    galleryTest('$type stays available but is not auto-downloaded', (
      tester,
    ) async {
      await tester.pumpWidget(
        _card(_photo('manual-media', type: type, name: 'media.bin')),
      );
      await tester.pump();
      expect(fake.guids, isEmpty);
      await tester.tap(find.byType(InkWell).first);
      await tester.pump();
      expect(fake.guids, ['manual-media']);
      await tester.pumpWidget(const SizedBox());
    });
  }

  galleryTest('existing downloader is joined, not duplicated', (tester) async {
    final photo = _photo('shared-photo');
    final original = downloads.getOrStartDownload(photo);
    await tester.pumpWidget(_card(photo));
    await tester.pump();
    expect(identical(downloads.getController(photo.guid), original), isTrue);
    expect(fake.guids, ['shared-photo']);
    expect(original.completeFuncs, hasLength(1));
    await tester.pumpWidget(const SizedBox());
    expect(original.completeFuncs, isEmpty);
    expect(original.errorFuncs, isEmpty);
  });

  galleryTest('cached photo and redacted photo do not trigger downloads', (
    tester,
  ) async {
    final photo = _photo('cached-photo');
    await tester.runAsync(() async {
      final cached = File(photo.path);
      await cached.create(recursive: true);
      await cached.writeAsBytes(_png);
    });
    await tester.pumpWidget(_card(photo));
    await tester.pumpAndSettle();
    expect(fake.guids, isEmpty);
    expect(find.byType(ImageDisplay), findsOneWidget);
    ss.settings.redactedMode.value = true;
    ss.settings.hideAttachments.value = true;
    await tester.pumpWidget(_card(_photo('redacted-photo')));
    await tester.pump();
    expect(fake.guids, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });

  for (final transport in ['wifi', 'mobile']) {
    galleryTest('gallery respects Wi-Fi-only on $transport', (tester) async {
      ss.settings.onlyWifiDownload.value = true;
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        network,
        (_) async => <String>[transport],
      );
      await tester.pumpWidget(_card(_photo('wifi-photo')));
      await tester.pump();
      expect(fake.guids.length, transport == 'wifi' ? 1 : 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  galleryTest('manual tap wins while automatic network check is pending', (
    tester,
  ) async {
    ss.settings.onlyWifiDownload.value = true;
    final reply = Completer<List<String>>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      network,
      (_) => reply.future,
    );
    await tester.pumpWidget(_card(_photo('manual-race')));
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    reply.complete(['wifi']);
    await tester.pump();
    expect(fake.guids, ['manual-race']);
    expect(downloads.getController('manual-race')!.prioritized, isTrue);
  });

  galleryTest('file cached during network check is reused', (tester) async {
    ss.settings.onlyWifiDownload.value = true;
    final reply = Completer<List<String>>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      network,
      (_) => reply.future,
    );
    final photo = _photo('cached-during-check');
    await tester.pumpWidget(_card(photo));
    await tester.runAsync(() async {
      final cached = File(photo.path);
      await cached.create(recursive: true);
      await cached.writeAsBytes(_png);
    });
    reply.complete(['wifi']);
    await tester.pumpAndSettle();
    expect(fake.guids, isEmpty);
    expect(find.byType(ImageDisplay), findsOneWidget);
  });

  galleryTest('disposal during network check cannot start a download', (
    tester,
  ) async {
    ss.settings.onlyWifiDownload.value = true;
    final reply = Completer<List<String>>();
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      network,
      (_) => reply.future,
    );
    await tester.pumpWidget(_card(_photo('disposed-photo')));
    await tester.pumpWidget(const SizedBox());
    reply.complete(['wifi']);
    await tester.pump();
    expect(fake.guids, isEmpty);
    expect(tester.takeException(), isNull);
  });

  galleryTest(
    '500 photos only queue nearby tiles, with V2 downloads serialized',
    (tester) async {
      final pager = ConversationMediaPager(
        chat: Chat(id: 1, guid: 'chat'),
        loader: ({required direction, cursor, required limit}) async =>
            ChatMediaPage.empty,
      )..seed(List.generate(500, (i) => _photo('photo-$i')), hasNewer: false);
      await tester.pumpWidget(
        GetMaterialApp(
          home: ConversationMediaGallery(
            pager: pager,
            itemBuilder: (_, attachment) => MediaGalleryCard(
              key: ValueKey(attachment.guid),
              attachment: attachment,
              mediaPager: pager,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(downloads.downloaders.length, greaterThan(1));
      expect(downloads.downloaders.length, lessThan(25));
      expect(fake.guids, hasLength(1));
      await tester.pumpWidget(const SizedBox());
      pager.dispose();
    },
  );
}

Future<void> _settleDownloads(
  WidgetTester tester,
  AttachmentDownloadService downloads, {
  void Function()? failPending,
}) async {
  for (var i = 0; i < 200; i++) {
    if (downloads.downloaders.isEmpty) return;
    failPending?.call();
    // Pump the widget-test zone as well as real file IO. Waiting only in
    // runAsync leaves download continuations in the fake zone unprocessed.
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  fail('Download queue did not settle');
}

class _TestAttachmentsService extends AttachmentsService {
  @override
  Future<String?> getImageGalleryThumbnail(String path) async => path;

  @override
  Future<Uint8List?> loadAndGetProperties(
    Attachment attachment, {
    bool onlyFetchData = false,
    String? actualPath,
    bool isPreview = false,
  }) async => null;
}

class _ControlledBackend implements BackendService {
  final guids = <String>[];
  final calls = <Completer<PlatformFile>>[];

  @override
  Future<PlatformFile> downloadAttachment(
    Attachment attachment, {
    void Function(int, int)? onReceiveProgress,
    bool original = false,
    CancelToken? cancelToken,
  }) {
    guids.add(attachment.guid!);
    final reply = Completer<PlatformFile>();
    calls.add(reply);
    return reply.future;
  }

  void failPending() {
    for (final reply in calls) {
      if (!reply.isCompleted) {
        reply.completeError(StateError('synthetic failure'));
      }
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
