import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../logger/logger.dart';
import 'shared_preferences_holder.dart';

/// Единый сервис для работы с хранилищем
/// Разделяет secure (токены) и non-secure (настройки) данные
class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  final Logger _logger = Logger();
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );
  SharedPreferences? _prefs;

  /// Инициализация сервиса. [prefs] — общий экземпляр из [getSharedPreferences], если null — берётся сам.
  Future<void> initialize([SharedPreferences? prefs]) async {
    try {
      _prefs = prefs ?? await getSharedPreferences();
      _logger.info('StorageService: Инициализирован');
    } catch (e) {
      _logger.error('StorageService: Ошибка инициализации', 'StorageService', e);
    }
  }

  // ==================== Secure Storage (токены, пароли) ====================

  /// Сохранить secure строку
  Future<bool> setSecureString(String key, String value) async {
    try {
      await _secureStorage.write(key: key, value: value);
      _logger.debug('StorageService: Сохранено secure $key');
      return true;
    } catch (e) {
      _logger.error('StorageService: Ошибка сохранения secure $key', 'StorageService', e);
      return false;
    }
  }

  /// Получить secure строку
  Future<String?> getSecureString(String key) async {
    try {
      final value = await _secureStorage.read(key: key);
      if (value != null) {
        _logger.debug('StorageService: Получено secure $key');
      }
      return value;
    } catch (e) {
      _logger.error('StorageService: Ошибка получения secure $key', 'StorageService', e);
      return null;
    }
  }

  /// Удалить secure строку
  Future<bool> removeSecureString(String key) async {
    try {
      await _secureStorage.delete(key: key);
      _logger.debug('StorageService: Удалено secure $key');
      return true;
    } catch (e) {
      _logger.error('StorageService: Ошибка удаления secure $key', 'StorageService', e);
      return false;
    }
  }

  // ==================== Non-Secure Storage (настройки, кэш) ====================

  /// Сохранить строку
  Future<bool> setString(String key, String value) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      await _prefs!.setString(key, value);
      _logger.debug('StorageService: Сохранено $key');
      return true;
    } catch (e) {
      _logger.error('StorageService: Ошибка сохранения $key', 'StorageService', e);
      return false;
    }
  }

  /// Получить строку
  Future<String?> getString(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      return _prefs!.getString(key);
    } catch (e) {
      _logger.error('StorageService: Ошибка получения $key', 'StorageService', e);
      return null;
    }
  }

  /// Сохранить int
  Future<bool> setInt(String key, int value) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      await _prefs!.setInt(key, value);
      return true;
    } catch (e) {
      _logger.error('StorageService: Ошибка сохранения $key', 'StorageService', e);
      return false;
    }
  }

  /// Получить int
  Future<int?> getInt(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      return _prefs!.getInt(key);
    } catch (e) {
      _logger.error('StorageService: Ошибка получения $key', 'StorageService', e);
      return null;
    }
  }

  /// Сохранить bool
  Future<bool> setBool(String key, bool value) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      await _prefs!.setBool(key, value);
      return true;
    } catch (e) {
      _logger.error('StorageService: Ошибка сохранения $key', 'StorageService', e);
      return false;
    }
  }

  /// Получить bool
  Future<bool?> getBool(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      return _prefs!.getBool(key);
    } catch (e) {
      _logger.error('StorageService: Ошибка получения $key', 'StorageService', e);
      return null;
    }
  }

  /// Удалить ключ
  Future<bool> remove(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      await _prefs!.remove(key);
      _logger.debug('StorageService: Удалено $key');
      return true;
    } catch (e) {
      _logger.error('StorageService: Ошибка удаления $key', 'StorageService', e);
      return false;
    }
  }

  /// Очистить все non-secure данные, кроме device_id (сохраняем для resolve после очистки).
  Future<bool> clear() async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      final deviceId = _prefs!.getString('device_id');
      await _prefs!.clear();
      if (deviceId != null && deviceId.isNotEmpty) {
        await _prefs!.setString('device_id', deviceId);
        _logger.info('StorageService: Очищено non-secure хранилище (device_id сохранён)');
      } else {
        _logger.info('StorageService: Очищено non-secure хранилище');
      }
      return true;
    } catch (e) {
      _logger.error('StorageService: Ошибка очистки', 'StorageService', e);
      return false;
    }
  }

  /// Очистить все secure данные, кроме device_id (чтобы не терять устройство при «полной очистке»).
  Future<bool> clearSecure() async {
    try {
      final deviceId = await _secureStorage.read(key: 'device_id');
      await _secureStorage.deleteAll();
      if (deviceId != null && deviceId.isNotEmpty) {
        await _secureStorage.write(key: 'device_id', value: deviceId);
        _logger.info('StorageService: Очищено secure хранилище (device_id сохранён)');
      } else {
        _logger.info('StorageService: Очищено secure хранилище');
      }
      return true;
    } catch (e) {
      _logger.error('StorageService: Ошибка очистки secure', 'StorageService', e);
      return false;
    }
  }

  /// Очистить все данные (secure + non-secure)
  Future<bool> clearAll() async {
    final secureCleared = await clearSecure();
    final nonSecureCleared = await clear();
    return secureCleared && nonSecureCleared;
  }

  /// Проверить, существует ли ключ
  Future<bool> containsKey(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      return _prefs!.containsKey(key);
    } catch (e) {
      _logger.error('StorageService: Ошибка проверки $key', 'StorageService', e);
      return false;
    }
  }

  /// Миграция данных из SharedPreferences в SecureStorage
  /// Используется для миграции токенов
  Future<bool> migrateToSecure(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      final value = _prefs!.getString(key);
      if (value != null) {
        await setSecureString(key, value);
        await _prefs!.remove(key);
        _logger.info('StorageService: Мигрировано $key в secure хранилище');
        return true;
      }
      return false;
    } catch (e) {
      _logger.error('StorageService: Ошибка миграции $key', 'StorageService', e);
      return false;
    }
  }
}
