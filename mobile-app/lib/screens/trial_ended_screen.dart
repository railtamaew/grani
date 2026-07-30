import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme.dart';
import '../config/app_config.dart';
import '../services/auth_service.dart';
import '../services/subscription_service.dart';
import '../config/subscription_products.dart';
import '../config/app_navigation.dart';
import 'bottom_sheet_profile.dart';
import '../widgets/snackbar_utils.dart';
import '../services/native_vpn_service.dart';
import '../services/vpn_service.dart';
import '../services/analytics_service.dart';
import '../l10n/l10n.dart';

/// Контекст открытия экрана тарифов.
enum SubscriptionScreenMode {
  /// Триал/подписка закончились — пользователь не может уйти без оплаты.
  expired,

  /// Активный триал — пользователь хочет оформить подписку заранее.
  upgrade,

  /// Активная подписка (Premium) — продление или смена тарифа.
  manage,
}

/// Интервал опроса статуса подписки (ручная подписка из админки)
const _subscriptionPollInterval = Duration(seconds: 25);

/// Экран тарифов (Figma 562:488).
/// Предлагает оформить подписку. Три тарифа (1, 6, 12 мес.) для интеграции с Google Play.
/// [mode] определяет заголовки, видимость таймера и возможность возврата назад.
class TrialEndedScreen extends StatefulWidget {
  final SubscriptionScreenMode mode;

  const TrialEndedScreen(
      {super.key, this.mode = SubscriptionScreenMode.expired});

  @override
  State<TrialEndedScreen> createState() => _TrialEndedScreenState();
}

class _TrialEndedScreenState extends State<TrialEndedScreen> with RouteAware {
  String? _purchasingProductId;

  String _storePrice(BuildContext context, String productId) {
    if (Platform.isWindows) {
      return context.l10n.subscriptionPayOnAndroidPrice;
    }
    final subscription = context.watch<SubscriptionService>();
    final price = subscription.priceFor(productId);
    if (price != null && price.trim().isNotEmpty) return price;
    return subscription.isLoading
        ? context.l10n.tariffPriceLoading
        : context.l10n.tariffPriceUnavailable;
  }

  Timer? _subscriptionPollTimer;
  Timer? _androidPaymentPollTimer;
  AuthService? _authServiceForListener;
  DateTime? _androidPaymentBaselineExpiresAt;
  bool _androidPaymentBaselineActive = false;
  bool _androidPaymentDialogOpen = false;
  bool _androidPaymentCheckInFlight = false;

