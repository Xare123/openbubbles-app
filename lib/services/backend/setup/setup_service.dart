import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:bluebubbles/helpers/network/network_tasks.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:get/get.dart';

SetupService setup = Get.isRegistered<SetupService>() ? Get.find<SetupService>() : Get.put(SetupService());
/// Awaits one platform preference write and treats a false return as failure.
/// This is platform-reported success, not crash-safe durability.
Future<void> checkedPreferenceWrite(Future<bool> Function() write, String label) async {
  final stored = await write();
  if (!stored) throw StateError(label + ' was not stored');
}

class SetupService extends GetxService {
  Future<void> startSetup(int numberOfMessagesPerPage, bool skipEmptyChats, bool saveToDownloads) async {
    sync.numberOfMessagesPerPage = numberOfMessagesPerPage;
    sync.skipEmptyChats = skipEmptyChats;
    sync.saveToDownloads = saveToDownloads;
    await sync.startFullSync();
    await finishSetup();
  }

  Future<void> persistSetupCompletion() async {
    final prior = ss.settings.finishedSetup.value;
    ss.settings.finishedSetup.value = true;
    try {
      await checkedPreferenceWrite(() => ss.prefs.setBool('finishedSetup', true), 'finishedSetup');
    } catch (_) {
      ss.settings.finishedSetup.value = prior;
      rethrow;
    }
  }
  Future<void> runBackgroundStartup() async {
    await StartupTasks.onStartup();
    await NetworkTasks.onConnect();
  }
  Future<void> finishSetup() async {
    await persistSetupCompletion();
    await runBackgroundStartup();
  }
}
