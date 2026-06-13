import 'package:bluebubbles/app/layouts/settings/pages/server/connection_panel/connection_panel.dart';
import 'package:bluebubbles/app/wrappers/stateful_boilerplate.dart';
import 'package:bluebubbles/helpers/helpers.dart';
import 'package:bluebubbles/models/models.dart' show ServerDetails;
import 'package:bluebubbles/services/services.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:version/version.dart';

class ServerManagementPanelController extends StatefulController {
  final RxnInt latency = RxnInt();
  final RxnString fetchStatus = RxnString();
  final Rx<ServerDetails> serverDetails = Rx(const ServerDetails.empty());
  final RxBool helperBundleStatus = RxBool(false);
  final RxnDouble timeSync = RxnDouble();
  final RxMap<String, dynamic> stats = RxMap({});
  final RxBool hasAccountInfo = RxBool(false);
  final RxBool statsLoadError = RxBool(false);

  // Restart trackers
  int? lastRestart;
  int? lastRestartMessages;
  int? lastRestartPrivateAPI;
  final RxBool isRestarting = false.obs;
  final RxBool isRestartingMessages = false.obs;
  final RxBool isRestartingPrivateAPI = false.obs;
  final RxDouble opacity = 1.0.obs;
  final RxnBool hasCheckedStats = RxnBool(false);

  @override
  void onInit() {
    super.onInit();
    serverDetails.value = SettingsSvc.serverDetails;
  }

  @override
  void onReady() {
    super.onReady();
    getServerStats();
  }

  void getServerStats() async {
    hasCheckedStats.value = false;
    statsLoadError.value = false;
    int now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await HttpSvc.server.ping();
    int later = DateTime.now().toUtc().millisecondsSinceEpoch;
    latency.value = later - now;
    HttpSvc.server.info().then((response) {
      final String macOSVersionStr = response.data['data']['os_version'] ?? '0.0';
      final String serverVersionStr = response.data['data']['server_version'] ?? '0.0.0';
      Version version = Version.parse(serverVersionStr);
      final osParts = macOSVersionStr.split('.');
      serverDetails.value = ServerDetails(
        macOSVersion: int.tryParse(osParts.isNotEmpty ? osParts[0] : '0') ?? 0,
        macOSMinorVersion: int.tryParse(osParts.length > 1 ? osParts[1] : '0') ?? 0,
        serverVersion: serverVersionStr,
        serverVersionCode: version.major * 100 + version.minor * 21 + version.patch,
        privateApiEnabled: response.data['data']['private_api'] ?? false,
        iCloudAccount: response.data['data']['detected_icloud'],
        proxyService: response.data['data']['proxy_service'],
      );
      helperBundleStatus.value = response.data['data']['helper_connected'] ?? false;
      timeSync.value = response.data['data']['macos_time_sync'];
      hasCheckedStats.value = true;

      final subsequentRequests = <Future>[];

      subsequentRequests.add(HttpSvc.server.getTotalStats().then((response) {
        if (response.data['status'] == 200) {
          stats.addAll(response.data['data'] ?? {});
          HttpSvc.server.getMediaStats().then((response) {
            if (response.data['status'] == 200) {
              stats.addAll(response.data['data'] ?? {});
            }
          });
        }
      }).catchError((_) {
        statsLoadError.value = true;
        showSnackbar("Error", "Failed to load server statistics!");
      }));

      Future.wait(subsequentRequests).whenComplete(() => opacity.value = 1.0);
    }).catchError((_) {
      showSnackbar("Error", "Failed to load server details!");
      hasCheckedStats.value = null;
    });
  }
}

class ServerManagementPanel extends CustomStateful<ServerManagementPanelController> {
  ServerManagementPanel({super.key}) : super(parentController: Get.put(ServerManagementPanelController()));

  @override
  State<ServerManagementPanel> createState() => _ServerManagementPanelState();
}

class _ServerManagementPanelState extends CustomState<ServerManagementPanel, void, ServerManagementPanelController> {
  @override
  Widget build(BuildContext context) {
    return ConnectionPanel(parentController: controller);
  }
}
