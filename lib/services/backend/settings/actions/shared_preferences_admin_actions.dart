import 'package:bluebubbles/services/backend/settings/shared_preferences_service.dart';

class SharedPreferencesAdminActions {
  final SharedPreferencesService service;

  SharedPreferencesAdminActions(this.service);

  Future<void> setBool(String key, bool value) async {
    await service.i.setBool(key, value);
  }

  Future<void> setString(String key, String value) async {
    await service.i.setString(key, value);
  }

  Future<void> setInt(String key, int value) async {
    await service.i.setInt(key, value);
  }

  Future<void> setDouble(String key, double value) async {
    await service.i.setDouble(key, value);
  }

  Future<void> remove(String key) async {
    await service.i.remove(key);
  }

  Set<String> getKeys() => service.i.getKeys();

  Object? get(String key) => service.i.get(key);

  Future<void> clearAll() async {
    await service.i.clear();
  }
}
