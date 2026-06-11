import 'package:bluebubbles/services/backend/settings/shared_preferences_service.dart';
import 'package:bluebubbles/services/backend/settings/settings_service.dart';
import 'package:bluebubbles/database/global/settings.dart';

class PrefsActions {
  static Future<void> saveReplyToMessageState(dynamic data) async {
    final chatGuid = data['chatGuid'] as String;
    final messageGuid = data['messageGuid'] as String?;
    final messagePart = data['messagePart'] as int?;

    if (messageGuid != null && messagePart != null) {
      await PrefsSvc.i.setString('replyToMessage_$chatGuid', messageGuid);
      await PrefsSvc.i.setInt('replyToMessagePart_$chatGuid', messagePart);
    } else {
      await PrefsSvc.i.remove('replyToMessage_$chatGuid');
      await PrefsSvc.i.remove('replyToMessagePart_$chatGuid');
    }
  }

  static Future<Map<String, dynamic>?> loadReplyToMessageState(dynamic data) async {
    final chatGuid = data['chatGuid'] as String;

    final messageGuid = PrefsSvc.i.getString('replyToMessage_$chatGuid');
    final messagePart = PrefsSvc.i.getInt('replyToMessagePart_$chatGuid');

    if (messageGuid != null && messagePart != null) {
      return {
        'messageGuid': messageGuid,
        'messagePart': messagePart,
      };
    }

    return null;
  }

  static Future<void> syncAllSettings(dynamic data) async {
    final settingsData = data['settings'] as Map<String, dynamic>;

    // Directly update the isolate's settings by creating a new Settings instance from the map
    // We can't use Settings.updateFromMap because it calls save() which triggers UI operations
    final newSettings = Settings.fromMap(settingsData);

    // Replace the settings in the SettingsService
    SettingsSvc.settings = newSettings;
  }

  static Future<void> syncSettings(dynamic data) async {
    Settings.updateFromMap(data);
  }
}
