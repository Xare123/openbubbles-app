import 'package:shared_preferences/shared_preferences.dart';
import 'package:get_it/get_it.dart';

// ignore: non_constant_identifier_names
SharedPreferencesService get PrefsSvc => GetIt.I<SharedPreferencesService>();

class SharedPreferencesService {
  late final SharedPreferences i;

  Future<void> init({bool headless = false}) async {
    i = await SharedPreferences.getInstance();
  }
}
