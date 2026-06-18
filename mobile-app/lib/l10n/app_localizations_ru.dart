// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Russian (`ru`).
class AppLocalizationsRu extends AppLocalizations {
  AppLocalizationsRu([String locale = 'ru']) : super(locale);

  @override
  String get appLanguageEnglish => 'Английский';

  @override
  String get appLanguageRussian => 'Русский';

  @override
  String get profileTitle => 'Профиль';

  @override
  String get profileClose => 'Закрыть';

  @override
  String get profileEmailCopied => 'Email скопирован';

  @override
  String get profileShareFailed => 'Не удалось открыть меню отправки';

  @override
  String get profileOpenTelegramFailed => 'Не удалось открыть Telegram';

  @override
  String get profileSupportInfoCopied =>
      'Данные для поддержки скопированы. Вставьте их в чат Telegram.';

  @override
  String get profileSupport => 'Поддержка';

  @override
  String get profileAccount => 'Аккаунт';

  @override
  String get profileDevices => 'Устройства';

  @override
  String get profileDevicesConnected => 'подключено';

  @override
  String profileDevicesFrom(Object connected, Object limit) {
    return '$connected из $limit ';
  }

  @override
  String get profileCopyEmail => 'Скопировать email';

  @override
  String get profileOpenDevices => 'Открыть список устройств';

  @override
  String get profileSelectSplitTunnelApps =>
      'Выбрать приложения для обхода VPN';

  @override
  String get profileCopyVersion => 'Скопировать версию';

  @override
  String get profileSupportChat => 'Написать в поддержку';

  @override
  String get profileSupportChatSubtitle =>
      'Telegram-чат с данными для диагностики';

  @override
  String get profileSupportChatSemantic =>
      'Открыть чат поддержки GRANI в Telegram';

  @override
  String get profileDiagnostics => 'Отправить диагностику';

  @override
  String get profileDiagnosticsSubtitle => 'Технический отчет для поддержки';

  @override
  String get profileDiagnosticsSemantic =>
      'Отправить диагностический отчет GRANI';

  @override
  String get profileDiagnosticsSent => 'Диагностика отправлена.';

  @override
  String get profileDiagnosticsFailed => 'Не удалось отправить диагностику.';

  @override
  String get profileSupportAccessPremium => 'Premium активен';

  @override
  String get profileSupportAccessTrial => 'Тестовый доступ активен';

  @override
  String get profileSupportAccessLimited => 'Доступ ограничен';

  @override
  String get profileSupportVpnConnected => 'Подключено';

  @override
  String get profileSupportVpnConnecting => 'Подключение';

  @override
  String get profileSupportVpnDisconnecting => 'Отключение';

  @override
  String get profileSupportVpnDisconnected => 'Отключено';

  @override
  String get profileSupportVpnError => 'Ошибка';

  @override
  String profileSupportPreparedMessage(
      Object userId,
      Object email,
      Object appVersion,
      Object buildNumber,
      Object language,
      Object accessStatus,
      Object vpnState,
      Object server,
      Object protocol,
      Object platform,
      Object timeUtc) {
    return 'Здравствуйте, поддержка GRANI.\n\nПроблема:\n\nТехнический контекст\nUser ID: $userId\nEmail: $email\nApp: $appVersion+$buildNumber\nЯзык: $language\nДоступ: $accessStatus\nVPN: $vpnState\nСервер: $server\nПротокол: $protocol\nУстройство: $platform\nВремя UTC: $timeUtc\n\nОпишите, пожалуйста, что произошло выше.';
  }

  @override
  String get profileSharePrefix => 'Поделиться';

  @override
  String get profileShareGrani => 'Поделиться GRANI';

  @override
  String profileSharePlayStoreMessage(Object url) {
    return 'GRANI. Установить:\n$url';
  }

  @override
  String get notificationJournalMenu => 'Журнал уведомлений';

  @override
  String get notificationJournalScreenTitle => 'Журнал уведомлений';

  @override
  String get notificationJournalEmpty => 'Пока нет уведомлений';

  @override
  String get notificationJournalClear => 'Очистить всё';

  @override
  String get notificationJournalClearTitle => 'Очистить журнал?';

  @override
  String get notificationJournalClearConfirm =>
      'Удалить все записи из журнала?';

  @override
  String get notificationJournalSourceForeground => 'Приложение открыто';

  @override
  String get notificationJournalSourceOpenedApp => 'Из уведомления';

