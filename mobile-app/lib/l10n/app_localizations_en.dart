// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appLanguageEnglish => 'English';

  @override
  String get appLanguageRussian => 'Russian';

  @override
  String get profileTitle => 'Profile';

  @override
  String get profileClose => 'Close';

  @override
  String get profileEmailCopied => 'Email copied';

  @override
  String get profileShareFailed => 'Could not open share menu';

  @override
  String get profileOpenTelegramFailed => 'Could not open Telegram';

  @override
  String get profileSupportInfoCopied =>
      'Support details copied. Paste them in Telegram chat.';

  @override
  String get profileSupport => 'Support';

  @override
  String get profileAccount => 'Account';

  @override
  String get profileDevices => 'Devices';

  @override
  String get profileDevicesConnected => 'connected';

  @override
  String profileDevicesFrom(Object connected, Object limit) {
    return '$connected of $limit ';
  }

  @override
  String get profileCopyEmail => 'Copy email';

  @override
  String get profileOpenDevices => 'Open devices list';

  @override
  String get profileSelectSplitTunnelApps => 'Select apps for VPN bypass';

  @override
  String get profileCopyVersion => 'Copy version';

  @override
  String get profileSupportChat => 'Contact support';

  @override
  String get profileSupportChatSubtitle =>
      'Telegram chat with diagnostic details';

  @override
  String get profileSupportChatSemantic =>
      'Open GRANI support chat in Telegram';

  @override
  String get profileDiagnostics => 'Send diagnostics';

  @override
  String get profileDiagnosticsSubtitle => 'Technical report for support';

  @override
  String get profileDiagnosticsSemantic => 'Send GRANI diagnostic report';

  @override
  String get profileDiagnosticsSent => 'Diagnostics sent.';

  @override
  String get profileDiagnosticsFailed => 'Could not send diagnostics.';

  @override
  String get profileSupportAccessPremium => 'Premium active';

  @override
  String get profileSupportAccessTrial => 'Trial active';

  @override
  String get profileSupportAccessLimited => 'Access limited';

  @override
  String get profileSupportVpnConnected => 'Connected';

  @override
  String get profileSupportVpnConnecting => 'Connecting';

  @override
  String get profileSupportVpnDisconnecting => 'Disconnecting';

  @override
  String get profileSupportVpnDisconnected => 'Disconnected';

  @override
  String get profileSupportVpnError => 'Error';

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
    return 'Hello GRANI support.\n\nProblem:\n\nTechnical context\nUser ID: $userId\nEmail: $email\nApp: $appVersion+$buildNumber\nLanguage: $language\nAccess: $accessStatus\nVPN: $vpnState\nServer: $server\nProtocol: $protocol\nDevice: $platform\nTime UTC: $timeUtc\n\nPlease describe what happened above.';
  }

  @override
  String get profileSharePrefix => 'Share';

  @override
  String get profileShareGrani => 'Share GRANI';

  @override
  String profileSharePlayStoreMessage(Object url) {
    return 'GRANI. Install:\n$url';
  }

  @override
  String get notificationJournalMenu => 'Notification log';

  @override
  String get notificationJournalScreenTitle => 'Notification log';

  @override
  String get notificationJournalEmpty => 'No notifications yet';

  @override
  String get notificationJournalClear => 'Clear all';

  @override
  String get notificationJournalClearTitle => 'Clear log?';

  @override
  String get notificationJournalClearConfirm =>
      'Remove all entries from this log?';

  @override
  String get notificationJournalSourceForeground => 'While app open';

  @override
  String get notificationJournalSourceOpenedApp => 'From notification tap';

  @override
  String get notificationJournalSourceInitial => 'From cold start';

  @override
  String get notificationJournalSourceBackground => 'In background';

  @override
  String get notificationJournalPushStopTitle => 'GRANI';

  @override
  String notificationJournalPushStopBody(Object reason) {
    return 'Connection stopped ($reason)';
  }

  @override
  String get notificationJournalDataPayloadTitle => 'Message';

  @override
  String notificationJournalDataPayloadBody(Object summary) {
    return '$summary';
  }

  @override
  String get notificationJournalEmptySubtitle =>
      'Subscription and payment updates from GRANI will appear here.';

  @override
  String get notificationJournalFallbackPaymentCompletedTitle =>
      'Payment received';

  @override
  String get notificationJournalFallbackPaymentCompletedBody =>
      'Your subscription has been extended.';

  @override
  String get notificationJournalFallbackSubscriptionRevokedTitle =>
      'Subscription cancelled';

  @override
  String get notificationJournalFallbackSubscriptionRevokedBody =>
      'VPN access is paused. Subscribe again to continue.';

  @override
  String get notificationJournalFallbackSubscriptionExpiredTitle =>
      'Subscription expired';

  @override
  String get notificationJournalFallbackSubscriptionExpiredBody =>
      'Renew in the GRANI app to restore VPN access.';

  @override
  String get notificationJournalFallbackSubscriptionExpiryWarningTitle =>
      'Subscription expiring soon';

  @override
  String get notificationJournalFallbackSubscriptionExpiryWarningBody =>
      'Renew before the end date to keep access.';

  @override
  String get notificationJournalFallbackTrialEndedTitle => 'Trial ended';

  @override
  String get notificationJournalFallbackTrialEndedBody =>
      'Subscribe to continue using GRANI.';

  @override
  String get notificationJournalFallbackTrialActivatedTitle =>
      'Trial access enabled';

  @override
  String get notificationJournalFallbackTrialActivatedBody =>
      'You can connect now.';

  @override
  String get trialAccessActivatedSnackbar =>
      'Trial access enabled. You can connect now.';

  @override
  String get profileAbout => 'About';

  @override
  String get profileVersion => 'Version';

  @override
  String get profileVersionCopied => 'Version copied';

  @override
  String get profileLanguage => 'Language';

  @override
  String get profileLanguageValue => 'Set';

  @override
  String get profileSubscriptionActive => 'Active';

  @override
  String profileSubscriptionActiveUntil(Object date) {
    return 'Active until $date';
  }

  @override
  String profileTrialUntil(Object date) {
    return 'Trial until $date';
  }

  @override
  String get profileAccessLimited => 'Access limited';

  @override
  String get profileNoSubscription => 'No subscription';

  @override
  String get splitTunnelTitle => 'Split tunneling';

  @override
  String get splitTunnelTabApps => 'Applications';

  @override
  String get splitTunnelTabDomains => 'Domains';

  @override
  String get splitTunnelSearchApps => 'Search app';

  @override
  String get splitTunnelSearchDomains => 'Search domain';

  @override
  String get splitTunnelAndroidOnly =>
      'This section is only available on Android';

  @override
  String get splitTunnelAddDomain => 'Add domain';

  @override
  String get splitTunnelModeHintExclude => 'Mode: selected apps bypass VPN';

  @override
  String get splitTunnelModeHintInclude =>
      'Mode: only selected apps go through VPN';

  @override
  String get splitTunnelModeExclude => 'Bypass VPN';

  @override
  String get splitTunnelModeInclude => 'Only through VPN';

  @override
  String get splitTunnelPresetsHint =>
      'Quick groups add installed apps from a category.';

  @override
  String get splitTunnelNoApps => 'No apps';

  @override
  String get splitTunnelNothingFound => 'Nothing found';

  @override
  String get splitTunnelNoDomains => 'No domains added';

  @override
  String get splitTunnelDomainsHint =>
      'Domains bypass VPN after reconnect: the app resolves them to IPs and caches them on device. For Chrome, disable Secure DNS, and on Android disable Private DNS, otherwise the browser may use a different IP.';

  @override
  String get splitTunnelReconnectConnected =>
      'Changes are saved. Disconnect and reconnect VPN manually to apply them.';

  @override
  String get splitTunnelReconnectDisconnected =>
      'Changes will be applied on next VPN connection';

  @override
  String get splitTunnelAppAdded => 'Application added to list.';

  @override
  String get splitTunnelAppRemoved => 'Application removed from list.';

  @override
  String get splitTunnelDomainAdded => 'Domain added.';

  @override
  String get splitTunnelDomainRemoved => 'Domain removed.';

  @override
  String get splitTunnelModeExcludeChanged => 'Mode changed: bypass VPN.';

  @override
  String get splitTunnelModeIncludeChanged => 'Mode changed: only through VPN.';

  @override
  String splitTunnelPresetNoApps(Object label) {
    return 'No matching apps found for group \"$label\".';
  }

  @override
  String get trialExpiredTitle => 'To continue, choose a plan';

  @override
  String get trialExpiredSubtitle =>
      'Get a subscription and receive full speed and protection access.';

  @override
  String get trialUpgradeTitle => 'Choose a plan';

  @override
  String get trialUpgradeSubtitle =>
      'Subscribe in advance - access will continue without interruption.';

  @override
  String get trialManageTitle => 'Manage subscription';

  @override
  String get trialManageSubtitle => 'Extend or change your plan.';

  @override
  String get trialTimeLeft => 'left: 00:00';

  @override
  String get homeReadyTitle => 'Ready';

  @override
  String get homeReadySubtitle => 'Tap to connect';

  @override
  String get homeProtectedTitle => 'Protected';

  @override
  String get homeProtectedSubtitle => 'Traffic is secured';

  @override
  String get homeConnectionFailedTitle => 'Connection failed';

  @override
  String get homeConnectionFailedSubtitle => 'Check the network and try again';

  @override
  String get homeSubscriptionActive => 'Subscription active';

  @override
  String get homeConnecting => 'Connecting...';

  @override
  String get homeDisconnecting => 'Disconnecting...';

  @override
  String get homeServiceReady => 'Service is active and ready to connect';

  @override
  String get homeConnectionFailed =>
      'Could not connect. Press the button to retry';

  @override
  String get homeConnectionActive =>
      'Connection established, traffic is protected';

  @override
  String get homeDisconnectingSubtitle => 'Finishing secure connection';

  @override
  String get homeSelectorLocked =>
      'Disconnect VPN to change the server or protocol';

  @override
  String errorAppStartup(Object error) {
    return 'Startup error: $error';
  }

  @override
  String get errorConnectionTimeout =>
      'Connection timeout exceeded. Check internet connection.';

  @override
  String get errorSendTimeout => 'Data send timeout exceeded.';

  @override
  String get errorReceiveTimeout => 'Data receive timeout exceeded.';

  @override
  String get errorRequestCancelled => 'Request cancelled.';

  @override
  String get errorConnection => 'Connection error. Check internet connection.';

  @override
  String get errorCertificate => 'Certificate error.';

  @override
  String get errorServerUnavailable =>
      'Server is unavailable. Check internet connection.';

  @override
  String get errorNetworkUnavailable =>
      'Network is unavailable. Check internet connection.';

  @override
  String errorUnknownNetwork(Object error) {
    return 'Unknown network error: $error';
  }

  @override
  String get errorServerGeneric => 'Server error.';

  @override
  String get errorHttp400 => 'Invalid request. Check entered data.';

  @override
  String get errorHttp401 => 'Authorization required. Please sign in.';

  @override
  String get errorHttp403 => 'Access denied.';

  @override
  String get errorHttp404 => 'Resource not found.';

  @override
  String get errorHttp409 => 'Data conflict.';

  @override
  String get errorHttp422 => 'Validation error.';

  @override
  String get errorHttp429 => 'Too many requests. Try again later.';

  @override
  String get errorHttp500 => 'Internal server error.';

  @override
  String get errorHttp502 => 'Server is temporarily unavailable.';

  @override
  String get errorHttp503 => 'Service is temporarily unavailable.';

  @override
  String errorHttpCode(Object code) {
    return 'Server error (code: $code).';
  }

  @override
  String get errorAuthRelogin => 'Authorization error. Please sign in again.';

  @override
  String get errorForbiddenRights => 'Access denied. Check your permissions.';

  @override
  String get errorTimeoutGeneric =>
      'Request timeout. Check internet connection.';

  @override
  String get errorNetworkGeneric => 'Network error. Check internet connection.';

  @override
  String get errorVpnPermissionRequired =>
      'VPN permission is required for connection.';

  @override
  String get errorServerProtocolNotSupported =>
      'Server does not support selected protocol. Choose another protocol.';

  @override
  String get errorVpnConfig =>
      'VPN configuration error. Try selecting another server.';

  @override
  String get errorDeviceAlreadyConnected =>
      'Device is already connected. Disconnect it on another device or try again.';

  @override
  String get errorSessionExpired => 'Session expired. Sign in again.';

  @override
  String get authServiceUnavailable => 'Service temporarily unavailable';

  @override
  String get authGoogleCancelled => 'Google sign-in cancelled';

  @override
  String get authTryAgain => 'Try again';

  @override
  String get startHeadline => 'Go beyond limits';

  @override
  String get startSubtitle =>
      'Access the whole world,\nprotection and speed — one tap away';

  @override
  String get startContinueGoogle => 'Continue with Google';

  @override
  String get startContinueEmail => 'Continue with email';

  @override
  String get startAlreadyHaveAccount => 'Already have an account? ';

  @override
  String get startSignIn => 'Sign in';

  @override
  String get startPrivacyMore => 'Privacy details';

  @override
  String get connectionSpeedZero => 'Speed: 0 Mbps';

  @override
  String connectionSpeedMbps(Object speed) {
    return 'Speed: $speed Mbps';
  }

  @override
  String get connectionStable => 'Connection stable';

  @override
  String get connectionWaitingTraffic => 'Waiting for traffic...';

  @override
  String get connectionTapCancel => 'Tap to cancel';

  @override
  String get connectionTapRetry => 'Tap to retry';

  @override
  String get connectionStagesTitle => 'Connection stages';

  @override
  String get btnVpnConnect => 'connect';

  @override
  String get btnVpnCancel => 'cancel';

  @override
  String get btnVpnConnecting => 'connecting…';

  @override
  String get btnVpnDisconnecting => 'disconnecting…';

  @override
  String get btnVpnConnected => 'connected';

  @override
  String get btnVpnRetry => 'retry';

  @override
  String get semanticsVpnConnect => 'Connect to VPN';

  @override
  String get semanticsVpnConnecting => 'Connecting…';

  @override
  String get semanticsVpnDisconnecting => 'Disconnecting…';

  @override
  String get semanticsVpnConnectedTapDisconnect =>
      'Connected. Tap to disconnect';

  @override
  String get semanticsVpnErrorRetry => 'Connection error. Tap to retry';

  @override
  String get semanticsVpnTapCancel => 'Tap to cancel';

  @override
  String get vpnProgressConnecting => 'Connecting to server...';

  @override
  String get vpnProgressVpnPermission => 'Checking VPN permission...';

  @override
  String get vpnProgressAuthCheck => 'Checking access...';

  @override
  String get vpnProgressServerSelection => 'Choosing the best server...';

  @override
  String get vpnProgressDeviceRegistration => 'Registering device...';

  @override
  String get vpnProgressConfigFetch => 'Preparing secure profile...';

  @override
  String get vpnProgressConfigProcessing => 'Checking connection parameters...';

  @override
  String get vpnProgressVpnInterface => 'Creating secure tunnel...';

  @override
  String get vpnProgressProtocolStart => 'Starting secure channel...';

  @override
  String get vpnProgressTrafficCheck => 'Verifying protected traffic...';

  @override
  String get vpnProgressConnected => 'Connection established';

  @override
  String get vpnProgressConnectCancelling => 'Cancelling connection...';

  @override
  String get vpnBadgeFastReconnect => 'Quick reconnect';

  @override
  String get vpnBadgeFirstSetup => 'First-time setup';

  @override
  String get vpnWaitSecureTraffic => 'Waiting for secure traffic...';

  @override
  String get vpnConnectPatienceWarm =>
      'Reconnecting is taking longer than usual — please wait, we are still connecting.';

  @override
  String get vpnRetryRouteWarm => 'Trying another connection route...';

  @override
  String get vpnSlowNetworkWarm =>
      'Connection may take longer due to the network.';

  @override
  String get vpnConnectPatienceCold =>
      'First-time setup on a slow network can take up to a minute — please wait, this is normal.';

  @override
  String get vpnOptimizeRoute => 'Optimizing route...';

  @override
  String get vpnSlowNetworkCold =>
      'Slow network is normal, still connecting...';

  @override
  String get connectionStagesProgressSemantic => 'VPN connection progress';

  @override
  String get serversTitle => 'Servers';

  @override
  String get serversNotLoaded => 'Servers not loaded';

  @override
  String get serversRefresh => 'Refresh';

  @override
  String get serversLoadFailed =>
      'Could not load servers. Check your internet connection and try again.';

  @override
  String get protocolsTitle => 'Protocols';

  @override
  String get protocolSheetTitle => 'Protocol';

  @override
  String get protocolNameVlessWs => 'VLESS WS';

  @override
  String get protocolNameHysteria2 => 'Hysteria 2';

  @override
  String get protocolNameGraniWg => 'WireGuard obf';

  @override
  String get protocolSheetVlessWsSubtitle =>
      'TCP/WebSocket path for restrictive networks';

  @override
  String get protocolSheetHysteria2Subtitle =>
      'QUIC/UDP route for unstable networks';

  @override
  String get protocolSheetGraniWgSubtitle =>
      'Fast WireGuard with traffic masking';

  @override
  String get protocolSheetFallbackSubtitle => 'Alternative connection route';

  @override
  String get protocolsUnavailable => 'Protocols unavailable';

  @override
  String get protocolsSelectServer => 'Select a server';

  @override
  String get profileSubscriptionSection => 'Subscription';

  @override
  String get profileSubscriptionPlan => 'Plan:';

  @override
  String get profileSubscriptionPlanNameFallback => 'Premium';

  @override
  String get profileNextPayment => 'Next payment';

  @override
  String get profileTrialAccess => 'Trial access';

  @override
  String get profileTrialEnds => 'Ends:';

  @override
  String get profileNoPlan => 'No subscription';

  @override
  String get profileChoosePlanContinue => 'Choose a plan to continue';

  @override
  String get profileGooglePlayManage => 'Manage subscription in Google Play';

  @override
  String get profileGooglePlayOpenFailed => 'Could not open Google Play';

  @override
  String get notificationChannelName => 'GRANI';

  @override
  String get notificationChannelDescription => 'Notifications from GRANI';

  @override
  String get profileLogoutDisconnectWarning =>
      'Could not disconnect cleanly. You are signed out.';

  @override
  String get profileLogoutSemantic => 'Sign out';

  @override
  String get profileLogoutButton => 'Sign out';

  @override
  String get profileLogoutDialogTitle => 'Sign out?';

  @override
  String get profileLogoutDialogBody =>
      'VPN will be disconnected. You can sign in again anytime.';

  @override
  String get profileLogoutDialogCancel => 'Cancel';

  @override
  String get profileLogoutDialogConfirm => 'Sign out';

  @override
  String get serverLabelPlaceholder => '—';

  @override
  String get trialUiTitle => 'Trial active';

  @override
  String get trialUiConnectingTitle => 'Connecting...';

  @override
  String get trialUiDisconnectingTitle => 'Disconnecting...';

  @override
  String get trialUiConnectedTitle => 'Protected';

  @override
  String get trialUiSubtitleInitial => 'You have 24 hours of protected access.';

  @override
  String get trialUiSubtitleDisconnected => 'Tap to connect and start testing.';

  @override
  String get trialUiSubtitleConnected => 'Trial traffic is secured.';

  @override
  String get trialUiDisconnectingSubtitle => 'Ending secure connection';

  @override
  String get trialTimerPrefix => 'left: ';

  @override
  String get devicesScreenTitle => 'My devices';

  @override
  String get devicesConnectedPrefix => 'Connected ';

  @override
  String get devicesConnectedSuffix => ' devices';

  @override
  String get devicesHintChangePhone =>
      'If you changed your phone, remove the old device.';

  @override
  String get devicesLimitExceeded => 'Limit exceeded. Remove extra devices.';

  @override
  String get devicesLimitReached =>
      'Limit reached. To add a new device, remove one from the list.';

  @override
  String get devicesRetry => 'Retry';

  @override
  String get devicesEmptyTitle => 'No devices';

  @override
  String get devicesEmptySubtitle =>
      'Connect VPN — your device will appear here';

  @override
  String get devicesDeletedSnackbar => 'Device removed';

  @override
  String get deviceLimitTitle => 'Device limit exceeded';

  @override
  String deviceLimitSubtitle(Object count, Object max) {
    return '$count devices are linked to your account.\nMaximum is $max. Remove extra devices to continue.';
  }

  @override
  String deviceLimitCount(Object current, Object max) {
    return '$current / $max devices';
  }

  @override
  String get deviceLimitBottomHint =>
      'After removal, you can connect VPN again.';

  @override
  String get deviceLimitEmptyList => 'Device list is empty.\nTry refreshing.';

  @override
  String get deviceListConnectionError => 'Connection problem.\nTry again.';

  @override
  String get deviceDeleteFailedGeneric => 'Could not remove device. Try again.';

  @override
  String get deviceActiveNow => 'Active now';

  @override
  String get deviceThisDevice => 'This device';

  @override
  String get deviceRemove => 'Remove';

  @override
  String get deviceCancel => 'Cancel';

  @override
  String get deviceConfirm => 'Confirm';

  @override
  String get deviceRecentlyActive => 'Recently active';

  @override
  String get deviceAndroidGeneric => 'Android device';

  @override
  String get deviceWindowsPc => 'Windows PC';

  @override
  String get deviceIphone => 'iPhone';

  @override
  String get deviceGenericName => 'Device';

  @override
  String deviceFallbackName(Object id) {
    return 'Device $id';
  }

  @override
  String get deviceLastSeenMonthAgo => 'Over a month ago';

  @override
  String get deviceLastSeenWeekAgo => 'A week ago';

  @override
  String get deviceLastSeenYesterday => 'Yesterday';

  @override
  String deviceLastSeenHoursAgo(Object n) {
    return '$n h ago';
  }

  @override
  String deviceLastSeenMinutesAgo(Object n) {
    return '$n min ago';
  }

  @override
  String get deviceLastSeenJustNow => 'Just now';

  @override
  String get splitTunnelPresetBanks => 'Banks';

  @override
  String get splitTunnelPresetGov => 'Gov services';

  @override
  String get splitTunnelPresetMaps => 'Maps';

  @override
  String get splitTunnelPresetMessengers => 'Messengers';

  @override
  String get splitTunnelPresetVideo => 'Video';

  @override
  String get splitTunnelPresetGames => 'Games';

  @override
  String splitTunnelPresetGroupAlreadyAdded(Object name) {
    return 'The \"$name\" group is already added.';
  }

  @override
  String splitTunnelPresetGroupAddedApps(Object name, Object count) {
    return '\"$name\": $count app(s) added.';
  }

  @override
  String get tariffBadgeMonthOne => 'month';

  @override
  String get tariffBadgeMonthsMany => 'months';

  @override
  String get tariffPriceMonthly => '\$8/mo';

  @override
  String get tariffPriceSixMonth => '\$6.8/mo';

  @override
  String get tariffPriceYearly => '\$5.6/mo';

  @override
  String get tariffDescMonthly =>
      'For those who want to start without commitment.';

  @override
  String get tariffDescSixMonth =>
      '\$40.8 — 15% off\nBalance of benefit and flexibility';

  @override
  String get tariffDescYearly => '\$67.2 — 30% off\nBest value';

  @override
  String get subscriptionSnackbarPlanChanged => 'Plan updated successfully';

  @override
  String get subscriptionSnackbarActivated => 'Subscription activated';

  @override
  String get subscriptionPaymentNotVerified =>
      'Google Play charged, but the server has not confirmed the subscription yet (often a network issue). Confirmation retries when you are back online; you can refresh status later.';

  @override
  String get subscriptionPurchaseIncomplete =>
      'Purchase was not completed. You can try again.';

  @override
  String get subscriptionPurchaseError => 'Payment error. Please try again.';

  @override
  String get subscriptionGooglePlayUnavailable =>
      'Google Play purchases are not available on this device.';

  @override
  String get vpnDisconnectedAccessExpired =>
      'VPN was disconnected because access expired.';

  @override
  String get connectRetryGeneric => 'Could not connect. Try again.';

  @override
  String get subscriptionActivatedTitle => 'Subscription activated!';

  @override
  String get subscriptionActivatedSubtitle =>
      'Access unlocked! One month of full speed and protection.';

  @override
  String get subscriptionReadyToConnect => 'Ready to connect';

  @override
  String get paymentFailedTitle => 'Payment failed';

  @override
  String get paymentFailedBody => 'We could not complete the charge.';

  @override
  String get paymentFailedRetry => 'Try payment again';

  @override
  String get paymentTariffTitleOneMonth => '1 month';

  @override
  String get paymentTariffTitleSixMonths => '6 months';

  @override
  String get paymentTariffTitleOneYear => '1 year';

  @override
  String get paymentTariffPriceMonthly => '399 ₽/mo';

  @override
  String get paymentTariffPriceSixMonth => '340 ₽/mo';

  @override
  String get paymentTariffPriceYearly => '279 ₽/mo';

  @override
  String get paymentTariffDescMonthly =>
      'For those who want to start without commitment.';

  @override
  String get paymentTariffDescSixMonth =>
      '2,035 ₽ — 15% off\nBalance of benefit and flexibility';

  @override
  String get paymentTariffDescYearly => '3,352 ₽ — 30% off\nBest value';

  @override
  String get termsOfUseLink => 'Terms of use';

  @override
  String get authEmailTitle => 'Enter your email';

  @override
  String get authEmailSubtitle => 'We\'ll send you a confirmation code';

  @override
  String get authEmailFieldHint => 'Email';

  @override
  String get authEmailErrorEmpty => 'Enter your email';

  @override
  String get authEmailErrorInvalidFormat => 'Enter a valid email address';

  @override
  String get authEmailSendCode => 'Send code';

  @override
  String get authEmailSendFailedGeneric =>
      'Could not send the code. Try again.';

  @override
  String get authCodeTitle => 'Enter code';

  @override
  String get authCodeSubtitle => 'We sent a code to your email';

  @override
  String get authCodePinLabel => 'PIN code';

  @override
  String get authCodeErrorInvalidFallback => 'Wrong code, try again';

  @override
  String get authCodeVerifying => 'Verifying code...';

  @override
  String get authCodeEnterCode => 'Enter the code';

  @override
  String authCodeResendWithCountdown(int seconds) {
    return 'Resend code ($seconds)';
  }

  @override
  String get authCodeResend => 'Resend code';

  @override
  String get authCodeNewSent => 'A new code was sent to your email';

  @override
  String authCodeResendWaitSeconds(int seconds) {
    return 'You can resend in $seconds s';
  }
}
