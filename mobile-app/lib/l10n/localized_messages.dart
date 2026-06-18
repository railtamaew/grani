import '../core/session/locale_controller.dart';

class LocalizedMessages {
  LocalizedMessages._();

  static LocaleController? _controller;

  static void bind(LocaleController controller) {
    _controller = controller;
  }

  static bool get _isRu => _controller?.locale.languageCode == 'ru';
  static String get currentLanguageCode =>
      _controller?.locale.languageCode ?? 'en';

  static String get connectionTimeout => _isRu
      ? 'Превышено время ожидания подключения. Проверьте интернет-соединение.'
      : 'Connection timeout exceeded. Check internet connection.';
  static String get sendTimeout => _isRu
      ? 'Превышено время ожидания отправки данных.'
      : 'Data send timeout exceeded.';
  static String get receiveTimeout => _isRu
      ? 'Превышено время ожидания получения данных.'
      : 'Data receive timeout exceeded.';
  static String get requestCancelled =>
      _isRu ? 'Запрос отменен.' : 'Request cancelled.';
  /// Долгий POST /auth/send-code или /auth/verify-code отменён при уходе приложения в фон.
  static String get authInterruptedInBackground => _isRu
      ? 'Запрос прерван при уходе приложения в фон. Повторите попытку.'
      : 'The request was interrupted when the app went to the background. Try again.';
  static String get connectionError => _isRu
      ? 'Ошибка подключения. Проверьте интернет-соединение.'
      : 'Connection error. Check internet connection.';
  static String get certificateError =>
      _isRu ? 'Ошибка сертификата.' : 'Certificate error.';
  static String get serverUnavailable => _isRu
      ? 'Сервер недоступен. Проверьте подключение к интернету.'
      : 'Server is unavailable. Check internet connection.';
  static String get networkUnavailable => _isRu
      ? 'Сеть недоступна. Проверьте подключение к интернету.'
      : 'Network is unavailable. Check internet connection.';

  static String unknownNetworkError(String details) => _isRu
      ? 'Неизвестная ошибка сети: $details'
      : 'Unknown network error: $details';

  static String get serverError => _isRu ? 'Ошибка сервера.' : 'Server error.';

  static String errorByHttpCode(int code) {
    if (_isRu) {
      switch (code) {
        case 400:
          return 'Неверный запрос. Проверьте введенные данные.';
        case 401:
          return 'Требуется авторизация. Войдите в систему.';
        case 403:
          return 'Доступ запрещен.';
        case 404:
          return 'Ресурс не найден.';
        case 409:
          return 'Конфликт данных.';
        case 422:
          return 'Ошибка валидации данных.';
        case 429:
          return 'Слишком много запросов. Попробуйте позже.';
        case 500:
          return 'Внутренняя ошибка сервера.';
        case 502:
          return 'Сервер временно недоступен.';
        case 503:
          return 'Сервис временно недоступен.';
        default:
          return 'Ошибка сервера (код: $code).';
      }
    }
    switch (code) {
      case 400:
        return 'Invalid request. Check entered data.';
      case 401:
        return 'Authorization required. Please sign in.';
      case 403:
        return 'Access denied.';
      case 404:
        return 'Resource not found.';
      case 409:
        return 'Data conflict.';
      case 422:
        return 'Validation error.';
      case 429:
        return 'Too many requests. Try again later.';
      case 500:
        return 'Internal server error.';
      case 502:
        return 'Server is temporarily unavailable.';
      case 503:
        return 'Service is temporarily unavailable.';
      default:
        return 'Server error (code: $code).';
    }
  }

  static String get authRelogin => _isRu
      ? 'Ошибка авторизации. Пожалуйста, войдите в систему снова.'
      : 'Authorization error. Please sign in again.';
  static String get forbiddenRights => _isRu
      ? 'Доступ запрещен. Проверьте права доступа.'
      : 'Access denied. Check your permissions.';
  static String get timeoutGeneric => _isRu
      ? 'Превышено время ожидания. Проверьте подключение к интернету.'
      : 'Request timeout. Check internet connection.';
  static String get networkGeneric => _isRu
      ? 'Ошибка сети. Проверьте подключение к интернету.'
      : 'Network error. Check internet connection.';
  static String get vpnPermissionRequired => _isRu
      ? 'Необходимо предоставить разрешение VPN для подключения.'
      : 'VPN permission is required for connection.';
  static String get serverProtocolNotSupported => _isRu
      ? 'Сервер не поддерживает выбранный протокол. Выберите другой протокол.'
      : 'Server does not support selected protocol. Choose another protocol.';
  static String get vpnConfigError => _isRu
      ? 'Ошибка конфигурации VPN. Попробуйте выбрать другой сервер.'
      : 'VPN configuration error. Try selecting another server.';
  static String get deviceAlreadyConnected => _isRu
      ? 'Устройство уже подключено. Отключите его на другом устройстве или попробуйте снова.'
      : 'Device is already connected. Disconnect it on another device or try again.';
  static String get sessionExpired =>
      _isRu ? 'Сессия истекла. Войдите в аккаунт снова.' : 'Session expired. Sign in again.';