  @override
  String get notificationJournalSourceInitial => 'При холодном старте';

  @override
  String get notificationJournalSourceBackground => 'В фоне';

  @override
  String get notificationJournalPushStopTitle => 'GRANI';

  @override
  String notificationJournalPushStopBody(Object reason) {
    return 'Соединение остановлено ($reason)';
  }

  @override
  String get notificationJournalDataPayloadTitle => 'Сообщение';

  @override
  String notificationJournalDataPayloadBody(Object summary) {
    return '$summary';
  }

  @override
  String get notificationJournalEmptySubtitle =>
      'Здесь будут обновления подписки и оплаты от GRANI.';

  @override
  String get notificationJournalFallbackPaymentCompletedTitle =>
      'Оплата получена';

  @override
  String get notificationJournalFallbackPaymentCompletedBody =>
      'Подписка продлена.';

  @override
  String get notificationJournalFallbackSubscriptionRevokedTitle =>
      'Подписка отменена';

  @override
  String get notificationJournalFallbackSubscriptionRevokedBody =>
      'Доступ к VPN приостановлен. Оформите подписку снова.';

  @override
  String get notificationJournalFallbackSubscriptionExpiredTitle =>
      'Подписка истекла';

  @override
  String get notificationJournalFallbackSubscriptionExpiredBody =>
      'Продлите подписку в приложении GRANI.';

  @override
  String get notificationJournalFallbackSubscriptionExpiryWarningTitle =>
      'Подписка скоро истечёт';

  @override
  String get notificationJournalFallbackSubscriptionExpiryWarningBody =>
      'Продлите до даты окончания, чтобы сохранить доступ.';

  @override
  String get notificationJournalFallbackTrialEndedTitle =>
      'Пробный период завершён';

  @override
  String get notificationJournalFallbackTrialEndedBody =>
      'Оформите подписку, чтобы продолжить пользоваться GRANI.';

  @override
  String get notificationJournalFallbackTrialActivatedTitle =>
      'Пробный доступ подключён';

  @override
  String get notificationJournalFallbackTrialActivatedBody =>
      'Можно подключаться.';

  @override
  String get trialAccessActivatedSnackbar =>
      'Пробный доступ подключён. Можно подключаться.';

  @override
  String get profileAbout => 'О приложении';

  @override
  String get profileVersion => 'Версия';

  @override
  String get profileVersionCopied => 'Версия скопирована';

  @override
  String get profileLanguage => 'Язык';

  @override
  String get profileLanguageValue => 'Настроить';

  @override
  String get profileSubscriptionActive => 'Активна';

  @override
  String profileSubscriptionActiveUntil(Object date) {
    return 'Активен до $date';
  }

  @override
  String profileTrialUntil(Object date) {
    return 'Тест до $date';
  }

  @override
  String get profileAccessLimited => 'Доступ ограничен';

  @override
  String get profileNoSubscription => 'Без подписки';

  @override
  String get splitTunnelTitle => 'Раздельный туннель';

  @override
  String get splitTunnelTabApps => 'Приложения';

  @override
  String get splitTunnelTabDomains => 'Домены';

  @override
  String get splitTunnelSearchApps => 'Поиск приложения';

  @override
  String get splitTunnelSearchDomains => 'Поиск домена';

  @override
  String get splitTunnelAndroidOnly => 'Раздел доступен только на Android';

  @override
  String get splitTunnelAddDomain => 'Добавить домен';

  @override
  String get splitTunnelModeHintExclude =>
      'Режим: выбранные приложения идут в обход VPN';

  @override
  String get splitTunnelModeHintInclude =>
      'Режим: только выбранные приложения идут через VPN';

  @override
  String get splitTunnelModeExclude => 'В обход VPN';

  @override
  String get splitTunnelModeInclude => 'Только через VPN';

  @override
  String get splitTunnelPresetsHint =>
      'Быстрые группы добавляют установленные приложения из категории.';

  @override
  String get splitTunnelNoApps => 'Нет приложений';

  @override
  String get splitTunnelNothingFound => 'Ничего не найдено';

  @override
  String get splitTunnelNoDomains => 'Нет добавленных доменов';

  @override
  String get splitTunnelDomainsHint =>
      'Домены идут в обход VPN после переподключения: приложение резолвит их в IP и кеширует на устройстве. Для Chrome выключите Secure DNS, а в Android — Private DNS, иначе браузер может использовать другой IP.';

