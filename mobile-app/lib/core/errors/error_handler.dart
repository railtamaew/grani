import 'package:dio/dio.dart';
import '../logger/logger.dart';
import '../../l10n/localized_messages.dart';
import '../../services/native_vpn_service.dart' show VpnException;

/// Unified error handler and user-facing message mapping for the app.
/// Обеспечивает:
/// - Единый формат ошибок
/// - Извлечение сообщений из разных форматов ответов
/// - Маппинг на пользовательские сообщения
class ErrorHandler {
  static final ErrorHandler _instance = ErrorHandler._internal();
  factory ErrorHandler() => _instance;
  ErrorHandler._internal();

  final Logger _logger = Logger();

  /// Обработка DioException
  DioException handleDioError(DioException error) {
    _logger.error(
      'ErrorHandler: Обработка DioException',
      'ErrorHandler',
      error,
    );

    // Извлекаем сообщение об ошибке
    final message = _extractErrorMessage(error);
    
    // Создаем новую ошибку с обработанным сообщением
    return DioException(
      requestOptions: error.requestOptions,
      response: error.response,
      type: error.type,
      error: error.error,
      message: message,
    );
  }

  /// Извлечение сообщения об ошибке из DioException
  String _extractErrorMessage(DioException error) {
    // Проверяем response.data
    if (error.response?.data != null) {
      final data = error.response!.data;
      
      // Формат: {"error": {"code": "...", "message": "..."}}
      if (data is Map) {
        if (data['error'] is Map) {
          final errorMap = data['error'] as Map;
          final message = errorMap['message'] as String?;
          if (message != null && message.isNotEmpty) {
            return message;
          }
        }
        
        // Формат: {"message": "..."}
        if (data['message'] is String) {
          return data['message'] as String;
        }
        
        // Формат: {"detail": "..."}
        if (data['detail'] is String) {
          return data['detail'] as String;
        }
      }
    }

    // Используем стандартное сообщение в зависимости от типа ошибки
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
        return LocalizedMessages.connectionTimeout;
      case DioExceptionType.sendTimeout:
        return LocalizedMessages.sendTimeout;
      case DioExceptionType.receiveTimeout:
        return LocalizedMessages.receiveTimeout;
      case DioExceptionType.badResponse:
        return _getHttpErrorMessage(error.response?.statusCode);
      case DioExceptionType.cancel:
        return LocalizedMessages.requestCancelled;
      case DioExceptionType.connectionError:
        return LocalizedMessages.connectionError;
      case DioExceptionType.badCertificate:
        return LocalizedMessages.certificateError;
      case DioExceptionType.unknown:
        final errorMsg = error.error?.toString() ?? error.message ?? '';
        if (errorMsg.contains('SocketException') || errorMsg.contains('Failed host lookup')) {
          return LocalizedMessages.serverUnavailable;
        }
        if (errorMsg.contains('Network is unreachable')) {
          return LocalizedMessages.networkUnavailable;
        }
        return LocalizedMessages.unknownNetworkError(errorMsg);
    }
  }

  /// Получить сообщение об ошибке по HTTP статус коду
  String _getHttpErrorMessage(int? statusCode) {
    if (statusCode == null) {
      return LocalizedMessages.serverError;
    }
    return LocalizedMessages.errorByHttpCode(statusCode);
  }

  /// Обработка общей ошибки (Exception)
  String handleException(Object error) {
    _logger.error(
      'ErrorHandler: Обработка Exception',
      'ErrorHandler',
      error,
    );

    if (error is DioException) {
      return _extractErrorMessage(error);
    }

    return error.toString();
  }

  /// Single source for user-facing VPN/connection error messages.
  /// Use this in UI instead of parsing error.toString() or duplicate messageFromError().
  String userMessageForConnectionError(Object error) {
    if (error is VpnException) {
      return error.message;
    }
    if (error is DioException) {
      return _extractErrorMessage(error);
    }
    final s = error.toString();
    if (s.contains('401') || s.contains('Unauthorized')) {
      return LocalizedMessages.authRelogin;
    }
    if (s.contains('403') || s.contains('Forbidden')) {
      return LocalizedMessages.forbiddenRights;
    }
    if (s.contains('timeout') || s.contains('Timeout')) {
      return LocalizedMessages.timeoutGeneric;
    }
    if (s.contains('Network') || s.contains('Socket')) {
      return LocalizedMessages.networkGeneric;
    }
    if (s.contains('PERMISSION_DENIED') || s.contains('разрешение')) {
      return LocalizedMessages.vpnPermissionRequired;
    }
    if (s.contains('сервер не поддерживает')) {
      return LocalizedMessages.serverProtocolNotSupported;
    }
    if (s.contains('конфигурация')) {
      return LocalizedMessages.vpnConfigError;
    }
    if (s.contains('Устройство уже подключено') || s.contains('already connected')) {
      return LocalizedMessages.deviceAlreadyConnected;
    }
    if (s.contains('авторизац') ||
        s.contains('Требуется повторная') ||
        s.contains('Необходима авторизация')) {
      return LocalizedMessages.sessionExpired;
    }
    return handleException(error);
  }

  /// Проверка, является ли ошибка критической
  bool isCriticalError(DioException error) {
    // Критические ошибки - это те, которые не стоит повторять
    if (error.response?.statusCode != null) {
      final statusCode = error.response!.statusCode!;
      // 4xx ошибки (кроме 429) - не критичны, но не требуют повторения
      if (statusCode >= 400 && statusCode < 500 && statusCode != 429) {
        return false;
      }
      // 5xx ошибки - критичны, но можно повторить
      if (statusCode >= 500) {
        return true;
      }
    }

    // Ошибки таймаута - не критичны, можно повторить
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return false;
    }

    // Ошибки подключения - критичны
    if (error.type == DioExceptionType.connectionError) {
      return true;
    }

    return false;
  }

  /// Проверка, стоит ли повторять запрос
  bool shouldRetry(DioException error) {
    // Не повторяем для 4xx ошибок (кроме 429)
    if (error.response?.statusCode != null) {
      final statusCode = error.response!.statusCode!;
      if (statusCode >= 400 && statusCode < 500 && statusCode != 429) {
        return false;
      }
    }

    // Повторяем для таймаутов
    if (error.type == DioExceptionType.connectionTimeout ||
        error.type == DioExceptionType.receiveTimeout ||
        error.type == DioExceptionType.sendTimeout) {
      return true;
    }

    // Повторяем для 5xx ошибок
    if (error.response?.statusCode != null) {
      final statusCode = error.response!.statusCode!;
      if (statusCode >= 500) {
        return true;
      }
    }

    // Повторяем для ошибок подключения
    if (error.type == DioExceptionType.connectionError) {
      return true;
    }

    return false;
  }
}
