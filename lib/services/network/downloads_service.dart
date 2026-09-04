import 'package:bluebubbles/services/network/backend_service.dart';
import 'package:bluebubbles/services/network/download_file_utils.dart';
import 'package:bluebubbles/services/rustpush/cloud_sync/cloud_attachment_provenance.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/database/models.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:get/get.dart' hide Response;
import 'package:path/path.dart';
import 'package:universal_io/io.dart';

/// Get an instance of our [AttachmentDownloadService]
AttachmentDownloadService attachmentDownloader = Get.isRegistered<AttachmentDownloadService>()
    ? Get.find<AttachmentDownloadService>() : Get.put(AttachmentDownloadService());

class AttachmentDownloadService extends GetxService {
  int maxDownloads = 2;
  final RxList<String> downloaders = <String>[].obs;
  final Map<String, List<AttachmentDownloadController>> _downloaders = {};

  AttachmentDownloadController? getController(String? guid) {
    return _downloaders.values.flattened.firstWhereOrNull((element) => element.attachment.guid == guid);
  }

  AttachmentDownloadController startDownload(Attachment a,
      {Function(PlatformFile)? onComplete, Function? onError, bool prioritized = false}) {
    return Get.put(AttachmentDownloadController(
      attachment: a,
      onComplete: onComplete,
      onError: onError,
      prioritized: prioritized,
    ), tag: a.guid!);
  }

  void _addToQueue(AttachmentDownloadController downloader) {
    downloaders.add(downloader.attachment.guid!);
    final chatGuid = downloader.attachment.message.target?.chat.target?.guid ?? "unknown";
    if (_downloaders.containsKey(chatGuid)) {
      if (downloader.prioritized) {
        _downloaders[chatGuid]!.insert(0, downloader);
      } else {
        _downloaders[chatGuid]!.add(downloader);
      }
    } else {
      _downloaders[chatGuid] = [downloader];
    }
    _fetchNext();
  }

  void _removeFromQueue(AttachmentDownloadController downloader) {
    downloaders.remove(downloader.attachment.guid!);
    final chatGuid = downloader.attachment.message.target?.chat.target?.guid ?? "unknown";
    _downloaders[chatGuid]!.removeWhere((e) => e.attachment.guid == downloader.attachment.guid);
    if (_downloaders[chatGuid]!.isEmpty) _downloaders.remove(chatGuid);
    Get.delete<AttachmentDownloadController>(tag: downloader.attachment.guid!);
    _fetchNext();
  }

  void prioritize(AttachmentDownloadController downloader) {
    if (downloader.isFetching) return;
    final chatGuid = downloader.attachment.message.target?.chat.target?.guid ?? "unknown";
    final queue = _downloaders[chatGuid];
    if (queue == null || !queue.remove(downloader)) return;
    queue.insert(0, downloader);
    _fetchNext();
  }

  void _fetchNext() {
    final active = _downloaders.values.flattened
        .where((downloader) => downloader.isFetching)
        .toList(growable: false);
    if (active.length < maxDownloads) {
      final cloudSyncV2DownloadActive = active.any(
        (downloader) =>
            downloader.downloadLane == CloudAttachmentDownloadLane.cloudSyncV2,
      );
      bool canStart(AttachmentDownloadController downloader) =>
          !downloader.isFetching &&
          canStartCloudAttachmentDownload(
            candidateLane: downloader.downloadLane,
            cloudSyncV2DownloadActive: cloudSyncV2DownloadActive,
          );
      AttachmentDownloadController? activeChatDownloader;
      // first check if we have an active chat that needs downloads, if so prioritize that chat
      if (cm.activeChat != null && _downloaders.containsKey(cm.activeChat!.chat.guid)) {
        activeChatDownloader = _downloaders[cm.activeChat!.chat.guid]!.firstWhereOrNull(canStart);
        activeChatDownloader?.fetchAttachment();
      }
      // otherwise just grab a random attachment that needs fetching
      if (activeChatDownloader == null) {
        _downloaders.values.flattened.firstWhereOrNull(canStart)?.fetchAttachment();
      }
    }
  }
}