  @override
  String get splitTunnelReconnectConnected =>
      'Изменения сохранены. Отключите и подключите VPN вручную, чтобы применить их.';

  @override
  String get splitTunnelReconnectDisconnected =>
      'Изменения применятся при следующем подключении VPN';

  @override
  String get splitTunnelAppAdded => 'Приложение добавлено в список.';

  @override
  String get splitTunnelAppRemoved => 'Приложение удалено из списка.';

  @override
  String get splitTunnelDomainAdded => 'Домен добавлен.';

  @override
  String get splitTunnelDomainRemoved => 'Домен удален.';

  @override
  String get splitTunnelModeExcludeChanged => 'Режим изменен: в обход VPN.';

  @override
  String get splitTunnelModeIncludeChanged =>
      'Режим изменен: только через VPN.';

  @override
  String splitTunnelPresetNoApps(Object label) {
    return 'Для группы \"$label\" подходящих приложений не найдено.';
  }

  @override
  String get trialExpiredTitle => 'Для продолжения работы, выберите тариф';

  @override
  String get trialExpiredSubtitle =>
      'Оформи подписку и получи полный доступ к скорости, защите.';

  @override
  String get trialUpgradeTitle => 'Выберите тариф';

  @override
  String get trialUpgradeSubtitle =>
      'Оформите подписку заранее - доступ продолжится без перерыва.';

  @override
  String get trialManageTitle => 'Управление подпиской';

  @override
  String get trialManageSubtitle => 'Продлите или измените тариф.';

  @override
  String get trialTimeLeft => 'осталось: 00:00';

  @override
  String get homeReadyTitle => 'Готово';

  @override
  String get homeReadySubtitle => 'Нажмите, чтобы подключиться';

  @override
  String get homeProtectedTitle => 'Защищено';

  @override
  String get homeProtectedSubtitle => 'Трафик защищён';

  @override
  String get homeConnectionFailedTitle => 'Сбой подключения';

  @override
  String get homeConnectionFailedSubtitle =>
      'Проверьте сеть и попробуйте снова';

  @override
  String get homeSubscriptionActive => 'Подписка активна';

  @override
  String get homeConnecting => 'Идет подключение...';

  @override
  String get homeDisconnecting => 'Отключение...';

  @override
  String get homeServiceReady => 'Сервис активен и готов к подключению';

  @override
  String get homeConnectionFailed =>
      'Не удалось подключиться. Нажмите кнопку для повтора';

  @override
  String get homeConnectionActive => 'Соединение установлено, трафик защищён';

  @override
  String get homeDisconnectingSubtitle => 'Завершаем защищённое соединение';

  @override
  String get homeSelectorLocked =>
      'Отключите VPN, чтобы сменить сервер или протокол';

  @override
  String errorAppStartup(Object error) {
    return 'Ошибка запуска: $error';
  }

  @override
  String get errorConnectionTimeout =>
      'Превышено время ожидания подключения. Проверьте интернет-соединение.';

  @override
  String get errorSendTimeout => 'Превышено время ожидания отправки данных.';

  @override
  String get errorReceiveTimeout =>
      'Превышено время ожидания получения данных.';

  @override
  String get errorRequestCancelled => 'Запрос отменен.';

  @override
  String get errorConnection =>
      'Ошибка подключения. Проверьте интернет-соединение.';

  @override
  String get errorCertificate => 'Ошибка сертификата.';

  @override
  String get errorServerUnavailable =>
      'Сервер недоступен. Проверьте подключение к интернету.';

  @override
  String get errorNetworkUnavailable =>
      'Сеть недоступна. Проверьте подключение к интернету.';

  @override
  String errorUnknownNetwork(Object error) {
    return 'Неизвестная ошибка сети: $error';
  }

  @override
  String get errorServerGeneric => 'Ошибка сервера.';

  @override
  String get errorHttp400 => 'Неверный запрос. Проверьте введенные данные.';

  @override
  String get errorHttp401 => 'Требуется авторизация. Войдите в систему.';

  @override
  String get errorHttp403 => 'Доступ запрещен.';

  @override
  String get errorHttp404 => 'Ресурс не найден.';

  @override
  String get errorHttp409 => 'Конфликт данных.';

  @override
  String get errorHttp422 => 'Ошибка валидации данных.';

  @override
  String get errorHttp429 => 'Слишком много запросов. Попробуйте позже.';