  static String get authError =>
      _isRu ? 'Ошибка авторизации' : 'Authorization error';
  static String get loginError =>
      _isRu ? 'Ошибка входа. Проверьте данные' : 'Sign-in error. Check your credentials.';
  static String get registrationError =>
      _isRu ? 'Ошибка регистрации' : 'Registration error';
  static String get googleTokenMissing => _isRu
      ? 'Не удалось получить токен авторизации от Google. Проверьте настройки в Google Cloud Console.'
      : 'Could not get Google authorization token. Check Google Cloud Console settings.';
  static String get googleOAuthConfigError => _isRu
      ? 'Ошибка настройки Google OAuth. Проверьте SHA-1 fingerprint и client_id в Google Cloud Console.'
      : 'Google OAuth configuration error. Check SHA-1 fingerprint and client_id in Google Cloud Console.';
  static String get sendCodeError =>
      _isRu ? 'Ошибка отправки кода' : 'Failed to send code';
  static String get invalidEmailFormat =>
      _isRu ? 'Некорректный формат email' : 'Invalid email format';
  static String get tooManyRequests =>
      _isRu ? 'Слишком много запросов. Повторите позже.' : 'Too many requests. Try again later.';
  static String get sendCodeRetry =>
      _isRu ? 'Не удалось отправить код. Повторите позже.' : 'Could not send code. Try again later.';
  static String get timeoutWithNetworkHint => _isRu
      ? 'Истекло время ожидания. Проверьте интернет. Для проверки подключите поочередно Wi-Fi и мобильную сеть.'
      : 'Request timed out. Check internet. Try switching between Wi-Fi and mobile network.';
  /// Таймаут при отправке кода: ответ неизвестен — письмо могло уйти.
  static String get sendCodeTimeoutAmbiguous => _isRu
      ? 'Ответ не пришёл вовремя. Код мог уже уйти на почту — проверьте входящие. Если письма нет, подождите и нажмите отправку кода снова.'
      : 'The response timed out. The code may already be in your inbox. Check your mail, or wait and tap resend.';
  static String get connectionRetryHint => _isRu
      ? 'Для проверки подключите поочередно Wi-Fi и мобильную сеть.'
      : 'Try switching between Wi-Fi and mobile network.';
  static String get authServiceError =>
      _isRu ? 'Ошибка сервиса авторизации. Повторите позже.' : 'Authorization service error. Try again later.';
  static String get unexpectedSendCodeError =>
      _isRu ? 'Неожиданная ошибка отправки кода' : 'Unexpected error while sending code';
  static String get invalidCode => _isRu ? 'Неверный код' : 'Invalid code';
  /// Сервер: «Код не найден или истек» (send/verify рассинхрон или TTL).
  static String get codeNotFoundOrExpired => _isRu
      ? 'Код не найден или срок его действия истёк. Запросите новый код.'
      : 'Code not found or expired. Request a new code.';
  static String get codeExpired =>
      _isRu ? 'Код истёк. Запросите новый код.' : 'Code expired. Request a new code.';
  static String get invalidAuthRequestId => _isRu
      ? 'Некорректный запрос кода. Запросите новый код.'
      : 'Invalid code request. Request a new code.';
  static String get tooManyAttempts =>
      _isRu ? 'Слишком много попыток. Повторите позже.' : 'Too many attempts. Try again later.';
  static String get verifyCodeError =>
      _isRu ? 'Ошибка при подтверждении кода' : 'Code verification failed';
  /// Таймаут ответа при verify без автоповтора.
  static String get verifyCodeReceiveTimeoutNoRetry => _isRu
      ? 'Не удалось подтвердить код. Попробуйте ещё раз.'
      : 'Could not confirm the code. Please try again.';
  static String get unexpectedVerifyCodeError =>
      _isRu ? 'Неожиданная ошибка проверки кода' : 'Unexpected code verification error';
  static String get storeUnavailable =>
      _isRu ? 'Магазин недоступен' : 'Store is unavailable';

  /// Connect flow: no active subscription or trial (message may be shown in future).
  static String get connectNoSubscription =>
      _isRu
          ? 'Подписка не активна. Оформите тариф или запустите пробный период.'
          : 'Subscription inactive. Subscribe or start a trial to connect.';

  static String get serversLoadFailedForConnect =>
      _isRu
          ? 'Не удалось загрузить список серверов. Проверьте подключение к интернету и попробуйте снова.'
          : 'Could not load servers. Check your internet connection and try again.';

  static String get selectServerBeforeConnect =>
      _isRu ? 'Выберите сервер перед подключением.' : 'Select a server before connecting.';

  static String get connectFailureRetry =>
      _isRu ? 'Не удалось подключиться. Попробуйте снова.' : 'Could not connect. Try again.';
}
