import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import '../theme.dart';
import '../widgets/privacy_policy_bottom_sheet.dart';
import '../widgets/auth_logo.dart';
import '../widgets/auth_text_block.dart';
import '../services/auth_service.dart';
import '../services/vpn_service.dart';
import '../services/push_notification_service.dart';
import '../services/analytics_service.dart';
import '../config/app_config.dart';
import '../core/session/device_limit_flow.dart'
    show registerDeviceUntilOkWithModal;
import '../l10n/l10n.dart';
import '../widgets/snackbar_utils.dart';

void _logStartAuthTiming(String event, Map<String, dynamic> data) {
  final parts = data.entries.map((e) => '${e.key}=${e.value}').join(', ');
  debugPrint('[auth-timing] start_screen_$event $parts');
}

class StartScreen extends StatefulWidget {
  const StartScreen({super.key});

  @override
  State<StartScreen> createState() => _StartScreenState();
}

class _StartScreenState extends State<StartScreen>
    with TickerProviderStateMixin {
  late AnimationController _fadeController;
  late AnimationController _scaleController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  bool _isGoogleButtonPressed = false;
  bool _isEmailButtonPressed = false;

  @override
  void initState() {
    super.initState();

    // Fade-in анимация при открытии экрана (0.4s)
    _fadeController = AnimationController(
      duration: const Duration(milliseconds: 400),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _fadeController, curve: Curves.easeIn),
    );
    // Запускаем анимацию сразу, не ждем
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _fadeController.forward();
      }
    });

    // Scale анимация для кнопок
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeInOut),
    );

    // Проверка авторизации больше не нужна здесь - она выполняется в main.dart
    // Оставляем как fallback на случай, если пользователь каким-то образом попал на StartScreen
    // будучи авторизованным (например, через прямой переход)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAuthAndRedirectFallback();
    });
  }

  /// Fallback проверка авторизации (на случай прямого перехода на StartScreen)
  Future<void> _checkAuthAndRedirectFallback() async {
    if (!mounted) return;

    try {
      final authService = Provider.of<AuthService>(context, listen: false);

      // Ждем загрузки токена из хранилища
      await authService.waitForTokenLoad();

      if (!mounted) return;

      // Проверяем, авторизован ли пользователь
      if (authService.isAuthenticated && authService.token != null) {
        debugPrint(
            'StartScreen: Fallback - пользователь авторизован, определяем правильный экран');

        // Определяем правильный экран на основе статуса пользователя
        String targetRoute = _determineTargetRoute(authService);
        debugPrint('StartScreen: Fallback - переход на: $targetRoute');

        if (mounted) {
          final currentRoute = ModalRoute.of(context)?.settings.name;
          if (currentRoute == targetRoute) {
            debugPrint(
                'StartScreen: Fallback - уже на $targetRoute, навигация пропущена');
            return;
          }
          Navigator.pushNamedAndRemoveUntil(context, targetRoute, (_) => false);
        }
      }
    } catch (e) {
      debugPrint('StartScreen: Ошибка при fallback проверке авторизации: $e');
      // Продолжаем показ стартового экрана при ошибке
    }
  }

  /// Определяет целевой маршрут на основе статуса пользователя
  /// Единый маршрут /main — MainContentScreen сам переключит trial/home по hasActiveSubscription
  String _determineTargetRoute(AuthService authService) {
    if (authService.hasActiveSubscription) {
      return '/main';
    }
    final trialSecondsLeft = authService.trialSecondsLeft ?? 0;
    if (trialSecondsLeft > 0) {
      return '/main';
    }
    return '/trial-ended';
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _scaleController.dispose();
    super.dispose();
  }

  double _measureTextHeight({
    required String text,
    required TextStyle style,
    required double maxWidth,
    int? maxLines,
  }) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
    )..layout(maxWidth: maxWidth);
    return painter.size.height;
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;
    final safeAreaTop = MediaQuery.of(context).padding.top;
    final safeAreaHorizontalPaddingLeft = MediaQuery.of(context).padding.left;
    final safeAreaHorizontalPaddingRight = MediaQuery.of(context).padding.right;

    // Размеры из макета Figma (базовый экран 412x917, node 516:295)
    const designWidth = 412.0;
    const designHeight = 917.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / designHeight;
    final typeScale = math.min(scaleX, scaleY);
    // Поднимаем текстовый блок чуть выше для более воздушной композиции.
    final logoToTitleGap = GraniTheme.startScreenLogoToTitleGap * 0.72;

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Container(
          width: double.infinity,
          height: double.infinity,
          decoration: const BoxDecoration(
            gradient: GraniTheme
                .startScreenBackgroundGradient, // Figma #StartScreen Fill: 0% #FFFFFF, 100% #F7F9FA
          ),
          child: SafeArea(
            bottom: false,
            child: SizedBox.expand(
              child: Stack(
                children: [
                  // Navigation bars (из Figma: x: 0, y: 893, width: 412, height: 24)
                  // layout_7XIZ5T - системный компонент, не верстаем
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: GraniTheme.navigationBarHeight,
                      color: Colors.transparent,
                    ),
                  ),

                  // Logo: размер и позиция из Figma (figma_fetch_layout.py: 37×48, y 74.4)
                  AuthLogo(
                    logoWidth: GraniTheme.logoWidth * scaleX,
                    logoHeight: GraniTheme.logoHeight * scaleY,
                    topOffset: safeAreaTop +
                        GraniTheme.startScreenLogoTopOffset +
                        14 * scaleY,
                  ),

                  // Text Block (отступ лого → заголовок по макету start_screen)
                  Builder(
                    builder: (context) {
                      final l10n = context.l10n;
                      final textBlockTop = safeAreaTop +
                          GraniTheme.startScreenLogoTopOffset +
                          GraniTheme.logoHeight * scaleY +
                          logoToTitleGap * scaleY;
                      // SafeArea снаружи уже отрезает left/right инсет, поэтому leftOffset
                      // считаем в координатах "внутри" SafeArea (без добавления safeAreaHorizontalPaddingLeft).
                      final safeWidth = screenWidth -
                          safeAreaHorizontalPaddingLeft -
                          safeAreaHorizontalPaddingRight;
                      final textBlockWidth =
                          GraniTheme.inputFieldWidth * scaleX;
                      final titleFontSize =
                          GraniTheme.startScreenTitleFontSize * typeScale;
                      final subtitleFontSize =
                          GraniTheme.startScreenSubtitleFontSize * typeScale;
                      final leftOffset = ((safeWidth - textBlockWidth) / 2)
                          .clamp(0.0, double.infinity);
                      return AuthTextBlock(
                        title: l10n.startHeadline,
                        subtitle: l10n.startSubtitle,
                        topOffset: textBlockTop,
                        leftOffset: leftOffset,
                        titleFontSize: titleFontSize,
                        titleLetterSpacing: 0,
                        subtitleFontSize: subtitleFontSize,
                        subtitleLetterSpacing: 0,
                        titleSubtitleGap:
                            GraniTheme.startScreenTitleSubtitleGap * scaleY,
                      );
                    },
                  ),

                  // Блок кнопок и ссылок
                  Builder(
                    builder: (context) {
                      final l10n = context.l10n;
                      final textBlockTop = safeAreaTop +
                          GraniTheme.startScreenLogoTopOffset +
                          GraniTheme.logoHeight * scaleY +
                          logoToTitleGap * scaleY;
                      final horizontalPadding =
                          GraniTheme.startScreenHorizontalPadding * scaleX;
                      final textBlockWidth =
                          GraniTheme.inputFieldWidth * scaleX;
                      final titleStyle = GraniTheme.headingLarge.copyWith(
                        fontSize:
                            GraniTheme.startScreenTitleFontSize * typeScale,
                        letterSpacing: 0,
                      );
                      final subtitleStyle = GraniTheme.bodyLarge.copyWith(
                        fontSize:
                            GraniTheme.startScreenSubtitleFontSize * typeScale,
                        letterSpacing: 0,
                      );
                      final titleHeight = _measureTextHeight(
                        text: l10n.startHeadline,
                        style: titleStyle,
                        maxWidth: textBlockWidth,
                      );
                      final subtitleHeight = _measureTextHeight(
                        text: l10n.startSubtitle,
                        style: subtitleStyle,
                        maxWidth: textBlockWidth,
                      );
                      final textBlockHeight = titleHeight +
                          (GraniTheme.startScreenTitleSubtitleGap * scaleY) +
                          subtitleHeight;
                      // Увеличиваем отлип от Subtitle до кнопок Google/Email
                      // (раньше использовался множитель 0.82 — делал блок слишком близко).
                      final buttonsTop = textBlockTop +
                          textBlockHeight +
                          (GraniTheme.startScreenGapSubtitleToButtons *
                              1.28 *
                              scaleY);
                      final emailPrimary = AppConfig.isEmailPrimaryAuth;
                      final googleSignInSupported =
                          defaultTargetPlatform != TargetPlatform.windows;
                      return Positioned(
                        top: buttonsTop,
                        left: horizontalPadding,
                        right: horizontalPadding,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (googleSignInSupported) ...[
                              Builder(
                                builder: (context) {
                                  final authService = Provider.of<AuthService>(
                                      context,
                                      listen: false);
                                  return _buildStartButton(
                                    context: context,
                                    text: l10n.startContinueGoogle,
                                    onPressed: authService.isLoading
                                        ? null
                                        : () => _handleGoogleSignIn(context),
                                    icon: _buildGoogleIcon(scaleX, scaleY),
                                    scaleX: scaleX,
                                    scaleY: scaleY,
                                    isPressed: _isGoogleButtonPressed,
                                    isLoading: authService.isLoading,
                                    useStartScreenStyle: !emailPrimary,
                                  );
                                },
                              ),
                              SizedBox(
                                  height:
                                      GraniTheme.startScreenGapBetweenButtons *
                                          0.85 *
                                          scaleY),
                            ],
                            _buildStartButton(
                              context: context,
                              text: l10n.startContinueEmail,
                              onPressed: () => _handleEmailSignIn(context),
                              icon: _buildEmailIcon(scaleX, scaleY),
                              scaleX: scaleX,
                              scaleY: scaleY,
                              isPressed: _isEmailButtonPressed,
                              useStartScreenStyle: emailPrimary,
                            ),
                            SizedBox(
                                height: GraniTheme
                                        .startScreenGapButtonsToAccountLink *
                                    0.85 *
                                    scaleY),
                            RichText(
                              textAlign: TextAlign.center,
                              text: TextSpan(
                                style: GraniTheme.bodySmall.copyWith(
                                  color: GraniTheme.primaryText,
                                  fontSize: 14 * scaleX,
                                ),
                                children: [
                                  TextSpan(text: l10n.startAlreadyHaveAccount),
                                  TextSpan(
                                    text: l10n.startSignIn,
                                    style: GraniTheme.bodySmall.copyWith(
                                      color: GraniTheme.primaryText,
                                      fontSize: 14 * scaleX,
                                      decoration: TextDecoration.underline,
                                      decorationColor: GraniTheme.primaryText,
                                    ),
                                    recognizer: TapGestureRecognizer()
                                      ..onTap = () {
                                        Navigator.pushNamed(
                                            context, '/auth-email');
                                      },
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(
                                height: GraniTheme
                                        .startScreenGapAccountLinkToPrivacy *
                                    0.72 *
                                    scaleY),
                            GestureDetector(
                              onTap: () =>
                                  PrivacyPolicyBottomSheet.show(context),
                              child: Text(
                                l10n.startPrivacyMore,
                                style: GraniTheme.privacyLinkText,
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGoogleIcon(double scaleX, double scaleY) {
    const iconSize = GraniTheme.buttonIconSize;
    return SizedBox(
      width: iconSize * scaleX,
      height: iconSize * scaleY,
      child: Image.asset(
        'assets/images/figma/google_logo.png',
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            width: iconSize * scaleX,
            height: iconSize * scaleY,
            decoration: BoxDecoration(
              color: Colors.grey[300],
              borderRadius: BorderRadius.circular(4),
            ),
            child: Icon(Icons.g_mobiledata, size: iconSize * scaleX),
          );
        },
      ),
    );
  }

  Widget _buildEmailIcon(double scaleX, double scaleY) {
    const iconSize = GraniTheme.buttonIconSize;
    return SizedBox(
      width: iconSize * scaleX,
      height: iconSize * scaleY,
      child: Image.asset(
        'assets/images/figma/email_icon.png',
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return Icon(
            Icons.email_outlined,
            size: iconSize * scaleX,
            color: GraniTheme.secondaryText,
          );
        },
      ),
    );
  }

  Future<void> _handleGoogleSignIn(BuildContext context) async {
    final screenTotalSw = Stopwatch()..start();
    setState(() {
      _isGoogleButtonPressed = true;
    });

    // Анимация нажатия
    _scaleController.forward().then((_) {
      _scaleController.reverse();
    });

    final authService = Provider.of<AuthService>(context, listen: false);

    try {
      debugPrint('=== НАЧАЛО GOOGLE OAUTH ===');
      debugPrint('StartScreen: Начало авторизации через Google...');
      if (kDebugMode) {
        debugPrint(
            'StartScreen: Web Client ID: ${AppConfig.googleOAuthWebClientId}');
        debugPrint('StartScreen: API Base URL: ${AppConfig.apiBaseUrl}');
      }

      final authServiceSw = Stopwatch()..start();
      final result = await authService.signInWithGoogle();
      authServiceSw.stop();
      _logStartAuthTiming('auth_service_done', {
        'elapsed_ms': authServiceSw.elapsedMilliseconds,
        'total_so_far_ms': screenTotalSw.elapsedMilliseconds,
        'status': result.status.name,
      });

      debugPrint('=== РЕЗУЛЬТАТ GOOGLE OAUTH ===');
      debugPrint('StartScreen: Результат Google OAuth получен');
      debugPrint('StartScreen: status=${result.status}');
      debugPrint('StartScreen: isSuccess=${result.isSuccess}');
      debugPrint('StartScreen: isError=${result.isError}');
      debugPrint('StartScreen: isCanceled=${result.isCanceled}');
      debugPrint('StartScreen: errorMessage=${result.errorMessage}');
      debugPrint('StartScreen: user=${result.user?.email}');
      debugPrint(
          'StartScreen: token=${result.token != null ? "получен" : "не получен"}');

      if (!context.mounted) {
        debugPrint('StartScreen: Context не mounted, выход');
        return;
      }

      if (result.isSuccess) {
        final authService = Provider.of<AuthService>(context, listen: false);
        final targetRoute = _determineTargetRoute(authService);
        _logStartAuthTiming('route_decision', {
          'total_so_far_ms': screenTotalSw.elapsedMilliseconds,
          'target_route': targetRoute,
        });
        // ASCII: logcat on some devices mangles Cyrillic in debugPrint.
        debugPrint(
          'StartScreen: Google OAuth OK user=${result.user?.id} '
          'build=${AppConfig.buildNumber} targetRoute=$targetRoute (nav after post-frame)',
        );

        try {
          AnalyticsService().logLogin('google');
          AnalyticsService().setUserId(result.user?.id);
        } catch (e) {
          debugPrint('Analytics error (non-critical): $e');
        }

        final deviceRegisterSw = Stopwatch()..start();
        final navigated = await _registerDeviceOrShowLimit(context);
        deviceRegisterSw.stop();
        _logStartAuthTiming('device_register_or_limit_done', {
          'elapsed_ms': deviceRegisterSw.elapsedMilliseconds,
          'total_so_far_ms': screenTotalSw.elapsedMilliseconds,
          'navigated': navigated,
        });
        if (navigated || !context.mounted) return;

        final vpnService = Provider.of<VpnService>(context, listen: false);
        unawaited(() async {
          final sw = Stopwatch()..start();
          try {
            await vpnService.refreshControlPlaneSnapshot(authService,
                force: true);
            sw.stop();
            _logStartAuthTiming('control_plane_snapshot_bg_done', {
              'elapsed_ms': sw.elapsedMilliseconds,
              'status': 'success',
            });
          } catch (e) {
            sw.stop();
            _logStartAuthTiming('control_plane_snapshot_bg_done', {
              'elapsed_ms': sw.elapsedMilliseconds,
              'status': 'error',
              'error': e.toString(),
            });
            debugPrint(
                'StartScreen: control-plane snapshot after Google failed: $e');
          }
        }());
        unawaited(() async {
          final sw = Stopwatch()..start();
          try {
            await PushNotificationService().syncPushTokenWithCurrentSession();
            sw.stop();
            _logStartAuthTiming('push_token_bg_done', {
              'elapsed_ms': sw.elapsedMilliseconds,
              'status': 'success',
            });
          } catch (e) {
            sw.stop();
            _logStartAuthTiming('push_token_bg_done', {
              'elapsed_ms': sw.elapsedMilliseconds,
              'status': 'error',
              'error': e.toString(),
            });
          }
        }());

        final route = targetRoute;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          Navigator.pushNamedAndRemoveUntil(context, route, (_) => false);
          screenTotalSw.stop();
          _logStartAuthTiming('navigation_done', {
            'total_ms': screenTotalSw.elapsedMilliseconds,
            'route': route,
          });
          debugPrint(
              'StartScreen: Navigator.pushNamedAndRemoveUntil done -> $route');
        });
      } else if (result.isCanceled) {
        // Статус canceled - пользователь нажал "Отмена"
        debugPrint(
            'StartScreen: ⚠️ Пользователь отменил авторизацию через Google');
        // Окно Google сворачивается автоматически
        // Не показываем уведомления - их нет в макете Figma
        // Просто возвращаемся на экран без действий
      } else if (result.isError) {
        // Статус error - внутренняя ошибка
        debugPrint(
            'StartScreen: ❌ Ошибка Google OAuth: ${result.errorMessage}');
        debugPrint('StartScreen: Проверьте:');
        debugPrint('  1. SHA-1 fingerprint в Google Cloud Console');
        debugPrint('  2. Client ID соответствует package name');
        debugPrint('  3. OAuth client настроен для Android');
        debugPrint('  4. Проверьте логи бэкенда на наличие ошибок');
        final msg = result.errorMessage ?? 'Ошибка входа через Google';
        if (context.mounted) {
          showErrorSnackBar(
            context,
            msg.length > 120 ? '${msg.substring(0, 120)}...' : msg,
          );
        }
      } else {
        debugPrint(
            'StartScreen: ⚠️ Неизвестный статус результата: ${result.status}');
      }

      debugPrint('=== КОНЕЦ GOOGLE OAUTH ===');
    } catch (e, stackTrace) {
      // Неожиданная ошибка
      debugPrint('Неожиданная ошибка Google OAuth: $e');
      debugPrint('Stack trace: $stackTrace');
      // Не показываем технические ошибки пользователю
      // Ошибки Google OAuth - это проблема конфигурации, не пользователя
    } finally {
      if (mounted) {
        setState(() {
          _isGoogleButtonPressed = false;
        });
      }
    }
  }

  /// Регистрирует устройство до входа в приложение; при лимите — модалка (см. [registerDeviceUntilOkWithModal]).
  /// Возвращает `true`, если уже выполнен переход (logout).
  Future<bool> _registerDeviceOrShowLimit(BuildContext context) async {
    final vpnService = Provider.of<VpnService>(context, listen: false);
    final authService = Provider.of<AuthService>(context, listen: false);
    final token = authService.token;
    if (token == null || token.isEmpty) return false;
    final ok = await registerDeviceUntilOkWithModal(
      context: context,
      authService: authService,
      vpnService: vpnService,
      token: token,
    );
    if (!ok) {
      if (context.mounted && authService.isAuthenticated) {
        showErrorSnackBar(context, context.l10n.errorNetworkGeneric);
      }
      return true;
    }
    return false;
  }

  void _handleEmailSignIn(BuildContext context) {
    debugPrint('StartScreen: нажата кнопка "Вход с email"');
    setState(() {
      _isEmailButtonPressed = true;
    });

    // Анимация нажатия
    _scaleController.forward().then((_) {
      _scaleController.reverse();
      if (mounted) {
        setState(() {
          _isEmailButtonPressed = false;
        });
        // Переход на экран ввода email
        debugPrint('StartScreen: переход на /auth-email');
        try {
          Navigator.pushNamed(context, '/auth-email').then((_) {
            debugPrint('StartScreen: возврат с /auth-email');
          }).catchError((error) {
            debugPrint('StartScreen: ошибка навигации на /auth-email: $error');
          });
        } catch (e, stackTrace) {
          debugPrint('StartScreen: исключение при навигации: $e');
          debugPrint('Stack trace: $stackTrace');
        }
      }
    });
  }

  Widget _buildStartButton({
    required BuildContext context,
    required String text,
    required VoidCallback? onPressed,
    Widget? icon,
    required double scaleX,
    required double scaleY,
    bool isPressed = false,
    bool isLoading = false,
    bool useStartScreenStyle = false,
  }) {
    final typeScale = math.min(scaleX, scaleY);
    final radius = useStartScreenStyle
        ? GraniTheme.radiusButtonStartScreen * scaleX
        : GraniTheme.radiusButton * scaleX;
    final textStyle = useStartScreenStyle
        ? GraniTheme.buttonTextStartScreen.copyWith(
            fontSize: GraniTheme.buttonTextStartScreen.fontSize! * typeScale,
            letterSpacing: 0.06 *
                (GraniTheme.buttonTextStartScreen.fontSize ?? 22) *
                typeScale,
          )
        : GraniTheme.buttonTextSecondary.copyWith(
            fontSize: 20 * typeScale,
            letterSpacing: 0.06 * 20 * typeScale,
          );
    final loadingIconSize = GraniTheme.buttonIconSize;
    return AnimatedBuilder(
      animation: _scaleAnimation,
      builder: (context, child) {
        final scale = isPressed ? _scaleAnimation.value : 1.0;
        return Transform.scale(
          scale: scale,
          child: Container(
            width: GraniTheme.inputFieldWidth * scaleX,
            height: GraniTheme.buttonHeight * scaleY,
            decoration: GraniTheme.graniSurfaceDecoration(
              radius: radius,
              borderOpacity: useStartScreenStyle ? 0.92 : 0.82,
              shadows: GraniTheme.surfaceControlShadowStrong,
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(radius),
                onTap: onPressed,
                child: Opacity(
                  opacity: isLoading || onPressed == null ? 0.7 : 1.0,
                  child: Container(
                    padding: EdgeInsets.only(
                      left: GraniTheme.buttonPaddingLeft * scaleX,
                      right: GraniTheme.buttonPaddingRight * scaleX,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isLoading)
                          SizedBox(
                            width: loadingIconSize * scaleX,
                            height: loadingIconSize * scaleY,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                GraniTheme.secondaryText,
                              ),
                            ),
                          )
                        else if (icon != null) ...[
                          icon,
                          SizedBox(width: GraniTheme.buttonIconGap * scaleX),
                        ],
                        if (!isLoading)
                          Flexible(
                            child: Text(
                              text,
                              overflow: TextOverflow.ellipsis,
                              style: textStyle,
                              textAlign: TextAlign.center,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