  @override
  String get errorHttp500 => 'Внутренняя ошибка сервера.';

  @override
  String get errorHttp502 => 'Сервер временно недоступен.';

  @override
  String get errorHttp503 => 'Сервис временно недоступен.';

  @override
  String errorHttpCode(Object code) {
    return 'Ошибка сервера (код: $code).';
  }

  @override
  String get errorAuthRelogin =>
      'Ошибка авторизации. Пожалуйста, войдите в систему снова.';

  @override
  String get errorForbiddenRights =>
      'Доступ запрещен. Проверьте права доступа.';

  @override
  String get errorTimeoutGeneric =>
      'Превышено время ожидания. Проверьте подключение к интернету.';

  @override
  String get errorNetworkGeneric =>
      'Ошибка сети. Проверьте подключение к интернету.';

  @override
  String get errorVpnPermissionRequired =>
      'Необходимо предоставить разрешение VPN для подключения.';

  @override
  String get errorServerProtocolNotSupported =>
      'Сервер не поддерживает выбранный протокол. Выберите другой протокол.';

  @override
  String get errorVpnConfig =>
      'Ошибка конфигурации VPN. Попробуйте выбрать другой сервер.';

  @override
  String get errorDeviceAlreadyConnected =>
      'Устройство уже подключено. Отключите его на другом устройстве или попробуйте снова.';

  @override
  String get errorSessionExpired => 'Сессия истекла. Войдите в аккаунт снова.';

  @override
  String get authServiceUnavailable => 'Сервис временно недоступен';

  @override
  String get authGoogleCancelled => 'Вход через Google отменен';

  @override
  String get authTryAgain => 'Попробуйте снова';

  @override
  String get startHeadline => 'Выходи за грани ограничений';

  @override
  String get startSubtitle =>
      'Доступ ко всему миру,\nзащита и скорость - одним нажатием';

  @override
  String get startContinueGoogle => 'Продолжить с Google';

  @override
  String get startContinueEmail => 'Продолжить с email';

  @override
  String get startAlreadyHaveAccount => 'Уже есть аккаунт? ';

  @override
  String get startSignIn => 'Войти';

  @override
  String get startPrivacyMore => 'Подробнее о конфиденциальности';

  @override
  String get connectionSpeedZero => 'Скорость: 0 Мбит/с';

  @override
  String connectionSpeedMbps(Object speed) {
    return 'Скорость: $speed Мбит/с';
  }

  @override
  String get connectionStable => 'Соединение стабильно';

  @override
  String get connectionWaitingTraffic => 'Ожидание трафика...';

  @override
  String get connectionTapCancel => 'Нажмите для отмены';

  @override
  String get connectionTapRetry => 'Нажмите для повтора';

  @override
  String get connectionStagesTitle => 'Этапы подключения';

  @override
  String get btnVpnConnect => 'подключить';

  @override
  String get btnVpnCancel => 'отменить';

  @override
  String get btnVpnConnecting => 'подключение…';

  @override
  String get btnVpnDisconnecting => 'отключение…';

  @override
  String get btnVpnConnected => 'подключено';

  @override
  String get btnVpnRetry => 'повторить';

  @override
  String get semanticsVpnConnect => 'Подключить к VPN';

  @override
  String get semanticsVpnConnecting => 'Подключение…';

  @override
  String get semanticsVpnDisconnecting => 'Отключение…';

  @override
  String get semanticsVpnConnectedTapDisconnect =>
      'Подключено. Нажмите для отключения';

  @override
  String get semanticsVpnErrorRetry =>
      'Ошибка подключения. Нажмите для повтора';

  @override
  String get semanticsVpnTapCancel => 'Нажмите для отмены';

  @override
  String get vpnProgressConnecting => 'Подключаемся к серверу...';

  @override
  String get vpnProgressVpnPermission => 'Проверяем разрешение VPN...';

  @override
  String get vpnProgressAuthCheck => 'Проверяем доступ...';

  @override
  String get vpnProgressServerSelection => 'Выбираем оптимальный сервер...';

  @override
  String get vpnProgressDeviceRegistration => 'Регистрируем устройство...';

  @override
  String get vpnProgressConfigFetch => 'Готовим защищенный профиль...';

  @override
  String get vpnProgressConfigProcessing =>
      'Проверяем параметры подключения...';

  @override
  String get vpnProgressVpnInterface => 'Создаем защищенный туннель...';

