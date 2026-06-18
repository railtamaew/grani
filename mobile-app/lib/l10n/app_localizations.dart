import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ru.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ru')
  ];

  /// No description provided for @appLanguageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get appLanguageEnglish;

  /// No description provided for @appLanguageRussian.
  ///
  /// In en, this message translates to:
  /// **'Russian'**
  String get appLanguageRussian;

  /// No description provided for @profileTitle.
  ///
  /// In en, this message translates to:
  /// **'Profile'**
  String get profileTitle;

  /// No description provided for @profileClose.
  ///
  /// In en, this message translates to:
  /// **'Close'**
  String get profileClose;

  /// No description provided for @profileEmailCopied.
  ///
  /// In en, this message translates to:
  /// **'Email copied'**
  String get profileEmailCopied;

  /// No description provided for @profileShareFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open share menu'**
  String get profileShareFailed;

  /// No description provided for @profileOpenTelegramFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open Telegram'**
  String get profileOpenTelegramFailed;

  /// No description provided for @profileSupportInfoCopied.
  ///
  /// In en, this message translates to:
  /// **'Support details copied. Paste them in Telegram chat.'**
  String get profileSupportInfoCopied;

  /// No description provided for @profileSupport.
  ///
  /// In en, this message translates to:
  /// **'Support'**
  String get profileSupport;

  /// No description provided for @profileAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get profileAccount;

  /// No description provided for @profileDevices.
  ///
  /// In en, this message translates to:
  /// **'Devices'**
  String get profileDevices;

  /// No description provided for @profileDevicesConnected.
  ///
  /// In en, this message translates to:
  /// **'connected'**
  String get profileDevicesConnected;

  /// No description provided for @profileDevicesFrom.
  ///
  /// In en, this message translates to:
  /// **'{connected} of {limit} '**
  String profileDevicesFrom(Object connected, Object limit);

  /// No description provided for @profileCopyEmail.
  ///
  /// In en, this message translates to:
  /// **'Copy email'**
  String get profileCopyEmail;

  /// No description provided for @profileOpenDevices.
  ///
  /// In en, this message translates to:
  /// **'Open devices list'**
  String get profileOpenDevices;

  /// No description provided for @profileSelectSplitTunnelApps.
  ///
  /// In en, this message translates to:
  /// **'Select apps for VPN bypass'**
  String get profileSelectSplitTunnelApps;

  /// No description provided for @profileCopyVersion.
  ///
  /// In en, this message translates to:
  /// **'Copy version'**
  String get profileCopyVersion;

  /// No description provided for @profileSupportChat.
  ///
  /// In en, this message translates to:
  /// **'Contact support'**
  String get profileSupportChat;

  /// No description provided for @profileSupportChatSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Telegram chat with diagnostic details'**
  String get profileSupportChatSubtitle;

  /// No description provided for @profileSupportChatSemantic.
  ///
  /// In en, this message translates to:
  /// **'Open GRANI support chat in Telegram'**
  String get profileSupportChatSemantic;

  /// No description provided for @profileDiagnostics.
  ///
  /// In en, this message translates to:
  /// **'Send diagnostics'**
  String get profileDiagnostics;

  /// No description provided for @profileDiagnosticsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Technical report for support'**
  String get profileDiagnosticsSubtitle;

  /// No description provided for @profileDiagnosticsSemantic.
  ///
  /// In en, this message translates to:
  /// **'Send GRANI diagnostic report'**
  String get profileDiagnosticsSemantic;

  /// No description provided for @profileDiagnosticsSent.
  ///
  /// In en, this message translates to:
  /// **'Diagnostics sent.'**
  String get profileDiagnosticsSent;

  /// No description provided for @profileDiagnosticsFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not send diagnostics.'**
  String get profileDiagnosticsFailed;

  /// No description provided for @profileSupportAccessPremium.
  ///
  /// In en, this message translates to:
  /// **'Premium active'**
  String get profileSupportAccessPremium;

  /// No description provided for @profileSupportAccessTrial.
  ///
  /// In en, this message translates to:
  /// **'Trial active'**
  String get profileSupportAccessTrial;

  /// No description provided for @profileSupportAccessLimited.
  ///
  /// In en, this message translates to:
  /// **'Access limited'**
  String get profileSupportAccessLimited;

  /// No description provided for @profileSupportVpnConnected.
  ///
  /// In en, this message translates to:
  /// **'Connected'**
  String get profileSupportVpnConnected;

  /// No description provided for @profileSupportVpnConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting'**
  String get profileSupportVpnConnecting;

  /// No description provided for @profileSupportVpnDisconnecting.
  ///
  /// In en, this message translates to:
  /// **'Disconnecting'**
  String get profileSupportVpnDisconnecting;

  /// No description provided for @profileSupportVpnDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Disconnected'**
  String get profileSupportVpnDisconnected;

  /// No description provided for @profileSupportVpnError.
  ///
  /// In en, this message translates to:
  /// **'Error'**
  String get profileSupportVpnError;

  /// No description provided for @profileSupportPreparedMessage.
  ///
  /// In en, this message translates to:
  /// **'Hello GRANI support.\n\nProblem:\n\nTechnical context\nUser ID: {userId}\nEmail: {email}\nApp: {appVersion}+{buildNumber}\nLanguage: {language}\nAccess: {accessStatus}\nVPN: {vpnState}\nServer: {server}\nProtocol: {protocol}\nDevice: {platform}\nTime UTC: {timeUtc}\n\nPlease describe what happened above.'**
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
      Object timeUtc);

  /// No description provided for @profileSharePrefix.
  ///
  /// In en, this message translates to:
  /// **'Share'**
  String get profileSharePrefix;

  /// No description provided for @profileShareGrani.
  ///
  /// In en, this message translates to:
  /// **'Share GRANI'**
  String get profileShareGrani;

  /// No description provided for @profileSharePlayStoreMessage.
  ///
  /// In en, this message translates to:
  /// **'GRANI. Install:\n{url}'**
  String profileSharePlayStoreMessage(Object url);

  /// No description provided for @notificationJournalMenu.
  ///
  /// In en, this message translates to:
  /// **'Notification log'**
  String get notificationJournalMenu;

  /// No description provided for @notificationJournalScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'Notification log'**
  String get notificationJournalScreenTitle;

  /// No description provided for @notificationJournalEmpty.
  ///
  /// In en, this message translates to:
  /// **'No notifications yet'**
  String get notificationJournalEmpty;

  /// No description provided for @notificationJournalClear.
  ///
  /// In en, this message translates to:
  /// **'Clear all'**
  String get notificationJournalClear;

  /// No description provided for @notificationJournalClearTitle.
  ///
  /// In en, this message translates to:
  /// **'Clear log?'**
  String get notificationJournalClearTitle;

  /// No description provided for @notificationJournalClearConfirm.
  ///
  /// In en, this message translates to:
  /// **'Remove all entries from this log?'**
  String get notificationJournalClearConfirm;

  /// No description provided for @notificationJournalSourceForeground.
  ///
  /// In en, this message translates to:
  /// **'While app open'**
  String get notificationJournalSourceForeground;

  /// No description provided for @notificationJournalSourceOpenedApp.
  ///
  /// In en, this message translates to:
  /// **'From notification tap'**
  String get notificationJournalSourceOpenedApp;

  /// No description provided for @notificationJournalSourceInitial.
  ///
  /// In en, this message translates to:
  /// **'From cold start'**
  String get notificationJournalSourceInitial;

  /// No description provided for @notificationJournalSourceBackground.
  ///
  /// In en, this message translates to:
  /// **'In background'**
  String get notificationJournalSourceBackground;

  /// No description provided for @notificationJournalPushStopTitle.
  ///
  /// In en, this message translates to:
  /// **'GRANI'**
  String get notificationJournalPushStopTitle;

  /// No description provided for @notificationJournalPushStopBody.
  ///
  /// In en, this message translates to:
  /// **'Connection stopped ({reason})'**
  String notificationJournalPushStopBody(Object reason);

  /// No description provided for @notificationJournalDataPayloadTitle.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get notificationJournalDataPayloadTitle;

  /// No description provided for @notificationJournalDataPayloadBody.
  ///
  /// In en, this message translates to:
  /// **'{summary}'**
  String notificationJournalDataPayloadBody(Object summary);

  /// No description provided for @notificationJournalEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Subscription and payment updates from GRANI will appear here.'**
  String get notificationJournalEmptySubtitle;

  /// No description provided for @notificationJournalFallbackPaymentCompletedTitle.
  ///
  /// In en, this message translates to:
  /// **'Payment received'**
  String get notificationJournalFallbackPaymentCompletedTitle;

  /// No description provided for @notificationJournalFallbackPaymentCompletedBody.
  ///
  /// In en, this message translates to:
  /// **'Your subscription has been extended.'**
  String get notificationJournalFallbackPaymentCompletedBody;

  /// No description provided for @notificationJournalFallbackSubscriptionRevokedTitle.
  ///
  /// In en, this message translates to:
  /// **'Subscription cancelled'**
  String get notificationJournalFallbackSubscriptionRevokedTitle;

  /// No description provided for @notificationJournalFallbackSubscriptionRevokedBody.
  ///
  /// In en, this message translates to:
  /// **'VPN access is paused. Subscribe again to continue.'**
  String get notificationJournalFallbackSubscriptionRevokedBody;

  /// No description provided for @notificationJournalFallbackSubscriptionExpiredTitle.
  ///
  /// In en, this message translates to:
  /// **'Subscription expired'**
  String get notificationJournalFallbackSubscriptionExpiredTitle;

  /// No description provided for @notificationJournalFallbackSubscriptionExpiredBody.
  ///
  /// In en, this message translates to:
  /// **'Renew in the GRANI app to restore VPN access.'**
  String get notificationJournalFallbackSubscriptionExpiredBody;

  /// No description provided for @notificationJournalFallbackSubscriptionExpiryWarningTitle.
  ///
  /// In en, this message translates to:
  /// **'Subscription expiring soon'**
  String get notificationJournalFallbackSubscriptionExpiryWarningTitle;

  /// No description provided for @notificationJournalFallbackSubscriptionExpiryWarningBody.
  ///
  /// In en, this message translates to:
  /// **'Renew before the end date to keep access.'**
  String get notificationJournalFallbackSubscriptionExpiryWarningBody;

  /// No description provided for @notificationJournalFallbackTrialEndedTitle.
  ///
  /// In en, this message translates to:
  /// **'Trial ended'**
  String get notificationJournalFallbackTrialEndedTitle;

  /// No description provided for @notificationJournalFallbackTrialEndedBody.
  ///
  /// In en, this message translates to:
  /// **'Subscribe to continue using GRANI.'**
  String get notificationJournalFallbackTrialEndedBody;

  /// No description provided for @notificationJournalFallbackTrialActivatedTitle.
  ///
  /// In en, this message translates to:
  /// **'Trial access enabled'**
  String get notificationJournalFallbackTrialActivatedTitle;

  /// No description provided for @notificationJournalFallbackTrialActivatedBody.
  ///
  /// In en, this message translates to:
  /// **'You can connect now.'**
  String get notificationJournalFallbackTrialActivatedBody;

  /// No description provided for @trialAccessActivatedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Trial access enabled. You can connect now.'**
  String get trialAccessActivatedSnackbar;

  /// No description provided for @profileAbout.
  ///
  /// In en, this message translates to:
  /// **'About'**
  String get profileAbout;

  /// No description provided for @profileVersion.
  ///
  /// In en, this message translates to:
  /// **'Version'**
  String get profileVersion;

  /// No description provided for @profileVersionCopied.
  ///
  /// In en, this message translates to:
  /// **'Version copied'**
  String get profileVersionCopied;

  /// No description provided for @profileLanguage.
  ///
  /// In en, this message translates to:
  /// **'Language'**
  String get profileLanguage;

  /// No description provided for @profileLanguageValue.
  ///
  /// In en, this message translates to:
  /// **'Set'**
  String get profileLanguageValue;

  /// No description provided for @profileSubscriptionActive.
  ///
  /// In en, this message translates to:
  /// **'Active'**
  String get profileSubscriptionActive;

  /// No description provided for @profileSubscriptionActiveUntil.
  ///
  /// In en, this message translates to:
  /// **'Active until {date}'**
  String profileSubscriptionActiveUntil(Object date);

  /// No description provided for @profileTrialUntil.
  ///
  /// In en, this message translates to:
  /// **'Trial until {date}'**
  String profileTrialUntil(Object date);

  /// No description provided for @profileAccessLimited.
  ///
  /// In en, this message translates to:
  /// **'Access limited'**
  String get profileAccessLimited;

  /// No description provided for @profileNoSubscription.
  ///
  /// In en, this message translates to:
  /// **'No subscription'**
  String get profileNoSubscription;

  /// No description provided for @splitTunnelTitle.
  ///
  /// In en, this message translates to:
  /// **'Split tunneling'**
  String get splitTunnelTitle;

  /// No description provided for @splitTunnelTabApps.
  ///
  /// In en, this message translates to:
  /// **'Applications'**
  String get splitTunnelTabApps;

  /// No description provided for @splitTunnelTabDomains.
  ///
  /// In en, this message translates to:
  /// **'Domains'**
  String get splitTunnelTabDomains;

  /// No description provided for @splitTunnelSearchApps.
  ///
  /// In en, this message translates to:
  /// **'Search app'**
  String get splitTunnelSearchApps;

  /// No description provided for @splitTunnelSearchDomains.
  ///
  /// In en, this message translates to:
  /// **'Search domain'**
  String get splitTunnelSearchDomains;

  /// No description provided for @splitTunnelAndroidOnly.
  ///
  /// In en, this message translates to:
  /// **'This section is only available on Android'**
  String get splitTunnelAndroidOnly;

  /// No description provided for @splitTunnelAddDomain.
  ///
  /// In en, this message translates to:
  /// **'Add domain'**
  String get splitTunnelAddDomain;

  /// No description provided for @splitTunnelModeHintExclude.
  ///
  /// In en, this message translates to:
  /// **'Mode: selected apps bypass VPN'**
  String get splitTunnelModeHintExclude;

  /// No description provided for @splitTunnelModeHintInclude.
  ///
  /// In en, this message translates to:
  /// **'Mode: only selected apps go through VPN'**
  String get splitTunnelModeHintInclude;

  /// No description provided for @splitTunnelModeExclude.
  ///
  /// In en, this message translates to:
  /// **'Bypass VPN'**
  String get splitTunnelModeExclude;

  /// No description provided for @splitTunnelModeInclude.
  ///
  /// In en, this message translates to:
  /// **'Only through VPN'**
  String get splitTunnelModeInclude;

  /// No description provided for @splitTunnelPresetsHint.
  ///
  /// In en, this message translates to:
  /// **'Quick groups add installed apps from a category.'**
  String get splitTunnelPresetsHint;

  /// No description provided for @splitTunnelNoApps.
  ///
  /// In en, this message translates to:
  /// **'No apps'**
  String get splitTunnelNoApps;

  /// No description provided for @splitTunnelNothingFound.
  ///
  /// In en, this message translates to:
  /// **'Nothing found'**
  String get splitTunnelNothingFound;

  /// No description provided for @splitTunnelNoDomains.
  ///
  /// In en, this message translates to:
  /// **'No domains added'**
  String get splitTunnelNoDomains;

  /// No description provided for @splitTunnelDomainsHint.
  ///
  /// In en, this message translates to:
  /// **'Domains bypass VPN after reconnect: the app resolves them to IPs and caches them on device. For Chrome, disable Secure DNS, and on Android disable Private DNS, otherwise the browser may use a different IP.'**
  String get splitTunnelDomainsHint;

  /// No description provided for @splitTunnelReconnectConnected.
  ///
  /// In en, this message translates to:
  /// **'Changes are saved. Disconnect and reconnect VPN manually to apply them.'**
  String get splitTunnelReconnectConnected;

  /// No description provided for @splitTunnelReconnectDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Changes will be applied on next VPN connection'**
  String get splitTunnelReconnectDisconnected;

  /// No description provided for @splitTunnelAppAdded.
  ///
  /// In en, this message translates to:
  /// **'Application added to list.'**
  String get splitTunnelAppAdded;

  /// No description provided for @splitTunnelAppRemoved.
  ///
  /// In en, this message translates to:
  /// **'Application removed from list.'**
  String get splitTunnelAppRemoved;

  /// No description provided for @splitTunnelDomainAdded.
  ///
  /// In en, this message translates to:
  /// **'Domain added.'**
  String get splitTunnelDomainAdded;

  /// No description provided for @splitTunnelDomainRemoved.
  ///
  /// In en, this message translates to:
  /// **'Domain removed.'**
  String get splitTunnelDomainRemoved;

  /// No description provided for @splitTunnelModeExcludeChanged.
  ///
  /// In en, this message translates to:
  /// **'Mode changed: bypass VPN.'**
  String get splitTunnelModeExcludeChanged;

  /// No description provided for @splitTunnelModeIncludeChanged.
  ///
  /// In en, this message translates to:
  /// **'Mode changed: only through VPN.'**
  String get splitTunnelModeIncludeChanged;

  /// No description provided for @splitTunnelPresetNoApps.
  ///
  /// In en, this message translates to:
  /// **'No matching apps found for group \"{label}\".'**
  String splitTunnelPresetNoApps(Object label);

  /// No description provided for @trialExpiredTitle.
  ///
  /// In en, this message translates to:
  /// **'To continue, choose a plan'**
  String get trialExpiredTitle;

  /// No description provided for @trialExpiredSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Get a subscription and receive full speed and protection access.'**
  String get trialExpiredSubtitle;

  /// No description provided for @trialUpgradeTitle.
  ///
  /// In en, this message translates to:
  /// **'Choose a plan'**
  String get trialUpgradeTitle;

  /// No description provided for @trialUpgradeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Subscribe in advance - access will continue without interruption.'**
  String get trialUpgradeSubtitle;

  /// No description provided for @trialManageTitle.
  ///
  /// In en, this message translates to:
  /// **'Manage subscription'**
  String get trialManageTitle;

  /// No description provided for @trialManageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Extend or change your plan.'**
  String get trialManageSubtitle;

  /// No description provided for @trialTimeLeft.
  ///
  /// In en, this message translates to:
  /// **'left: 00:00'**
  String get trialTimeLeft;

  /// No description provided for @homeReadyTitle.
  ///
  /// In en, this message translates to:
  /// **'Ready'**
  String get homeReadyTitle;

  /// No description provided for @homeReadySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Tap to connect'**
  String get homeReadySubtitle;

  /// No description provided for @homeProtectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Protected'**
  String get homeProtectedTitle;

  /// No description provided for @homeProtectedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Traffic is secured'**
  String get homeProtectedSubtitle;

  /// No description provided for @homeConnectionFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection failed'**
  String get homeConnectionFailedTitle;

  /// No description provided for @homeConnectionFailedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Check the network and try again'**
  String get homeConnectionFailedSubtitle;

  /// No description provided for @homeSubscriptionActive.
  ///
  /// In en, this message translates to:
  /// **'Subscription active'**
  String get homeSubscriptionActive;

  /// No description provided for @homeConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get homeConnecting;

  /// No description provided for @homeDisconnecting.
  ///
  /// In en, this message translates to:
  /// **'Disconnecting...'**
  String get homeDisconnecting;

  /// No description provided for @homeServiceReady.
  ///
  /// In en, this message translates to:
  /// **'Service is active and ready to connect'**
  String get homeServiceReady;

  /// No description provided for @homeConnectionFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not connect. Press the button to retry'**
  String get homeConnectionFailed;

  /// No description provided for @homeConnectionActive.
  ///
  /// In en, this message translates to:
  /// **'Connection established, traffic is protected'**
  String get homeConnectionActive;

  /// No description provided for @homeDisconnectingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Finishing secure connection'**
  String get homeDisconnectingSubtitle;

  /// No description provided for @homeSelectorLocked.
  ///
  /// In en, this message translates to:
  /// **'Disconnect VPN to change the server or protocol'**
  String get homeSelectorLocked;

  /// No description provided for @errorAppStartup.
  ///
  /// In en, this message translates to:
  /// **'Startup error: {error}'**
  String errorAppStartup(Object error);

  /// No description provided for @errorConnectionTimeout.
  ///
  /// In en, this message translates to:
  /// **'Connection timeout exceeded. Check internet connection.'**
  String get errorConnectionTimeout;

  /// No description provided for @errorSendTimeout.
  ///
  /// In en, this message translates to:
  /// **'Data send timeout exceeded.'**
  String get errorSendTimeout;

  /// No description provided for @errorReceiveTimeout.
  ///
  /// In en, this message translates to:
  /// **'Data receive timeout exceeded.'**
  String get errorReceiveTimeout;

  /// No description provided for @errorRequestCancelled.
  ///
  /// In en, this message translates to:
  /// **'Request cancelled.'**
  String get errorRequestCancelled;

  /// No description provided for @errorConnection.
  ///
  /// In en, this message translates to:
  /// **'Connection error. Check internet connection.'**
  String get errorConnection;

  /// No description provided for @errorCertificate.
  ///
  /// In en, this message translates to:
  /// **'Certificate error.'**
  String get errorCertificate;

  /// No description provided for @errorServerUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Server is unavailable. Check internet connection.'**
  String get errorServerUnavailable;

  /// No description provided for @errorNetworkUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Network is unavailable. Check internet connection.'**
  String get errorNetworkUnavailable;

  /// No description provided for @errorUnknownNetwork.
  ///
  /// In en, this message translates to:
  /// **'Unknown network error: {error}'**
  String errorUnknownNetwork(Object error);

  /// No description provided for @errorServerGeneric.
  ///
  /// In en, this message translates to:
  /// **'Server error.'**
  String get errorServerGeneric;

  /// No description provided for @errorHttp400.
  ///
  /// In en, this message translates to:
  /// **'Invalid request. Check entered data.'**
  String get errorHttp400;

  /// No description provided for @errorHttp401.
  ///
  /// In en, this message translates to:
  /// **'Authorization required. Please sign in.'**
  String get errorHttp401;

  /// No description provided for @errorHttp403.
  ///
  /// In en, this message translates to:
  /// **'Access denied.'**
  String get errorHttp403;

  /// No description provided for @errorHttp404.
  ///
  /// In en, this message translates to:
  /// **'Resource not found.'**
  String get errorHttp404;

  /// No description provided for @errorHttp409.
  ///
  /// In en, this message translates to:
  /// **'Data conflict.'**
  String get errorHttp409;

  /// No description provided for @errorHttp422.
  ///
  /// In en, this message translates to:
  /// **'Validation error.'**
  String get errorHttp422;

  /// No description provided for @errorHttp429.
  ///
  /// In en, this message translates to:
  /// **'Too many requests. Try again later.'**
  String get errorHttp429;

  /// No description provided for @errorHttp500.
  ///
  /// In en, this message translates to:
  /// **'Internal server error.'**
  String get errorHttp500;

  /// No description provided for @errorHttp502.
  ///
  /// In en, this message translates to:
  /// **'Server is temporarily unavailable.'**
  String get errorHttp502;

  /// No description provided for @errorHttp503.
  ///
  /// In en, this message translates to:
  /// **'Service is temporarily unavailable.'**
  String get errorHttp503;

  /// No description provided for @errorHttpCode.
  ///
  /// In en, this message translates to:
  /// **'Server error (code: {code}).'**
  String errorHttpCode(Object code);

  /// No description provided for @errorAuthRelogin.
  ///
  /// In en, this message translates to:
  /// **'Authorization error. Please sign in again.'**
  String get errorAuthRelogin;

  /// No description provided for @errorForbiddenRights.
  ///
  /// In en, this message translates to:
  /// **'Access denied. Check your permissions.'**
  String get errorForbiddenRights;

  /// No description provided for @errorTimeoutGeneric.
  ///
  /// In en, this message translates to:
  /// **'Request timeout. Check internet connection.'**
  String get errorTimeoutGeneric;

  /// No description provided for @errorNetworkGeneric.
  ///
  /// In en, this message translates to:
  /// **'Network error. Check internet connection.'**
  String get errorNetworkGeneric;

  /// No description provided for @errorVpnPermissionRequired.
  ///
  /// In en, this message translates to:
  /// **'VPN permission is required for connection.'**
  String get errorVpnPermissionRequired;

  /// No description provided for @errorServerProtocolNotSupported.
  ///
  /// In en, this message translates to:
  /// **'Server does not support selected protocol. Choose another protocol.'**
  String get errorServerProtocolNotSupported;

  /// No description provided for @errorVpnConfig.
  ///
  /// In en, this message translates to:
  /// **'VPN configuration error. Try selecting another server.'**
  String get errorVpnConfig;

  /// No description provided for @errorDeviceAlreadyConnected.
  ///
  /// In en, this message translates to:
  /// **'Device is already connected. Disconnect it on another device or try again.'**
  String get errorDeviceAlreadyConnected;

  /// No description provided for @errorSessionExpired.
  ///
  /// In en, this message translates to:
  /// **'Session expired. Sign in again.'**
  String get errorSessionExpired;

  /// No description provided for @authServiceUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Service temporarily unavailable'**
  String get authServiceUnavailable;

  /// No description provided for @authGoogleCancelled.
  ///
  /// In en, this message translates to:
  /// **'Google sign-in cancelled'**
  String get authGoogleCancelled;

  /// No description provided for @authTryAgain.
  ///
  /// In en, this message translates to:
  /// **'Try again'**
  String get authTryAgain;

  /// No description provided for @startHeadline.
  ///
  /// In en, this message translates to:
  /// **'Go beyond limits'**
  String get startHeadline;

  /// No description provided for @startSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Access the whole world,\nprotection and speed — one tap away'**
  String get startSubtitle;

  /// No description provided for @startContinueGoogle.
  ///
  /// In en, this message translates to:
  /// **'Continue with Google'**
  String get startContinueGoogle;

  /// No description provided for @startContinueEmail.
  ///
  /// In en, this message translates to:
  /// **'Continue with email'**
  String get startContinueEmail;

  /// No description provided for @startAlreadyHaveAccount.
  ///
  /// In en, this message translates to:
  /// **'Already have an account? '**
  String get startAlreadyHaveAccount;

  /// No description provided for @startSignIn.
  ///
  /// In en, this message translates to:
  /// **'Sign in'**
  String get startSignIn;

  /// No description provided for @startPrivacyMore.
  ///
  /// In en, this message translates to:
  /// **'Privacy details'**
  String get startPrivacyMore;

  /// No description provided for @connectionSpeedZero.
  ///
  /// In en, this message translates to:
  /// **'Speed: 0 Mbps'**
  String get connectionSpeedZero;

  /// No description provided for @connectionSpeedMbps.
  ///
  /// In en, this message translates to:
  /// **'Speed: {speed} Mbps'**
  String connectionSpeedMbps(Object speed);

  /// No description provided for @connectionStable.
  ///
  /// In en, this message translates to:
  /// **'Connection stable'**
  String get connectionStable;

  /// No description provided for @connectionWaitingTraffic.
  ///
  /// In en, this message translates to:
  /// **'Waiting for traffic...'**
  String get connectionWaitingTraffic;

  /// No description provided for @connectionTapCancel.
  ///
  /// In en, this message translates to:
  /// **'Tap to cancel'**
  String get connectionTapCancel;

  /// No description provided for @connectionTapRetry.
  ///
  /// In en, this message translates to:
  /// **'Tap to retry'**
  String get connectionTapRetry;

  /// No description provided for @connectionStagesTitle.
  ///
  /// In en, this message translates to:
  /// **'Connection stages'**
  String get connectionStagesTitle;

  /// No description provided for @btnVpnConnect.
  ///
  /// In en, this message translates to:
  /// **'connect'**
  String get btnVpnConnect;

  /// No description provided for @btnVpnCancel.
  ///
  /// In en, this message translates to:
  /// **'cancel'**
  String get btnVpnCancel;

  /// No description provided for @btnVpnConnecting.
  ///
  /// In en, this message translates to:
  /// **'connecting…'**
  String get btnVpnConnecting;

  /// No description provided for @btnVpnDisconnecting.
  ///
  /// In en, this message translates to:
  /// **'disconnecting…'**
  String get btnVpnDisconnecting;

  /// No description provided for @btnVpnConnected.
  ///
  /// In en, this message translates to:
  /// **'connected'**
  String get btnVpnConnected;

  /// No description provided for @btnVpnRetry.
  ///
  /// In en, this message translates to:
  /// **'retry'**
  String get btnVpnRetry;

  /// No description provided for @semanticsVpnConnect.
  ///
  /// In en, this message translates to:
  /// **'Connect to VPN'**
  String get semanticsVpnConnect;

  /// No description provided for @semanticsVpnConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting…'**
  String get semanticsVpnConnecting;

  /// No description provided for @semanticsVpnDisconnecting.
  ///
  /// In en, this message translates to:
  /// **'Disconnecting…'**
  String get semanticsVpnDisconnecting;

  /// No description provided for @semanticsVpnConnectedTapDisconnect.
  ///
  /// In en, this message translates to:
  /// **'Connected. Tap to disconnect'**
  String get semanticsVpnConnectedTapDisconnect;

  /// No description provided for @semanticsVpnErrorRetry.
  ///
  /// In en, this message translates to:
  /// **'Connection error. Tap to retry'**
  String get semanticsVpnErrorRetry;

  /// No description provided for @semanticsVpnTapCancel.
  ///
  /// In en, this message translates to:
  /// **'Tap to cancel'**
  String get semanticsVpnTapCancel;

  /// No description provided for @vpnProgressConnecting.
  ///
  /// In en, this message translates to:
  /// **'Connecting to server...'**
  String get vpnProgressConnecting;

  /// No description provided for @vpnProgressVpnPermission.
  ///
  /// In en, this message translates to:
  /// **'Checking VPN permission...'**
  String get vpnProgressVpnPermission;

  /// No description provided for @vpnProgressAuthCheck.
  ///
  /// In en, this message translates to:
  /// **'Checking access...'**
  String get vpnProgressAuthCheck;

  /// No description provided for @vpnProgressServerSelection.
  ///
  /// In en, this message translates to:
  /// **'Choosing the best server...'**
  String get vpnProgressServerSelection;

  /// No description provided for @vpnProgressDeviceRegistration.
  ///
  /// In en, this message translates to:
  /// **'Registering device...'**
  String get vpnProgressDeviceRegistration;

  /// No description provided for @vpnProgressConfigFetch.
  ///
  /// In en, this message translates to:
  /// **'Preparing secure profile...'**
  String get vpnProgressConfigFetch;

  /// No description provided for @vpnProgressConfigProcessing.
  ///
  /// In en, this message translates to:
  /// **'Checking connection parameters...'**
  String get vpnProgressConfigProcessing;

  /// No description provided for @vpnProgressVpnInterface.
  ///
  /// In en, this message translates to:
  /// **'Creating secure tunnel...'**
  String get vpnProgressVpnInterface;

  /// No description provided for @vpnProgressProtocolStart.
  ///
  /// In en, this message translates to:
  /// **'Starting secure channel...'**
  String get vpnProgressProtocolStart;

  /// No description provided for @vpnProgressTrafficCheck.
  ///
  /// In en, this message translates to:
  /// **'Verifying protected traffic...'**
  String get vpnProgressTrafficCheck;

  /// No description provided for @vpnProgressConnected.
  ///
  /// In en, this message translates to:
  /// **'Connection established'**
  String get vpnProgressConnected;

  /// No description provided for @vpnProgressConnectCancelling.
  ///
  /// In en, this message translates to:
  /// **'Cancelling connection...'**
  String get vpnProgressConnectCancelling;

  /// No description provided for @vpnBadgeFastReconnect.
  ///
  /// In en, this message translates to:
  /// **'Quick reconnect'**
  String get vpnBadgeFastReconnect;

  /// No description provided for @vpnBadgeFirstSetup.
  ///
  /// In en, this message translates to:
  /// **'First-time setup'**
  String get vpnBadgeFirstSetup;

  /// No description provided for @vpnWaitSecureTraffic.
  ///
  /// In en, this message translates to:
  /// **'Waiting for secure traffic...'**
  String get vpnWaitSecureTraffic;

  /// No description provided for @vpnConnectPatienceWarm.
  ///
  /// In en, this message translates to:
  /// **'Reconnecting is taking longer than usual — please wait, we are still connecting.'**
  String get vpnConnectPatienceWarm;

  /// No description provided for @vpnRetryRouteWarm.
  ///
  /// In en, this message translates to:
  /// **'Trying another connection route...'**
  String get vpnRetryRouteWarm;

  /// No description provided for @vpnSlowNetworkWarm.
  ///
  /// In en, this message translates to:
  /// **'Connection may take longer due to the network.'**
  String get vpnSlowNetworkWarm;

  /// No description provided for @vpnConnectPatienceCold.
  ///
  /// In en, this message translates to:
  /// **'First-time setup on a slow network can take up to a minute — please wait, this is normal.'**
  String get vpnConnectPatienceCold;

  /// No description provided for @vpnOptimizeRoute.
  ///
  /// In en, this message translates to:
  /// **'Optimizing route...'**
  String get vpnOptimizeRoute;

  /// No description provided for @vpnSlowNetworkCold.
  ///
  /// In en, this message translates to:
  /// **'Slow network is normal, still connecting...'**
  String get vpnSlowNetworkCold;

  /// No description provided for @connectionStagesProgressSemantic.
  ///
  /// In en, this message translates to:
  /// **'VPN connection progress'**
  String get connectionStagesProgressSemantic;

  /// No description provided for @serversTitle.
  ///
  /// In en, this message translates to:
  /// **'Servers'**
  String get serversTitle;

  /// No description provided for @serversNotLoaded.
  ///
  /// In en, this message translates to:
  /// **'Servers not loaded'**
  String get serversNotLoaded;

  /// No description provided for @serversRefresh.
  ///
  /// In en, this message translates to:
  /// **'Refresh'**
  String get serversRefresh;

  /// No description provided for @serversLoadFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not load servers. Check your internet connection and try again.'**
  String get serversLoadFailed;

  /// No description provided for @protocolsTitle.
  ///
  /// In en, this message translates to:
  /// **'Protocols'**
  String get protocolsTitle;

  /// No description provided for @protocolSheetTitle.
  ///
  /// In en, this message translates to:
  /// **'Protocol'**
  String get protocolSheetTitle;

  /// No description provided for @protocolNameVlessWs.
  ///
  /// In en, this message translates to:
  /// **'VLESS WS'**
  String get protocolNameVlessWs;

  /// No description provided for @protocolNameHysteria2.
  ///
  /// In en, this message translates to:
  /// **'Hysteria 2'**
  String get protocolNameHysteria2;

  /// No description provided for @protocolNameGraniWg.
  ///
  /// In en, this message translates to:
  /// **'WireGuard obf'**
  String get protocolNameGraniWg;

  /// No description provided for @protocolSheetVlessWsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'TCP/WebSocket path for restrictive networks'**
  String get protocolSheetVlessWsSubtitle;

  /// No description provided for @protocolSheetHysteria2Subtitle.
  ///
  /// In en, this message translates to:
  /// **'QUIC/UDP route for unstable networks'**
  String get protocolSheetHysteria2Subtitle;

  /// No description provided for @protocolSheetGraniWgSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Fast WireGuard with traffic masking'**
  String get protocolSheetGraniWgSubtitle;

  /// No description provided for @protocolSheetFallbackSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Alternative connection route'**
  String get protocolSheetFallbackSubtitle;

  /// No description provided for @protocolsUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Protocols unavailable'**
  String get protocolsUnavailable;

  /// No description provided for @protocolsSelectServer.
  ///
  /// In en, this message translates to:
  /// **'Select a server'**
  String get protocolsSelectServer;

  /// No description provided for @profileSubscriptionSection.
  ///
  /// In en, this message translates to:
  /// **'Subscription'**
  String get profileSubscriptionSection;

  /// No description provided for @profileSubscriptionPlan.
  ///
  /// In en, this message translates to:
  /// **'Plan:'**
  String get profileSubscriptionPlan;

  /// No description provided for @profileSubscriptionPlanNameFallback.
  ///
  /// In en, this message translates to:
  /// **'Premium'**
  String get profileSubscriptionPlanNameFallback;

  /// No description provided for @profileNextPayment.
  ///
  /// In en, this message translates to:
  /// **'Next payment'**
  String get profileNextPayment;

  /// No description provided for @profileTrialAccess.
  ///
  /// In en, this message translates to:
  /// **'Trial access'**
  String get profileTrialAccess;

  /// No description provided for @profileTrialEnds.
  ///
  /// In en, this message translates to:
  /// **'Ends:'**
  String get profileTrialEnds;

  /// No description provided for @profileNoPlan.
  ///
  /// In en, this message translates to:
  /// **'No subscription'**
  String get profileNoPlan;

  /// No description provided for @profileChoosePlanContinue.
  ///
  /// In en, this message translates to:
  /// **'Choose a plan to continue'**
  String get profileChoosePlanContinue;

  /// No description provided for @profileGooglePlayManage.
  ///
  /// In en, this message translates to:
  /// **'Manage subscription in Google Play'**
  String get profileGooglePlayManage;

  /// No description provided for @profileGooglePlayOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Could not open Google Play'**
  String get profileGooglePlayOpenFailed;

  /// No description provided for @notificationChannelName.
  ///
  /// In en, this message translates to:
  /// **'GRANI'**
  String get notificationChannelName;

  /// No description provided for @notificationChannelDescription.
  ///
  /// In en, this message translates to:
  /// **'Notifications from GRANI'**
  String get notificationChannelDescription;

  /// No description provided for @profileLogoutDisconnectWarning.
  ///
  /// In en, this message translates to:
  /// **'Could not disconnect cleanly. You are signed out.'**
  String get profileLogoutDisconnectWarning;

  /// No description provided for @profileLogoutSemantic.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get profileLogoutSemantic;

  /// No description provided for @profileLogoutButton.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get profileLogoutButton;

  /// No description provided for @profileLogoutDialogTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out?'**
  String get profileLogoutDialogTitle;

  /// No description provided for @profileLogoutDialogBody.
  ///
  /// In en, this message translates to:
  /// **'VPN will be disconnected. You can sign in again anytime.'**
  String get profileLogoutDialogBody;

  /// No description provided for @profileLogoutDialogCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get profileLogoutDialogCancel;

  /// No description provided for @profileLogoutDialogConfirm.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get profileLogoutDialogConfirm;

  /// No description provided for @serverLabelPlaceholder.
  ///
  /// In en, this message translates to:
  /// **'—'**
  String get serverLabelPlaceholder;

  /// No description provided for @trialUiTitle.
  ///
  /// In en, this message translates to:
  /// **'Trial active'**
  String get trialUiTitle;

  /// No description provided for @trialUiConnectingTitle.
  ///
  /// In en, this message translates to:
  /// **'Connecting...'**
  String get trialUiConnectingTitle;

  /// No description provided for @trialUiDisconnectingTitle.
  ///
  /// In en, this message translates to:
  /// **'Disconnecting...'**
  String get trialUiDisconnectingTitle;

  /// No description provided for @trialUiConnectedTitle.
  ///
  /// In en, this message translates to:
  /// **'Protected'**
  String get trialUiConnectedTitle;

  /// No description provided for @trialUiSubtitleInitial.
  ///
  /// In en, this message translates to:
  /// **'You have 24 hours of protected access.'**
  String get trialUiSubtitleInitial;

  /// No description provided for @trialUiSubtitleDisconnected.
  ///
  /// In en, this message translates to:
  /// **'Tap to connect and start testing.'**
  String get trialUiSubtitleDisconnected;

  /// No description provided for @trialUiSubtitleConnected.
  ///
  /// In en, this message translates to:
  /// **'Trial traffic is secured.'**
  String get trialUiSubtitleConnected;

  /// No description provided for @trialUiDisconnectingSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Ending secure connection'**
  String get trialUiDisconnectingSubtitle;

  /// No description provided for @trialTimerPrefix.
  ///
  /// In en, this message translates to:
  /// **'left: '**
  String get trialTimerPrefix;

  /// No description provided for @devicesScreenTitle.
  ///
  /// In en, this message translates to:
  /// **'My devices'**
  String get devicesScreenTitle;

  /// No description provided for @devicesConnectedPrefix.
  ///
  /// In en, this message translates to:
  /// **'Connected '**
  String get devicesConnectedPrefix;

  /// No description provided for @devicesConnectedSuffix.
  ///
  /// In en, this message translates to:
  /// **' devices'**
  String get devicesConnectedSuffix;

  /// No description provided for @devicesHintChangePhone.
  ///
  /// In en, this message translates to:
  /// **'If you changed your phone, remove the old device.'**
  String get devicesHintChangePhone;

  /// No description provided for @devicesLimitExceeded.
  ///
  /// In en, this message translates to:
  /// **'Limit exceeded. Remove extra devices.'**
  String get devicesLimitExceeded;

  /// No description provided for @devicesLimitReached.
  ///
  /// In en, this message translates to:
  /// **'Limit reached. To add a new device, remove one from the list.'**
  String get devicesLimitReached;

  /// No description provided for @devicesRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get devicesRetry;

  /// No description provided for @devicesEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No devices'**
  String get devicesEmptyTitle;

  /// No description provided for @devicesEmptySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Connect VPN — your device will appear here'**
  String get devicesEmptySubtitle;

  /// No description provided for @devicesDeletedSnackbar.
  ///
  /// In en, this message translates to:
  /// **'Device removed'**
  String get devicesDeletedSnackbar;

  /// No description provided for @deviceLimitTitle.
  ///
  /// In en, this message translates to:
  /// **'Device limit exceeded'**
  String get deviceLimitTitle;

  /// No description provided for @deviceLimitSubtitle.
  ///
  /// In en, this message translates to:
  /// **'{count} devices are linked to your account.\nMaximum is {max}. Remove extra devices to continue.'**
  String deviceLimitSubtitle(Object count, Object max);

  /// No description provided for @deviceLimitCount.
  ///
  /// In en, this message translates to:
  /// **'{current} / {max} devices'**
  String deviceLimitCount(Object current, Object max);

  /// No description provided for @deviceLimitBottomHint.
  ///
  /// In en, this message translates to:
  /// **'After removal, you can connect VPN again.'**
  String get deviceLimitBottomHint;

  /// No description provided for @deviceLimitEmptyList.
  ///
  /// In en, this message translates to:
  /// **'Device list is empty.\nTry refreshing.'**
  String get deviceLimitEmptyList;

  /// No description provided for @deviceListConnectionError.
  ///
  /// In en, this message translates to:
  /// **'Connection problem.\nTry again.'**
  String get deviceListConnectionError;

  /// No description provided for @deviceDeleteFailedGeneric.
  ///
  /// In en, this message translates to:
  /// **'Could not remove device. Try again.'**
  String get deviceDeleteFailedGeneric;

  /// No description provided for @deviceActiveNow.
  ///
  /// In en, this message translates to:
  /// **'Active now'**
  String get deviceActiveNow;

  /// No description provided for @deviceThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get deviceThisDevice;

  /// No description provided for @deviceRemove.
  ///
  /// In en, this message translates to:
  /// **'Remove'**
  String get deviceRemove;

  /// No description provided for @deviceCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get deviceCancel;

  /// No description provided for @deviceConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm'**
  String get deviceConfirm;

  /// No description provided for @deviceRecentlyActive.
  ///
  /// In en, this message translates to:
  /// **'Recently active'**
  String get deviceRecentlyActive;

  /// No description provided for @deviceAndroidGeneric.
  ///
  /// In en, this message translates to:
  /// **'Android device'**
  String get deviceAndroidGeneric;

  /// No description provided for @deviceWindowsPc.
  ///
  /// In en, this message translates to:
  /// **'Windows PC'**
  String get deviceWindowsPc;

  /// No description provided for @deviceIphone.
  ///
  /// In en, this message translates to:
  /// **'iPhone'**
  String get deviceIphone;

  /// No description provided for @deviceGenericName.
  ///
  /// In en, this message translates to:
  /// **'Device'**
  String get deviceGenericName;

  /// No description provided for @deviceFallbackName.
  ///
  /// In en, this message translates to:
  /// **'Device {id}'**
  String deviceFallbackName(Object id);

  /// No description provided for @deviceLastSeenMonthAgo.
  ///
  /// In en, this message translates to:
  /// **'Over a month ago'**
  String get deviceLastSeenMonthAgo;

  /// No description provided for @deviceLastSeenWeekAgo.
  ///
  /// In en, this message translates to:
  /// **'A week ago'**
  String get deviceLastSeenWeekAgo;

  /// No description provided for @deviceLastSeenYesterday.
  ///
  /// In en, this message translates to:
  /// **'Yesterday'**
  String get deviceLastSeenYesterday;

  /// No description provided for @deviceLastSeenHoursAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} h ago'**
  String deviceLastSeenHoursAgo(Object n);

  /// No description provided for @deviceLastSeenMinutesAgo.
  ///
  /// In en, this message translates to:
  /// **'{n} min ago'**
  String deviceLastSeenMinutesAgo(Object n);

  /// No description provided for @deviceLastSeenJustNow.
  ///
  /// In en, this message translates to:
  /// **'Just now'**
  String get deviceLastSeenJustNow;

  /// No description provided for @splitTunnelPresetBanks.
  ///
  /// In en, this message translates to:
  /// **'Banks'**
  String get splitTunnelPresetBanks;

  /// No description provided for @splitTunnelPresetGov.
  ///
  /// In en, this message translates to:
  /// **'Gov services'**
  String get splitTunnelPresetGov;

  /// No description provided for @splitTunnelPresetMaps.
  ///
  /// In en, this message translates to:
  /// **'Maps'**
  String get splitTunnelPresetMaps;

  /// No description provided for @splitTunnelPresetMessengers.
  ///
  /// In en, this message translates to:
  /// **'Messengers'**
  String get splitTunnelPresetMessengers;

  /// No description provided for @splitTunnelPresetVideo.
  ///
  /// In en, this message translates to:
  /// **'Video'**
  String get splitTunnelPresetVideo;

  /// No description provided for @splitTunnelPresetGames.
  ///
  /// In en, this message translates to:
  /// **'Games'**
  String get splitTunnelPresetGames;

  /// No description provided for @splitTunnelPresetGroupAlreadyAdded.
  ///
  /// In en, this message translates to:
  /// **'The \"{name}\" group is already added.'**
  String splitTunnelPresetGroupAlreadyAdded(Object name);

  /// No description provided for @splitTunnelPresetGroupAddedApps.
  ///
  /// In en, this message translates to:
  /// **'\"{name}\": {count} app(s) added.'**
  String splitTunnelPresetGroupAddedApps(Object name, Object count);

  /// No description provided for @tariffBadgeMonthOne.
  ///
  /// In en, this message translates to:
  /// **'month'**
  String get tariffBadgeMonthOne;

  /// No description provided for @tariffBadgeMonthsMany.
  ///
  /// In en, this message translates to:
  /// **'months'**
  String get tariffBadgeMonthsMany;

  /// No description provided for @tariffPriceMonthly.
  ///
  /// In en, this message translates to:
  /// **'\$8/mo'**
  String get tariffPriceMonthly;

  /// No description provided for @tariffPriceSixMonth.
  ///
  /// In en, this message translates to:
  /// **'\$6.8/mo'**
  String get tariffPriceSixMonth;

  /// No description provided for @tariffPriceYearly.
  ///
  /// In en, this message translates to:
  /// **'\$5.6/mo'**
  String get tariffPriceYearly;

  /// No description provided for @tariffDescMonthly.
  ///
  /// In en, this message translates to:
  /// **'For those who want to start without commitment.'**
  String get tariffDescMonthly;

  /// No description provided for @tariffDescSixMonth.
  ///
  /// In en, this message translates to:
  /// **'\$40.8 — 15% off\nBalance of benefit and flexibility'**
  String get tariffDescSixMonth;

  /// No description provided for @tariffDescYearly.
  ///
  /// In en, this message translates to:
  /// **'\$67.2 — 30% off\nBest value'**
  String get tariffDescYearly;

  /// No description provided for @subscriptionSnackbarPlanChanged.
  ///
  /// In en, this message translates to:
  /// **'Plan updated successfully'**
  String get subscriptionSnackbarPlanChanged;

  /// No description provided for @subscriptionSnackbarActivated.
  ///
  /// In en, this message translates to:
  /// **'Subscription activated'**
  String get subscriptionSnackbarActivated;

  /// No description provided for @subscriptionPaymentNotVerified.
  ///
  /// In en, this message translates to:
  /// **'Google Play charged, but the server has not confirmed the subscription yet (often a network issue). Confirmation retries when you are back online; you can refresh status later.'**
  String get subscriptionPaymentNotVerified;

  /// No description provided for @subscriptionPurchaseIncomplete.
  ///
  /// In en, this message translates to:
  /// **'Purchase was not completed. You can try again.'**
  String get subscriptionPurchaseIncomplete;

  /// No description provided for @subscriptionPurchaseError.
  ///
  /// In en, this message translates to:
  /// **'Payment error. Please try again.'**
  String get subscriptionPurchaseError;

  /// No description provided for @subscriptionGooglePlayUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Google Play purchases are not available on this device.'**
  String get subscriptionGooglePlayUnavailable;

  /// No description provided for @vpnDisconnectedAccessExpired.
  ///
  /// In en, this message translates to:
  /// **'VPN was disconnected because access expired.'**
  String get vpnDisconnectedAccessExpired;

  /// No description provided for @connectRetryGeneric.
  ///
  /// In en, this message translates to:
  /// **'Could not connect. Try again.'**
  String get connectRetryGeneric;

  /// No description provided for @subscriptionActivatedTitle.
  ///
  /// In en, this message translates to:
  /// **'Subscription activated!'**
  String get subscriptionActivatedTitle;

  /// No description provided for @subscriptionActivatedSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Access unlocked! One month of full speed and protection.'**
  String get subscriptionActivatedSubtitle;

  /// No description provided for @subscriptionReadyToConnect.
  ///
  /// In en, this message translates to:
  /// **'Ready to connect'**
  String get subscriptionReadyToConnect;

  /// No description provided for @paymentFailedTitle.
  ///
  /// In en, this message translates to:
  /// **'Payment failed'**
  String get paymentFailedTitle;

  /// No description provided for @paymentFailedBody.
  ///
  /// In en, this message translates to:
  /// **'We could not complete the charge.'**
  String get paymentFailedBody;

  /// No description provided for @paymentFailedRetry.
  ///
  /// In en, this message translates to:
  /// **'Try payment again'**
  String get paymentFailedRetry;

  /// No description provided for @paymentTariffTitleOneMonth.
  ///
  /// In en, this message translates to:
  /// **'1 month'**
  String get paymentTariffTitleOneMonth;

  /// No description provided for @paymentTariffTitleSixMonths.
  ///
  /// In en, this message translates to:
  /// **'6 months'**
  String get paymentTariffTitleSixMonths;

  /// No description provided for @paymentTariffTitleOneYear.
  ///
  /// In en, this message translates to:
  /// **'1 year'**
  String get paymentTariffTitleOneYear;

  /// No description provided for @paymentTariffPriceMonthly.
  ///
  /// In en, this message translates to:
  /// **'399 ₽/mo'**
  String get paymentTariffPriceMonthly;

  /// No description provided for @paymentTariffPriceSixMonth.
  ///
  /// In en, this message translates to:
  /// **'340 ₽/mo'**
  String get paymentTariffPriceSixMonth;

  /// No description provided for @paymentTariffPriceYearly.
  ///
  /// In en, this message translates to:
  /// **'279 ₽/mo'**
  String get paymentTariffPriceYearly;

  /// No description provided for @paymentTariffDescMonthly.
  ///
  /// In en, this message translates to:
  /// **'For those who want to start without commitment.'**
  String get paymentTariffDescMonthly;

  /// No description provided for @paymentTariffDescSixMonth.
  ///
  /// In en, this message translates to:
  /// **'2,035 ₽ — 15% off\nBalance of benefit and flexibility'**
  String get paymentTariffDescSixMonth;

  /// No description provided for @paymentTariffDescYearly.
  ///
  /// In en, this message translates to:
  /// **'3,352 ₽ — 30% off\nBest value'**
  String get paymentTariffDescYearly;

  /// No description provided for @termsOfUseLink.
  ///
  /// In en, this message translates to:
  /// **'Terms of use'**
  String get termsOfUseLink;

  /// No description provided for @authEmailTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your email'**
  String get authEmailTitle;

  /// No description provided for @authEmailSubtitle.
  ///
  /// In en, this message translates to:
  /// **'We\'ll send you a confirmation code'**
  String get authEmailSubtitle;

  /// No description provided for @authEmailFieldHint.
  ///
  /// In en, this message translates to:
  /// **'Email'**
  String get authEmailFieldHint;

  /// No description provided for @authEmailErrorEmpty.
  ///
  /// In en, this message translates to:
  /// **'Enter your email'**
  String get authEmailErrorEmpty;

  /// No description provided for @authEmailErrorInvalidFormat.
  ///
  /// In en, this message translates to:
  /// **'Enter a valid email address'**
  String get authEmailErrorInvalidFormat;

  /// No description provided for @authEmailSendCode.
  ///
  /// In en, this message translates to:
  /// **'Send code'**
  String get authEmailSendCode;

  /// No description provided for @authEmailSendFailedGeneric.
  ///
  /// In en, this message translates to:
  /// **'Could not send the code. Try again.'**
  String get authEmailSendFailedGeneric;

  /// No description provided for @authCodeTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter code'**
  String get authCodeTitle;

  /// No description provided for @authCodeSubtitle.
  ///
  /// In en, this message translates to:
  /// **'We sent a code to your email'**
  String get authCodeSubtitle;

  /// No description provided for @authCodePinLabel.
  ///
  /// In en, this message translates to:
  /// **'PIN code'**
  String get authCodePinLabel;

  /// No description provided for @authCodeErrorInvalidFallback.
  ///
  /// In en, this message translates to:
  /// **'Wrong code, try again'**
  String get authCodeErrorInvalidFallback;

  /// No description provided for @authCodeVerifying.
  ///
  /// In en, this message translates to:
  /// **'Verifying code...'**
  String get authCodeVerifying;

  /// No description provided for @authCodeEnterCode.
  ///
  /// In en, this message translates to:
  /// **'Enter the code'**
  String get authCodeEnterCode;

  /// No description provided for @authCodeResendWithCountdown.
  ///
  /// In en, this message translates to:
  /// **'Resend code ({seconds})'**
  String authCodeResendWithCountdown(int seconds);

  /// No description provided for @authCodeResend.
  ///
  /// In en, this message translates to:
  /// **'Resend code'**
  String get authCodeResend;

  /// No description provided for @authCodeNewSent.
  ///
  /// In en, this message translates to:
  /// **'A new code was sent to your email'**
  String get authCodeNewSent;

  /// No description provided for @authCodeResendWaitSeconds.
  ///
  /// In en, this message translates to:
  /// **'You can resend in {seconds} s'**
  String authCodeResendWaitSeconds(int seconds);
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ru'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ru':
      return AppLocalizationsRu();
  }

  throw FlutterError(
      'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
