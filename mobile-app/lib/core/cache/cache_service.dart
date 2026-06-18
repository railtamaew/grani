import 'package:shared_preferences/shared_preferences.dart';
import '../logger/logger.dart';
import '../storage/shared_preferences_holder.dart';

/// Единый сервис кэширования для всего приложения
/// Обеспечивает:
/// - Единый интерфейс для кэширования
/// - TTL поддержку
/// - Автоматическую очистку
/// - Типизированные методы
class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal();

  final Logger _logger = Logger();
  SharedPreferences? _prefs;

  /// Инициализация сервиса. [prefs] — общий экземпляр из [getSharedPreferences], если null — берётся сам.
  Future<void> initialize([SharedPreferences? prefs]) async {
    try {
      _prefs = prefs ?? await getSharedPreferences();
      _logger.info('CacheService: Инициализирован');
    } catch (e) {
      _logger.error('CacheService: Ошибка инициализации', 'CacheService', e);
    }
  }

  /// Сохранить строку в кэш с TTL
  Future<bool> setString(
    String key,
    String value, {
    Duration? ttl,
  }) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      await _prefs!.setString(key, value);
      
      if (ttl != null) {
        final expiresAt = timestamp + ttl.inMilliseconds;
        await _prefs!.setInt('${key}_expires_at', expiresAt);
        _logger.debug('CacheService: Сохранено $key с TTL ${ttl.inSeconds}s');
      } else {
        await _prefs!.setInt('${key}_timestamp', timestamp);
        _logger.debug('CacheService: Сохранено $key без TTL');
      }
      
      return true;
    } catch (e) {
      _logger.error('CacheService: Ошибка сохранения $key', 'CacheService', e);
      return false;
    }
  }

  /// Получить строку из кэша
  Future<String?> getString(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      // Проверяем TTL
      final expiresAt = _prefs!.getInt('${key}_expires_at');
      if (expiresAt != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now > expiresAt) {
          // Кэш истек
          await remove(key);
          _logger.debug('CacheService: Кэш $key истек');
          return null;
        }
      }

      final value = _prefs!.getString(key);
      if (value != null) {
        _logger.debug('CacheService: Получено $key из кэша');
      }
      return value;
    } catch (e) {
      _logger.error('CacheService: Ошибка получения $key', 'CacheService', e);
      return null;
    }
  }

  /// Сохранить int в кэш
  Future<bool> setInt(
    String key,
    int value, {
    Duration? ttl,
  }) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      await _prefs!.setInt(key, value);
      
      if (ttl != null) {
        final expiresAt = timestamp + ttl.inMilliseconds;
        await _prefs!.setInt('${key}_expires_at', expiresAt);
      } else {
        await _prefs!.setInt('${key}_timestamp', timestamp);
      }
      
      return true;
    } catch (e) {
      _logger.error('CacheService: Ошибка сохранения $key', 'CacheService', e);
      return false;
    }
  }

  /// Получить int из кэша
  Future<int?> getInt(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      final expiresAt = _prefs!.getInt('${key}_expires_at');
      if (expiresAt != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now > expiresAt) {
          await remove(key);
          return null;
        }
      }

      return _prefs!.getInt(key);
    } catch (e) {
      _logger.error('CacheService: Ошибка получения $key', 'CacheService', e);
      return null;
    }
  }

  /// Сохранить bool в кэш
  Future<bool> setBool(
    String key,
    bool value, {
    Duration? ttl,
  }) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      await _prefs!.setBool(key, value);
      
      if (ttl != null) {
        final expiresAt = timestamp + ttl.inMilliseconds;
        await _prefs!.setInt('${key}_expires_at', expiresAt);
      } else {
        await _prefs!.setInt('${key}_timestamp', timestamp);
      }
      
      return true;
    } catch (e) {
      _logger.error('CacheService: Ошибка сохранения $key', 'CacheService', e);
      return false;
    }
  }

  /// Получить bool из кэша
  Future<bool?> getBool(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      final expiresAt = _prefs!.getInt('${key}_expires_at');
      if (expiresAt != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now > expiresAt) {
          await remove(key);
          return null;
        }
      }

      return _prefs!.getBool(key);
    } catch (e) {
      _logger.error('CacheService: Ошибка получения $key', 'CacheService', e);
      return null;
    }
  }

  /// Удалить ключ из кэша
  Future<bool> remove(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      await _prefs!.remove(key);
      await _prefs!.remove('${key}_timestamp');
      await _prefs!.remove('${key}_expires_at');
      _logger.debug('CacheService: Удалено $key из кэша');
      return true;
    } catch (e) {
      _logger.error('CacheService: Ошибка удаления $key', 'CacheService', e);
      return false;
    }
  }

  /// Очистить весь кэш
  Future<bool> clear() async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      await _prefs!.clear();
      _logger.info('CacheService: Кэш очищен');
      return true;
    } catch (e) {
      _logger.error('CacheService: Ошибка очистки кэша', 'CacheService', e);
      return false;
    }
  }

  /// Проверить, существует ли ключ в кэше
  Future<bool> containsKey(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      // Проверяем TTL
      final expiresAt = _prefs!.getInt('${key}_expires_at');
      if (expiresAt != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now > expiresAt) {
          await remove(key);
          return false;
        }
      }

      return _prefs!.containsKey(key);
    } catch (e) {
      _logger.error('CacheService: Ошибка проверки $key', 'CacheService', e);
      return false;
    }
  }

  /// Получить возраст кэша в секундах
  Future<int?> getAge(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      final timestamp = _prefs!.getInt('${key}_timestamp');
      if (timestamp == null) {
        return null;
      }

      final age = DateTime.now().millisecondsSinceEpoch - timestamp;
      return (age / 1000).round();
    } catch (e) {
      _logger.error('CacheService: Ошибка получения возраста $key', 'CacheService', e);
      return null;
    }
  }

  /// Проверить, валиден ли кэш (не истек ли TTL)
  Future<bool> isValid(String key) async {
    if (_prefs == null) {
      await initialize();
    }

    try {
      final expiresAt = _prefs!.getInt('${key}_expires_at');
      if (expiresAt == null) {
        // Нет TTL, считаем валидным
        return _prefs!.containsKey(key);
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      if (now > expiresAt) {
        await remove(key);
        return false;
      }

      return true;
    } catch (e) {
      _logger.error('CacheService: Ошибка проверки валидности $key', 'CacheService', e);
      return false;
    }
  }
}