  @override
  String get vpnProgressProtocolStart => 'Запускаем защищенный канал...';

  @override
  String get vpnProgressTrafficCheck => 'Проверяем защищенный трафик...';

  @override
  String get vpnProgressConnected => 'Соединение установлено';

  @override
  String get vpnProgressConnectCancelling => 'Отменяем подключение...';

  @override
  String get vpnBadgeFastReconnect => 'Быстрое восстановление';

  @override
  String get vpnBadgeFirstSetup => 'Первичная настройка';

  @override
  String get vpnWaitSecureTraffic => 'Ожидание защищенного трафика...';

  @override
  String get vpnConnectPatienceWarm =>
      'Восстановление связи занимает дольше обычного — подождите, подключение продолжается.';

  @override
  String get vpnRetryRouteWarm => 'Пробуем другой маршрут подключения...';

  @override
  String get vpnSlowNetworkWarm =>
      'Соединение может занять немного больше времени из-за сети.';

  @override
  String get vpnConnectPatienceCold =>
      'Первичная настройка на медленной сети может занять до минуты — подождите, это нормально.';

  @override
  String get vpnOptimizeRoute => 'Пробуем оптимизировать маршрут...';

  @override
  String get vpnSlowNetworkCold =>
      'Это нормально при медленной сети, продолжаем подключение...';

  @override
  String get connectionStagesProgressSemantic => 'Прогресс подключения VPN';

  @override
  String get serversTitle => 'Серверы';

  @override
  String get serversNotLoaded => 'Серверы не загружены';

  @override
  String get serversRefresh => 'Обновить';

  @override
  String get serversLoadFailed =>
      'Не удалось загрузить список серверов. Проверьте подключение к интернету и попробуйте снова.';

  @override
  String get protocolsTitle => 'Протоколы';

  @override
  String get protocolSheetTitle => 'Протокол';

  @override
  String get protocolNameVlessWs => 'VLESS WS';

  @override
  String get protocolNameHysteria2 => 'Hysteria 2';

  @override
  String get protocolNameGraniWg => 'WireGuard obf';

  @override
  String get protocolSheetVlessWsSubtitle => 'TCP/WebSocket для строгих сетей';

  @override
  String get protocolSheetHysteria2Subtitle =>
      'QUIC/UDP маршрут для нестабильной сети';

  @override
  String get protocolSheetGraniWgSubtitle =>
      'Быстрый WireGuard с маскировкой трафика';

  @override
  String get protocolSheetFallbackSubtitle =>
      'Альтернативный маршрут подключения';

  @override
  String get protocolsUnavailable => 'Протоколы не доступны';

  @override
  String get protocolsSelectServer => 'Выберите сервер';

  @override
  String get profileSubscriptionSection => 'Подписка';

  @override
  String get profileSubscriptionPlan => 'План:';

  @override
  String get profileSubscriptionPlanNameFallback => 'Premium';

  @override
  String get profileNextPayment => 'Следующий платеж';

  @override
  String get profileTrialAccess => 'Тестовый доступ';

  @override
  String get profileTrialEnds => 'Заканчивается:';

  @override
  String get profileNoPlan => 'Подписка отсутствует';

  @override
  String get profileChoosePlanContinue => 'Выберите тариф, чтобы продолжить';

  @override
  String get profileGooglePlayManage => 'Управление подпиской в Google Play';

  @override
  String get profileGooglePlayOpenFailed => 'Не удалось открыть Google Play';

  @override
  String get notificationChannelName => 'GRANI';

  @override
  String get notificationChannelDescription => 'Уведомления от GRANI';

  @override
  String get profileLogoutDisconnectWarning =>
      'Не удалось корректно завершить подключение. Вы вышли из аккаунта.';

  @override
  String get profileLogoutSemantic => 'Выйти из аккаунта';

  @override
  String get profileLogoutButton => 'Выйти из аккаунта';

  @override
  String get profileLogoutDialogTitle => 'Выйти из аккаунта?';

  @override
  String get profileLogoutDialogBody =>
      'VPN будет отключён. Вы сможете войти снова в любое время.';

  @override
  String get profileLogoutDialogCancel => 'Отмена';

  @override
  String get profileLogoutDialogConfirm => 'Выйти';

  @override
  String get serverLabelPlaceholder => '—';

  @override
  String get trialUiTitle => 'Тест активен';

  @override
  String get trialUiConnectingTitle => 'Подключение...';

