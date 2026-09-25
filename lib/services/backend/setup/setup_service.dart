import 'package:bluebubbles/helpers/backend/startup_tasks.dart';
import 'package:bluebubbles/helpers/network/network_tasks.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:get/get.dart';

SetupService setup = Get.isRegistered<SetupService>() ? Get.find<SetupService>() : Get.put(SetupService());

class SetupService extends GetxService {
  Future<void> startSetup(int numberOfMessagesPerPage, bool skipEmptyChats, bool saveToDownloads) async {
    sync.numberOfMessagesPerPage = numberOfMessagesPerPage;
    sync.skipEmptyChats = skipEmptyChats;
    sync.saveToDownloads = saveToDownloads;
    await sync.startFullSync();
    await finishSetup();
  }

  Future<void> persistSetupCompletion() async {
    ss.settings.finishedSetup.value = true;
    await ss.saveSettings();
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
