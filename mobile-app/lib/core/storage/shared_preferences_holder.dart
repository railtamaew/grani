import 'package:shared_preferences/shared_preferences.dart';

/// Single shared [SharedPreferences] instance for the app.
/// Used by [StorageService] and [CacheService] to avoid duplicate disk access at startup.
SharedPreferences? _instance;

/// Returns the single [SharedPreferences] instance (creates it once).
Future<SharedPreferences> getSharedPreferences() async {
  _instance ??= await SharedPreferences.getInstance();
  return _instance!;
}