  @override
  String get trialUiDisconnectingTitle => 'Отключение...';

  @override
  String get trialUiConnectedTitle => 'Защищено';

  @override
  String get trialUiSubtitleInitial =>
      'У вас есть 24 часа защищённого доступа.';

  @override
  String get trialUiSubtitleDisconnected =>
      'Нажмите, чтобы подключиться и начать тест.';

  @override
  String get trialUiSubtitleConnected => 'Трафик в тестовом периоде защищён.';

  @override
  String get trialUiDisconnectingSubtitle => 'Завершаем защищённое соединение';

  @override
  String get trialTimerPrefix => 'осталось: ';

  @override
  String get devicesScreenTitle => 'Мои устройства';

  @override
  String get devicesConnectedPrefix => 'Подключено ';

  @override
  String get devicesConnectedSuffix => ' устройств';

  @override
  String get devicesHintChangePhone =>
      'Если вы сменили телефон — удалите старое устройство.';

  @override
  String get devicesLimitExceeded =>
      'Лимит превышен. Удалите лишние устройства.';

  @override
  String get devicesLimitReached =>
      'Лимит достигнут. Чтобы добавить новое устройство, удалите одно из списка.';

  @override
  String get devicesRetry => 'Повторить';

  @override
  String get devicesEmptyTitle => 'Нет устройств';

  @override
  String get devicesEmptySubtitle =>
      'Подключите VPN — устройство появится здесь';

  @override
  String get devicesDeletedSnackbar => 'Устройство удалено';

  @override
  String get deviceLimitTitle => 'Превышен лимит устройств';

  @override
  String deviceLimitSubtitle(Object count, Object max) {
    return 'К вашему аккаунту привязано $count устройств.\nМаксимум - $max. Для продолжения удалите лишние устройства.';
  }

  @override
  String deviceLimitCount(Object current, Object max) {
    return '$current / $max устройств';
  }

  @override
  String get deviceLimitBottomHint =>
      'После удаления, сможете вновь подключить VPN';

  @override
  String get deviceLimitEmptyList =>
      'Список устройств пуст.\nПопробуйте обновить.';

  @override
  String get deviceListConnectionError =>
      'Проблема с соединением.\nПопробуйте снова.';

  @override
  String get deviceDeleteFailedGeneric =>
      'Не удалось удалить устройство. Попробуйте снова.';

  @override
  String get deviceActiveNow => 'Активно сейчас';

  @override
  String get deviceThisDevice => 'Это устройство';

  @override
  String get deviceRemove => 'Убрать';

  @override
  String get deviceCancel => 'Отмена';

  @override
  String get deviceConfirm => 'Подтвердить';

  @override
  String get deviceRecentlyActive => 'Было недавно';

  @override
  String get deviceAndroidGeneric => 'Android устройство';

  @override
  String get deviceWindowsPc => 'Windows ПК';

  @override
  String get deviceIphone => 'iPhone';

  @override
  String get deviceGenericName => 'Устройство';

  @override
  String deviceFallbackName(Object id) {
    return 'Устройство $id';
  }

  @override
  String get deviceLastSeenMonthAgo => 'Было больше месяца назад';

  @override
  String get deviceLastSeenWeekAgo => 'Было неделю назад';

  @override
  String get deviceLastSeenYesterday => 'Было вчера';

  @override
  String deviceLastSeenHoursAgo(Object n) {
    return 'Был $n ч назад';
  }

  @override
  String deviceLastSeenMinutesAgo(Object n) {
    return 'Был $n мин назад';
  }

  @override
  String get deviceLastSeenJustNow => 'Только что';

  @override
  String get splitTunnelPresetBanks => 'Банки';

  @override
  String get splitTunnelPresetGov => 'Госуслуги';

  @override
  String get splitTunnelPresetMaps => 'Карты';

  @override
  String get splitTunnelPresetMessengers => 'Мессенджеры';

  @override
  String get splitTunnelPresetVideo => 'Видео';

  @override
  String get splitTunnelPresetGames => 'Игры';

  @override
  String splitTunnelPresetGroupAlreadyAdded(Object name) {
    return 'Группа «$name» уже добавлена.';
  }

  @override
  String splitTunnelPresetGroupAddedApps(Object name, Object count) {
    return '«$name»: добавлено $count прил.';
  }

  @override
  String get tariffBadgeMonthOne => 'месяц';

