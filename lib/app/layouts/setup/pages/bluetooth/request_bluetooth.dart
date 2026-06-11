import 'package:bluebubbles/app/layouts/setup/pages/page_template.dart';
import 'package:bluebubbles/services/services.dart';
import 'package:bluebubbles/utils/logger/logger.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class RequestBluetooth extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SetupPageTemplate(
      title: "Nearby Devices",
      subtitle: "Apple uses proximity detection to securely transfer account data during login.",
      onNextPressed: () async {
        if ((FilesystemSvc.androidInfo?.version.sdkInt ?? 0) >= 31) {
          final statuses = await [
            Permission.bluetoothAdvertise,
            Permission.bluetoothConnect,
          ].request();

          final ok = statuses.values.every((s) => s.isGranted);
          if (!ok) {
            return true;
          }
        }

        try {
          await MethodChannelSvc.invokeMethod("enable-bt", {"request": true});
        } catch (e, s) {
          Logger.error("Failed to enable bt", error: e, trace: s);
          return false;
        }

        return true;
      },
    );
  }
}