class AttachmentDownloadController extends GetxController {
  final Attachment attachment;
  final CloudAttachmentDownloadLane downloadLane;
  final List<Function(PlatformFile)> completeFuncs = [];
  final List<Function> errorFuncs = [];
  final RxnNum progress = RxnNum();
  final Rxn<PlatformFile> file = Rxn<PlatformFile>();
  final RxBool error = RxBool(false);
  final bool prioritized;
  Stopwatch stopwatch = Stopwatch();
  bool isFetching = false;

  AttachmentDownloadController({
    required this.attachment,
    Function(PlatformFile)? onComplete,
    Function? onError,
    this.prioritized = false,
  }) : downloadLane = cloudAttachmentDownloadLaneFor(attachment.metadata) {
    if (onComplete != null) completeFuncs.add(onComplete);
    if (onError != null) errorFuncs.add(onError);
  }

  @override
  void onInit() {
    attachmentDownloader._addToQueue(this);
    super.onInit();
  }

  Future<void> fetchAttachment() async {
    if (attachment.guid == null || attachment.guid!.contains("temp")) return;
    isFetching = true;
    stopwatch.start();
    PlatformFile response;
    try {
      response = await backend.downloadAttachment(
        attachment,
        onReceiveProgress: (count, total) {
          final expectedTotal = kIsWeb
              ? total
              : ((attachment.totalBytes ?? 0) > 0 ? attachment.totalBytes! : total);
          setProgress(expectedTotal > 0 ? count / expectedTotal : 0);
        },
      );
      if (!kIsWeb) {
        final file = await materializeDownloadedFile(
          targetPath: attachment.path,
          bytes: response.bytes,
          sourcePath: response.path,
        );
        response.path = file.path;
      }
    } catch (e, stack) {
      Logger.error("Attachment fetch error", error: e, trace: stack);
      try {
        if (!kIsWeb &&
            shouldDeleteFailedAttachmentTarget(downloadLane)) {
          File file = File(attachment.path);
          if (await file.exists()) {
            await file.delete();
          }
        }
        for (Function f in errorFuncs) {
          f.call();
        }

        error.value = true;
      } finally {
        attachmentDownloader._removeFromQueue(this);
      }
      return;
    }
    Logger.info("Finished fetching attachment");
    stopwatch.stop();
    Logger.info("Attachment downloaded in ${stopwatch.elapsedMilliseconds} ms");

    try {
      // Compress the attachment
      if (!kIsWeb) {
        await as.loadAndGetProperties(attachment, actualPath: attachment.path);
        attachment.save(null);
      }
    } catch (ex) {
      // So what if it crashes here.... I don't care...
    }

    // Finish the downloader
    attachmentDownloader._removeFromQueue(this);
    // Add attachment to sink based on if we got data

    file.value = response;
    for (Function f in completeFuncs) {
      f.call(file.value);
    }
    if (ss.settings.autoSave.value
        && !kIsWeb
        && !kIsDesktop
        && !(attachment.isOutgoing ?? false)
        && !(attachment.message.target?.isInteractive ?? false)) {
      String filePath = "/storage/emulated/0/Download/";
      if (attachment.mimeType?.startsWith("image") ?? false) {
        await as.saveToDisk(file.value!, isAutoDownload: true);
      } else if (file.value?.bytes != null) {
        await File(join(filePath, file.value!.name)).writeAsBytes(file.value!.bytes!);
      }
    }
  }

  void setProgress(double value) {
    if (value.isNaN) {
      value = 0;
    } else if (value.isInfinite) {
      value = 1.0;
    } else if (value.isNegative) {
      value = 0;
    }

    progress.value = value.clamp(0, 1);
  }
}