  @override
  String get tariffBadgeMonthsMany => 'месяцев';

  @override
  String get tariffPriceMonthly => '8\$ в месяц';

  @override
  String get tariffPriceSixMonth => '6,8\$ в месяц';

  @override
  String get tariffPriceYearly => '5,6\$ в месяц';

  @override
  String get tariffDescMonthly => 'Для тех, кто хочет начать без обязательств';

  @override
  String get tariffDescSixMonth =>
      '40,8\$ - 15% скидка\nБаланс выгоды и гибкости';

  @override
  String get tariffDescYearly => '67,2\$ - 30% скидка\nСамый выгодный вариант';

  @override
  String get subscriptionSnackbarPlanChanged => 'Тариф успешно изменён';

  @override
  String get subscriptionSnackbarActivated => 'Подписка активирована';

  @override
  String get subscriptionPaymentNotVerified =>
      'Оплата в Google Play прошла, но сервер не подтвердил подписку (часто из‑за сети). Подтверждение повторится при появлении сети; можно обновить статус позже.';

  @override
  String get subscriptionPurchaseIncomplete =>
      'Операция не завершена. Можно повторить попытку.';

  @override
  String get subscriptionPurchaseError => 'Ошибка оплаты. Попробуйте снова.';

  @override
  String get subscriptionGooglePlayUnavailable =>
      'Покупки через Google Play недоступны на этом устройстве.';

  @override
  String get vpnDisconnectedAccessExpired =>
      'VPN отключен из-за окончания доступа.';

  @override
  String get connectRetryGeneric =>
      'Не удалось подключиться. Попробуйте снова.';

  @override
  String get subscriptionActivatedTitle => 'Подписка активирована!';

  @override
  String get subscriptionActivatedSubtitle =>
      'Доступ открыт! 1 месяц полной скорости и защиты';

  @override
  String get subscriptionReadyToConnect => 'готово к подключению';

  @override
  String get paymentFailedTitle => 'Оплата не прошла';

  @override
  String get paymentFailedBody => 'Мы не смогли списать оплату.';

  @override
  String get paymentFailedRetry => 'Повторить оплату';

  @override
  String get paymentTariffTitleOneMonth => '1 месяц';

  @override
  String get paymentTariffTitleSixMonths => '6 месяцев';

  @override
  String get paymentTariffTitleOneYear => '1 год';

  @override
  String get paymentTariffPriceMonthly => '399 ₽ мес.';

  @override
  String get paymentTariffPriceSixMonth => '340 ₽ мес.';

  @override
  String get paymentTariffPriceYearly => '279 ₽ мес.';

  @override
  String get paymentTariffDescMonthly =>
      'Для тех, кто хочет начать без обязательств';

  @override
  String get paymentTariffDescSixMonth =>
      '2035 ₽ - 15% скидка\nБаланс выгоды и гибкости';

  @override
  String get paymentTariffDescYearly =>
      '3352 ₽ - 30% скидка\nСамый выгодный вариант';

  @override
  String get termsOfUseLink => 'Условия использования';

  @override
  String get authEmailTitle => 'Введите email';

  @override
  String get authEmailSubtitle => 'Мы отправим вам код подтверждения';

  @override
  String get authEmailFieldHint => 'Введите email';

  @override
  String get authEmailErrorEmpty => 'Введите email';

  @override
  String get authEmailErrorInvalidFormat => 'Введите корректный email';

  @override
  String get authEmailSendCode => 'Отправить код';

  @override
  String get authEmailSendFailedGeneric =>
      'Не удалось отправить код. Попробуйте снова.';

  @override
  String get authCodeTitle => 'Введите код';

  @override
  String get authCodeSubtitle => 'Мы отправили код вам на email';

  @override
  String get authCodePinLabel => 'PIN-код';

  @override
  String get authCodeErrorInvalidFallback => 'Неверный код, попробуйте ещё раз';

  @override
  String get authCodeVerifying => 'Проверяем код...';

  @override
  String get authCodeEnterCode => 'Введите код';

  @override
  String authCodeResendWithCountdown(int seconds) {
    return 'Отправить код повторно ($seconds)';
  }

  @override
  String get authCodeResend => 'Отправить код повторно';

  @override
  String get authCodeNewSent => 'Новый код отправлен на почту';

  @override
  String authCodeResendWaitSeconds(int seconds) {
    return 'Повторная отправка доступна через $seconds сек.';
  }
}