  @override
  void initState() {
    super.initState();
    unawaited(AnalyticsService().logPaywallView());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route is ModalRoute<void>) {
        appRouteObserver.subscribe(this, route);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (widget.mode == SubscriptionScreenMode.expired) {
        final wasDisconnected = await _ensureVpnDisconnected();
        await _refreshAndNavigate();
        if (!mounted) return;
        if (wasDisconnected) {
          showInfoSnackBar(context, context.l10n.vpnDisconnectedAccessExpired);
        }
        final authService = Provider.of<AuthService>(context, listen: false);
        _authServiceForListener = authService;
        authService.addListener(_onAuthSubscriptionUpdate);
        _subscriptionPollTimer = Timer.periodic(
            _subscriptionPollInterval, (_) => _refreshAndNavigate());
      }
      if (!mounted) return;
      final sub = Provider.of<SubscriptionService>(context, listen: false);
      if (SubscriptionService.supported) sub.initialize();
    });
  }

  @override
  void didPopNext() {
    // Вернулись на этот экран (например, закрыли Billing UI) — сбрасываем loading.
    if (mounted && _purchasingProductId != null) {
      debugPrint('TrialEndedScreen: didPopNext, reset loading');
      setState(() => _purchasingProductId = null);
    }
  }

  void _onAuthSubscriptionUpdate() {
    if (!mounted) return;
    final auth = _authServiceForListener;
    if (auth != null &&
        (auth.hasActiveSubscription || ((auth.trialSecondsLeft ?? 0) > 0))) {
      _subscriptionPollTimer?.cancel();
      _subscriptionPollTimer = null;
      auth.removeListener(_onAuthSubscriptionUpdate);
      _authServiceForListener = null;
      if (!auth.hasActiveSubscription && (auth.trialSecondsLeft ?? 0) > 0) {
        showInfoSnackBar(context, context.l10n.trialAccessActivatedSnackbar);
      }
      Navigator.pushReplacementNamed(context, '/main');
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _subscriptionPollTimer?.cancel();
    _androidPaymentPollTimer?.cancel();
    _authServiceForListener?.removeListener(_onAuthSubscriptionUpdate);
    super.dispose();
  }

  String _androidPaymentUrl(String productId) {
    final base = Uri.parse(AppConfig.androidPaymentHandoffUrl);
    return base.replace(
      queryParameters: <String, String>{
        ...base.queryParameters,
        'plan': productId,
      },
    ).toString();
  }

  Future<void> _showPayOnAndroid(String productId) async {
    if (!Platform.isWindows || _androidPaymentDialogOpen) return;

    final auth = Provider.of<AuthService>(context, listen: false);
    _androidPaymentBaselineActive = auth.hasActiveSubscription;
    _androidPaymentBaselineExpiresAt = auth.subscriptionExpiresAt;
    _androidPaymentDialogOpen = true;
    final handoffUrl = _androidPaymentUrl(productId);

    _androidPaymentPollTimer?.cancel();
    _androidPaymentPollTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_checkAndroidPayment(showNotFound: false)),
    );

    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: true,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text(context.l10n.subscriptionPayOnAndroidTitle),
            content: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(context.l10n.subscriptionPayOnAndroidBody),
                    const SizedBox(height: 16),
                    Semantics(
                      label: context.l10n.subscriptionPayOnAndroidTitle,
                      image: true,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: QrImageView(
                            data: handoffUrl,
                            size: 220,
                            backgroundColor: Colors.white,
                            eyeStyle: const QrEyeStyle(
                              eyeShape: QrEyeShape.square,
                              color: Color(0xFF163041),
                            ),
                            dataModuleStyle: const QrDataModuleStyle(
                              dataModuleShape: QrDataModuleShape.square,
                              color: Color(0xFF163041),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.subscriptionPayOnAndroidSameAccount,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 8),
                    Text(context.l10n.subscriptionPayOnAndroidWaiting),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: handoffUrl));
                  if (!mounted) return;
                  showInfoSnackBar(
                    context,
                    context.l10n.subscriptionPayOnAndroidLinkCopied,
                  );
                },
                child: Text(context.l10n.subscriptionPayOnAndroidCopyLink),
              ),
              TextButton(
                onPressed: () async {
                  await launchUrl(
                    Uri.parse(AppConfig.sharePlayStoreUrl),
                    mode: LaunchMode.externalApplication,
                  );
                },
                child: Text(context.l10n.subscriptionPayOnAndroidOpenStore),
              ),
              FilledButton(
                onPressed: () => _checkAndroidPayment(showNotFound: true),
                child: Text(context.l10n.subscriptionPayOnAndroidCheck),
              ),
            ],
          );
        },
      );
    } finally {
      _androidPaymentDialogOpen = false;
      _androidPaymentPollTimer?.cancel();
      _androidPaymentPollTimer = null;
    }
  }

  Future<void> _checkAndroidPayment({required bool showNotFound}) async {
    if (!_androidPaymentDialogOpen ||
        _androidPaymentCheckInFlight ||
        !mounted) {
      return;
    }
    _androidPaymentCheckInFlight = true;
    final auth = Provider.of<AuthService>(context, listen: false);
    try {
      if (showNotFound) {
        showInfoSnackBar(
          context,
          context.l10n.subscriptionPayOnAndroidChecking,
        );
      }
      await auth.refreshUserStatus(force: true);
      if (!mounted || !_androidPaymentDialogOpen) return;

      final expiresAt = auth.subscriptionExpiresAt;
      final activated =
          !_androidPaymentBaselineActive && auth.hasActiveSubscription;
      final extended = _androidPaymentBaselineActive &&
          expiresAt != null &&
          (_androidPaymentBaselineExpiresAt == null ||
              expiresAt.isAfter(_androidPaymentBaselineExpiresAt!));

      if (activated || extended) {
        _androidPaymentDialogOpen = false;
        _androidPaymentPollTimer?.cancel();
        _androidPaymentPollTimer = null;
        Navigator.of(context, rootNavigator: true).pop();
        showInfoSnackBar(
          context,
          context.l10n.subscriptionSnackbarActivated,
        );
        Navigator.pushNamedAndRemoveUntil(context, '/main', (_) => false);
      } else if (showNotFound) {
        showInfoSnackBar(
          context,
          context.l10n.subscriptionPayOnAndroidNotFound,
        );
      }
    } catch (_) {
      if (showNotFound && mounted && _androidPaymentDialogOpen) {
        showErrorSnackBar(
          context,
          context.l10n.subscriptionPreflightUnavailable,
        );
      }
    } finally {
      _androidPaymentCheckInFlight = false;
    }
  }

  Future<void> _purchase(String productId) async {
    if (_purchasingProductId != null) return;
    setState(() => _purchasingProductId = productId);
    debugPrint(
        'TrialEndedScreen: _purchase start productId=$productId mode=${widget.mode}');
    final sub = Provider.of<SubscriptionService>(context, listen: false);
    final auth = Provider.of<AuthService>(context, listen: false);
    try {
      final applicationUserName =
          SubscriptionService.obfuscatedAccountIdFor(auth.user?.id);
      // Paid periods are repeatable consumable products. The backend binds
      // each verified token to the currently signed-in GRANI account and
      // stacks 30/180/365 days after the existing paid-until timestamp.
      // Therefore another subscription owned by the same Google Play account
      // must never block this purchase.
      final success = await sub.buyExtension(
        productId,
        applicationUserName: applicationUserName,
      );

      if (!mounted) return;
      if (success) {
        final verifyData = sub.lastPurchaseForVerification;
        bool verified = false;
        if (verifyData != null) {
          verified = await auth.verifyGooglePlayPurchase(
            purchaseToken: verifyData['purchase_token']!,
            productId: verifyData['product_id']!,
            orderId: verifyData['order_id'],
          );
          if (!verified && mounted) {
            debugPrint('TrialEndedScreen: верификация на бэкенде не прошла');
          }
        }
        await auth.refreshUserStatus(force: true);
        if (!mounted) return;
        if (verified) {
          unawaited(AnalyticsService().logPurchaseCompleted(productId));
          showInfoSnackBar(
            context,
            context.l10n.subscriptionSnackbarActivated,
          );
          Navigator.pushReplacementNamed(context, '/main');
        } else {
          showErrorSnackBar(
              context, context.l10n.subscriptionPaymentNotVerified);
        }
      } else {
        if (mounted) {
          showErrorSnackBar(
              context, context.l10n.subscriptionPurchaseIncomplete);
        }
      }
    } catch (e) {
      if (!mounted) return;
      if (mounted) {
        showErrorSnackBar(context, context.l10n.subscriptionPurchaseError);
      }
    } finally {
      if (mounted) {
        debugPrint('TrialEndedScreen: _purchase reset loading');
        setState(() => _purchasingProductId = null);
      }
    }
  }

  Future<void> _refreshAndNavigate() async {
    if (!mounted) return;
    final authService = Provider.of<AuthService>(context, listen: false);
    await authService.refreshUserStatus();
    if (!mounted) return;
    if (authService.hasActiveSubscription) {
      Navigator.pushReplacementNamed(context, '/main');
      return;
    }
    if ((authService.trialSecondsLeft ?? 0) > 0) {
      Navigator.pushReplacementNamed(context, '/main');
      return;
    }
  }

  Future<bool> _ensureVpnDisconnected() async {
    if (!mounted) return false;
    var requestedDisconnect = false;
    try {
      final vpnService = Provider.of<VpnService>(context, listen: false);
      if (vpnService.isVpnSessionPotentiallyActive) {
        requestedDisconnect = true;
        await vpnService
            .disconnect(source: 'trial_ended_paywall')
            .timeout(const Duration(seconds: 4));
      }
    } catch (_) {
      // Best-effort disconnect: paywall должен открыться даже если отключение не удалось мгновенно.
    }
    try {
      final amneziaWasConnected = await NativeVpnService.getAmneziaWgStatus()
              .timeout(const Duration(seconds: 2)) ==
          true;
      if (amneziaWasConnected) requestedDisconnect = true;
      await NativeVpnService.disconnectAmneziaWg(
        reason: 'access_expired',
        source: 'trial_ended_paywall',
      ).timeout(const Duration(seconds: 4));
    } catch (_) {
      // Best-effort direct Simple/GRANIwg disconnect.
    }
    try {
      final nativeWasConnected =
          await NativeVpnService.getNativeConnectionStatus()
                  .timeout(const Duration(seconds: 2)) ==
              true;
      if (nativeWasConnected) requestedDisconnect = true;
      await NativeVpnService.disconnect(
        reason: 'access_expired',
        source: 'trial_ended_paywall',
      ).timeout(const Duration(seconds: 4));
    } catch (_) {
      // Best-effort legacy/native disconnect.
    }
    return requestedDisconnect;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    const designWidth = 412.0;
    const designHeight = 917.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / designHeight;
    final topBarHeight = (12 + 39 + 12) * scaleY;
    final safeBottom = MediaQuery.of(context).padding.bottom;
    final canPop = widget.mode != SubscriptionScreenMode.expired;

    String title;
    String subtitle;
    bool showTimer;
    final l10n = context.l10n;
    switch (widget.mode) {
      case SubscriptionScreenMode.expired:
        title = l10n.trialExpiredTitle;
        subtitle = l10n.trialExpiredSubtitle;
        showTimer = true;
      case SubscriptionScreenMode.upgrade:
        title = l10n.trialUpgradeTitle;
        subtitle = l10n.trialUpgradeSubtitle;
        showTimer = false;
      case SubscriptionScreenMode.manage:
        title = l10n.trialManageTitle;
        subtitle = l10n.trialManageSubtitle;
        showTimer = false;
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Color(0xFFFFFFFF),
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFFF7F9FA),
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: PopScope(
        canPop: canPop,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Container(
            decoration: const BoxDecoration(
              gradient: GraniTheme.startScreenBackgroundGradient,
            ),
            child: SafeArea(
              bottom: false,
              child: Stack(
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      height:
                          safeBottom + GraniTheme.navigationBarHeight * scaleY,
                      color: const Color(0xFFF7F9FA),
                    ),
                  ),
                  // Верхняя панель по макету 562:488: меню (слева), лого (центр), поделиться (справа)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(
                          20 * scaleX, 12 * scaleY, 20 * scaleX, 12 * scaleY),
                      child: Row(
                        children: [
                          if (canPop)
                            GestureDetector(
                              onTap: () => Navigator.of(context).pop(),
                              child: SizedBox(
                                width: 32 * scaleX,
                                height: 29 * scaleY,
                                child: Icon(Icons.arrow_back_ios_new,
                                    size: 22 * scaleX,
                                    color: GraniTheme.primaryText),
                              ),
                            )
                          else
                            GestureDetector(
                              onTap: () => showProfileDrawer(context),
                              child: SizedBox(
                                width: 32 * scaleX,
                                height: 33 * scaleY,
                                child: SvgPicture.asset(
                                  'assets/images/figma/profile/menu_new.svg',
                                  fit: BoxFit.contain,
                                ),
                              ),
                            ),
                          const Spacer(),
                          SizedBox(
                            width: 154 * scaleX,
                            height: 39 * scaleY,
                            child: Image.asset(
                              'assets/images/figma/logo_grani_new.png',
                              fit: BoxFit.contain,
                              errorBuilder: (context, error, stackTrace) {
                                return const Icon(Icons.vpn_key,
                                    size: 40, color: GraniTheme.primaryText);
                              },
                            ),
                          ),
                          const Spacer(),
                          GestureDetector(
                            onTap: () async {
                              try {
                                await Share.share(
                                  l10n.profileSharePlayStoreMessage(
                                      AppConfig.sharePlayStoreUrl),
                                );
                              } catch (_) {
                                if (context.mounted) {
                                  showErrorSnackBar(
                                      context, l10n.profileShareFailed);
                                }
                              }
                            },
                            child: SizedBox(
                              width: 32 * scaleX,
                              height: 33 * scaleY,
                              child: Image.asset(
                                'assets/images/figma/share_icon.png',
                                fit: BoxFit.contain,
                                errorBuilder: (context, error, stackTrace) {
                                  return Icon(Icons.share,
                                      size: 24 * scaleX,
                                      color: GraniTheme.primaryText);
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  // Единый скролл: заголовок + таймер + карточки тарифов
                  Positioned(
                    top: topBarHeight,
                    left: 0,
                    right: 0,
                    bottom:
                        GraniTheme.navigationBarHeight * scaleY + safeBottom,
                    child: SingleChildScrollView(
                      padding: EdgeInsets.fromLTRB(
                        32 * scaleX,
                        24 * scaleY,
                        32 * scaleX,
                        24 * scaleY,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(
                            child: Column(
                              children: [
                                Text(
                                  title,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontFamily: 'Montserrat',
                                    fontWeight: FontWeight.w400,
                                    fontSize: 24 * scaleX,
                                    height: 21.6 / 24,
                                    letterSpacing: -0.96 * scaleX,
                                    color: const Color(0xFF192F3F),
                                  ),
                                ),
                                SizedBox(height: 8 * scaleY),
                                Text(
                                  subtitle,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontFamily: 'Montserrat',
                                    fontWeight: FontWeight.w300,
                                    fontSize: 16 * scaleX,
                                    height: 15.52 / 16,
                                    letterSpacing: 0.96 * scaleX,
                                    color: const Color(0xFF192F3F),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (showTimer) ...[
                            SizedBox(height: 16 * scaleY),
                            Center(
                              child: Text(
                                l10n.trialTimeLeft,
                                style: TextStyle(
                                  fontFamily: 'Montserrat',
                                  fontWeight: GraniTheme.trialTimerFontWeight,
                                  fontSize:
                                      GraniTheme.trialTimerFontSize * scaleX,
                                  height: 18 / GraniTheme.trialTimerFontSize,
                                  letterSpacing: -0.8 * scaleX,
                                  color: GraniTheme.trialEndedTimer,
                                ),
                              ),
                            ),
                          ],
                          SizedBox(height: 24 * scaleY),
                          _buildTariffCard(
                            '1',
                            l10n.tariffBadgeMonthOne,
                            _storePrice(
                                context, SubscriptionProducts.extension30Days),
                            l10n.tariffDescMonthly,
                            scaleX,
                            scaleY,
                            SubscriptionProducts.extension30Days,
                          ),
                          SizedBox(height: 10 * scaleY),
                          _buildTariffCard(
                            '6',
                            l10n.tariffBadgeMonthsMany,
                            _storePrice(
                                context, SubscriptionProducts.extension180Days),
                            l10n.tariffDescSixMonth,
                            scaleX,
                            scaleY,
                            SubscriptionProducts.extension180Days,
                          ),
                          SizedBox(height: 10 * scaleY),
                          _buildTariffCard(
                            '12',
                            l10n.tariffBadgeMonthsMany,
                            _storePrice(
                                context, SubscriptionProducts.extension365Days),
                            l10n.tariffDescYearly,
                            scaleX,
                            scaleY,
                            SubscriptionProducts.extension365Days,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTariffCard(
    String number,
    String period,
    String price,
    String description,
    double scaleX,
    double scaleY,
    String productId,
  ) {
    final isPurchasing = _purchasingProductId == productId;
    return Stack(
      children: [
        GestureDetector(
          onTap: isPurchasing
              ? null
              : () {
                  if (SubscriptionService.supported) {
                    _purchase(productId);
                  } else if (Platform.isWindows) {
                    _showPayOnAndroid(productId);
                  } else {
                    showErrorSnackBar(context,
                        context.l10n.subscriptionGooglePlayUnavailable);
                  }
                },
          child: Container(
            width: 348 * scaleX,
            padding: EdgeInsets.all(12 * scaleX),
            decoration: BoxDecoration(
              gradient: GraniTheme.surfaceControlGradient,
              borderRadius: BorderRadius.circular(25 * scaleX),
              border: Border.all(
                color: GraniTheme.surfaceControlBorder.withOpacity(0.86),
              ),
              boxShadow: GraniTheme.surfaceControlShadowStrong
                  .map((shadow) => BoxShadow(
                        color: shadow.color,
                        offset: Offset(shadow.offset.dx * scaleX,
                            shadow.offset.dy * scaleY),
                        blurRadius: shadow.blurRadius * scaleX,
                        spreadRadius: shadow.spreadRadius * scaleX,
                      ))
                  .toList(),
            ),
            child: Row(
              children: [
                Container(
                  width: 64 * scaleX,
                  padding: EdgeInsets.symmetric(vertical: 18 * scaleY),
                  decoration: BoxDecoration(
                    gradient: GraniTheme.surfaceControlGradient,
                    borderRadius: BorderRadius.circular(20 * scaleX),
                    border: Border.all(
                      color: GraniTheme.surfaceControlBorder.withOpacity(0.74),
                    ),
                    boxShadow: GraniTheme.surfaceControlShadow
                        .map((shadow) => BoxShadow(
                              color: shadow.color,
                              offset: Offset(shadow.offset.dx * scaleX,
                                  shadow.offset.dy * scaleY),
                              blurRadius: shadow.blurRadius * scaleX,
                              spreadRadius: shadow.spreadRadius * scaleX,
                            ))
                        .toList(),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        number,
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w600,
                          fontSize: 40 * scaleX,
                          height: 1.1,
                          color: GraniTheme.trialEndedTariffBadgeText,
                        ),
                      ),
                      Text(
                        period,
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w600,
                          fontSize: 14 * scaleX,
                          height: 1.1,
                          color: GraniTheme.trialEndedTariffBadgeText,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(width: 12 * scaleX),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        price,
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w400,
                          fontSize: 24 * scaleX,
                          height: 1.1,
                          letterSpacing: 1.44 * scaleX,
                          color: GraniTheme.trialEndedTariffPrice,
                        ),
                      ),
                      SizedBox(height: 5 * scaleY),
                      Text(
                        description,
                        style: TextStyle(
                          fontFamily: 'Montserrat',
                          fontWeight: FontWeight.w300,
                          fontSize: 12 * scaleX,
                          height: 0.84,
                          letterSpacing: 0.72 * scaleX,
                          color: GraniTheme.trialEndedTariffDescription,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (isPurchasing)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(25 * scaleX),
              ),
              child: Center(
                child: SizedBox(
                  width: 32 * scaleX,
                  height: 32 * scaleY,
                  child: const CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
