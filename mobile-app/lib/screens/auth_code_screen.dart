import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/l10n.dart';
import '../l10n/localized_messages.dart';
import '../theme.dart';
import '../widgets/pin_code_input.dart';
import '../widgets/error_message.dart';
import '../services/auth_service.dart';
import '../services/vpn_service.dart';
import '../services/push_notification_service.dart';
import '../services/analytics_service.dart';
import '../widgets/ui_density.dart';
import '../core/errors/error_handler.dart';
import '../core/session/device_limit_flow.dart' show registerDeviceAfterLoginBackground;
import '../widgets/adaptive_text.dart';
import '../widgets/snackbar_utils.dart';

class AuthCodeScreenArguments {
  final String email;
  final int? initialSeconds;
  final int? dailyRemaining;
  final bool isError;

  const AuthCodeScreenArguments({
    required this.email,
    this.initialSeconds,
    this.dailyRemaining,
    this.isError = false,
  });
}

class AuthCodeScreen extends StatefulWidget {
  final String email;
  final bool isError;
  final int? initialSeconds;
  final int? dailyRemaining;

  const AuthCodeScreen({
    super.key,
    required this.email,
    this.isError = false,
    this.initialSeconds,
    this.dailyRemaining,
  });

  @override
  State<AuthCodeScreen> createState() => _AuthCodeScreenState();
}

class _AuthCodeScreenState extends State<AuthCodeScreen> with WidgetsBindingObserver {
  final GlobalKey<PinCodeInputState> _pinCodeKey = GlobalKey<PinCodeInputState>();
  final _scrollController = ScrollController();
  final _pinCardKey = GlobalKey();
  final _resendBlockKey = GlobalKey();
  Timer? _countdownTimer;
  int _secondsLeft = 0;
  int? _dailyRemaining;
  bool _isLoading = false;
  bool _isResending = false;
  /// Синхронная защита от двойного onCompleted до setState(_isLoading).
  bool _verifyUiInFlight = false;
  /// После успешного verify не сбрасываем in-flight — иначе IME/жесты шлют повторный verify на том же PIN.
  bool _loginSucceeded = false;
  late bool _isErrorState;
  Timer? _shortErrorTimer;
  /// Скролл к PIN только при первом фокусе (не при каждом перескоке цифры).
  bool _didScrollOnFirstPinFocus = false;
  /// Предыдущий нижний inset — для детекта открытия клавиатуры.
  double _lastViewInsetBottom = 0;

  bool get _isBusy => _isLoading || _isResending || _verifyUiInFlight;

  bool _isInvalidCodeError(String? message) {
    if (message == null) return false;
    final normalized = message.toLowerCase();
    if (normalized.contains('invalid_code')) return true;
    if (message == LocalizedMessages.invalidCode) return true;
    return normalized.contains('неверный код') ||
        normalized.contains('invalid code');
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isErrorState = widget.isError;
    _dailyRemaining = widget.dailyRemaining;
    final authService = Provider.of<AuthService>(context, listen: false);
    final fromArgs = widget.initialSeconds ?? 0;
    final fromState = authService.secondsUntilCodeResend;
    final initialSeconds = fromArgs > 0 ? fromArgs : fromState;
    _startCountdown(initialSeconds);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    _shortErrorTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && mounted) {
      Provider.of<AuthService>(context, listen: false).cancelInFlightEmailAuth();
    }
  }

  void _scrollToPinCard() {
    // Мягко подскролливаем только PIN-блок при фокусе, не уводя заголовок.
    Future.delayed(const Duration(milliseconds: 120), () {
      if (!mounted) return;
      if (_pinCardKey.currentContext != null) {
        Scrollable.ensureVisible(
          _pinCardKey.currentContext!,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          alignment: 0.15,
        );
      }
    });
  }

  /// Один скролл при появлении клавиатуры (inset вырос), без дерганий на каждую цифру.
  void _maybeScrollOnKeyboardOpen(double bottomInset) {
    if (bottomInset > _lastViewInsetBottom + 40 && bottomInset > 80) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _scrollToPinCard();
      });
    }
    _lastViewInsetBottom = bottomInset;
  }

  Future<void> _verifyCode(String codeToVerify) async {
    final trimmed = codeToVerify.trim();
    if (trimmed.isEmpty || trimmed.length < 4) {
      showErrorSnackBar(context, context.l10n.authCodeEnterCode);
      return;
    }
    if (_loginSucceeded || _isBusy) return;
    _verifyUiInFlight = true;

    setState(() => _isLoading = true);

    try {
      debugPrint('Email Auth Code Screen: ========== НАЧАЛО ПРОВЕРКИ КОДА ==========');
      debugPrint('Email Auth Code Screen: проверка кода для ${widget.email}, длина=${trimmed.length}');
      final authService = Provider.of<AuthService>(context, listen: false);
      // Таймауты: NetworkTimeouts.authVerifyCode; verify без повтора запроса.
      final success = await authService.verifyCode(widget.email, trimmed);
      
      if (mounted) {
        if (success) {
          debugPrint('Email Auth Code Screen: ✅ код подтверждён, переход в приложение (регистрация устройства в фоне)');
          final vpnService = Provider.of<VpnService>(context, listen: false);
          final token = authService.token;
          if (token == null || token.isEmpty) {
            if (mounted) {
              showErrorSnackBar(context, context.l10n.errorAuthRelogin);
            }
            return;
          }
          _loginSucceeded = true;
          debugPrint('Email Auth Code Screen: ========== УСПЕШНАЯ АВТОРИЗАЦИЯ ==========');

          Navigator.pushNamedAndRemoveUntil(context, '/main', (_) => false);

          unawaited(_postLoginBackgroundTasks(authService, vpnService));
        } else {
          final errorMessage = authService.lastError;
          debugPrint('Email Auth Code Screen: ❌ ошибка проверки кода: ${authService.lastError}');
          debugPrint('Email Auth Code Screen: ========== ОШИБКА АВТОРИЗАЦИИ ==========');
          final backgroundInterrupt =
              errorMessage == LocalizedMessages.authInterruptedInBackground;
          if (backgroundInterrupt) {
            setState(() => _isErrorState = false);
            if (errorMessage != null && errorMessage.isNotEmpty) {
              showErrorSnackBar(context, errorMessage);
            }
          } else {
            // Устанавливаем состояние ошибки - PinCodeInput автоматически обработает
            setState(() => _isErrorState = true);
            // Плашка «неверный код» — см. GraniTheme.authCodeErrorBannerDismissDelay.
            _shortErrorTimer?.cancel();
            if (_isInvalidCodeError(errorMessage)) {
              _shortErrorTimer = Timer(GraniTheme.authCodeErrorBannerDismissDelay, () {
                if (!mounted) return;
                setState(() {
                  _isErrorState = false;
                });
              });
            }
          }
        }
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(context, ErrorHandler().userMessageForConnectionError(e));
      }
    } finally {
      if (!_loginSucceeded) {
        _verifyUiInFlight = false;
        if (mounted) {
          setState(() => _isLoading = false);
        }
      }
    }
  }

  /// Фоновые задачи после успешной авторизации и перехода на [/main].
  Future<void> _postLoginBackgroundTasks(AuthService authService, VpnService vpnService) async {
    try {
      await registerDeviceAfterLoginBackground(
        authService: authService,
        vpnService: vpnService,
      );

      try {
        await vpnService.refreshControlPlaneSnapshot(authService, force: true);
        debugPrint('Email Auth Code Screen: ✅ Control-plane snapshot (background refresh)');
      } catch (e) {
        debugPrint('Email Auth Code Screen: ⚠️ Ошибка snapshot (background): $e');
      }

      // Не вызываем prewarm session/prepare сразу после логина: пользователь часто жмёт Connect
      // через несколько секунд — in-flight prewarm отменяется (cancel_all), лишняя нагрузка и
      // гонка с первым connect. Конфиг и так запрашивается при подключении.

      // user status уже обновлен через единый snapshot.

      // FCM getToken/init на Android может поднять фоновый FlutterEngine — откладываем,
      // чтобы не пересекаться с первым VPN connect (см. push_notification_service / OEM focus).
      unawaited(
        Future.delayed(const Duration(seconds: 20), () async {
          try {
            await PushNotificationService().syncPushTokenWithCurrentSession();
          } catch (e) {
            debugPrint('Email Auth Code Screen: push token sync (deferred): $e');
          }
        }),
      );
      try {
        AnalyticsService().logLogin('email');
        AnalyticsService().setUserId(authService.user?.id);
      } catch (e) {
        debugPrint('Analytics error (non-critical, background): $e');
      }
    } catch (e) {
      debugPrint('Email Auth Code Screen: ⚠️ post-login background tasks error: $e');
    }
  }

  Future<void> _requestNewCode() async {
    final l10n = context.l10n;
    if (_isBusy) return;
    if (_secondsLeft > 0) {
      showErrorSnackBar(context, l10n.authCodeResendWaitSeconds(_secondsLeft));
      return;
    }

    setState(() => _isResending = true);

    try {
      // Отправка нового кода через AuthService
      final authService = Provider.of<AuthService>(context, listen: false);
      final success = await authService.resendCode(widget.email).timeout(
        const Duration(seconds: 60),
        onTimeout: () => throw TimeoutException(l10n.errorTimeoutGeneric),
      );
      
      if (mounted) {
        if (success) {
          _shortErrorTimer?.cancel();
          setState(() {
            _isErrorState = false;
            _dailyRemaining = authService.dailyCodeRemaining;
          });
          _pinCodeKey.currentState?.clear();
          _startCountdown(authService.secondsUntilCodeResend);
          showInfoSnackBar(context, l10n.authCodeNewSent);
        } else {
          showErrorSnackBar(
            context,
            authService.lastError ?? l10n.authEmailSendFailedGeneric,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        showErrorSnackBar(context, ErrorHandler().userMessageForConnectionError(e));
      }
    } finally {
      if (mounted) {
        setState(() => _isResending = false);
      }
    }
  }

  void _startCountdown(int seconds) {
    _countdownTimer?.cancel();
    setState(() {
      _secondsLeft = seconds;
    });
    if (seconds <= 0) return;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsLeft <= 1) {
        timer.cancel();
        setState(() {
          _secondsLeft = 0;
        });
      } else {
        setState(() {
          _secondsLeft -= 1;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final mq = MediaQuery.of(context);
    final screenWidth = mq.size.width;
    final screenHeight = mq.size.height;
    final safeBottom = mq.padding.bottom;
    
    // Определяем режим плотности
    final density = UiTokens.determineDensity(context);
    final tokens = UiTokens.of(density);
    
    // Размеры из макета Figma (базовый экран 412x917, node 516:223)
    const designWidth = 412.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / 917.0;
    // Обновляем dailyRemaining из AuthService если он не был передан
    if (_dailyRemaining == null) {
      try {
        final authService = Provider.of<AuthService>(context, listen: false);
        _dailyRemaining = authService.dailyCodeRemaining;
      } catch (e) {
        debugPrint('Не удалось получить dailyRemaining из AuthService: $e');
      }
    }

    final viewInsets = mq.viewInsets.bottom;
    _maybeScrollOnKeyboardOpen(viewInsets);

    return Scaffold(
      resizeToAvoidBottomInset: true,
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: GraniTheme.startScreenBackgroundGradient,
        ),
        child: SafeArea(
          child: GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            behavior: HitTestBehavior.opaque,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Фиксированный верхний блок: лого + заголовки (не скроллится)
                Padding(
                  padding: EdgeInsets.only(top: tokens.logoTop * scaleY),
                  child: Center(
                    child: SizedBox(
                      width: GraniTheme.logoWidth * scaleX,
                      height: GraniTheme.logoHeight * scaleY,
                      child: Image.asset(
                        'assets/images/figma/logo_grani_new.png',
                        fit: BoxFit.contain,
                        errorBuilder: (context, error, stackTrace) {
                          return const Icon(Icons.vpn_key, size: 40);
                        },
                      ),
                    ),
                  ),
                ),
                SizedBox(height: 18 * scaleY),
                AdaptiveTitleText(
                  text: l10n.authCodeTitle,
                  maxLines: tokens.titleMaxLines,
                  minScale: tokens.titleMinScale,
                  style: GraniTheme.headingLarge.copyWith(
                    fontSize: 40 * scaleX,
                    letterSpacing: -1.6 * scaleX,
                    height: 36 / 40,
                    color: GraniTheme.primaryText,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: tokens.textGap * scaleY),
                AdaptiveSubtitleText(
                  text: l10n.authCodeSubtitle,
                  maxLines: tokens.subtitleMaxLines,
                  style: GraniTheme.bodyLarge.copyWith(
                    fontSize: 16 * scaleX,
                    letterSpacing: 0.96 * scaleX,
                    height: 15.52 / 16,
                    color: GraniTheme.primaryText,
                  ),
                  textAlign: TextAlign.center,
                ),
                SizedBox(height: 14 * scaleY),

                // Скроллируется только PIN-блок, чтобы верхний заголовок всегда оставался видимым.
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: EdgeInsets.fromLTRB(
                      GraniTheme.authScreenHorizontalPadding * scaleX,
                      8 * scaleY,
                      GraniTheme.authScreenHorizontalPadding * scaleX,
                      safeBottom + viewInsets + 32 * scaleY,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // PIN-блок + resend (по макету — без подложки, контент на фоне экрана)
                        Container(
                          key: _pinCardKey,
                          width: double.infinity,
                          padding: EdgeInsets.all(GraniTheme.backgroundBoxPadding * scaleX),
                          decoration: const BoxDecoration(
                            color: Colors.transparent,
                          ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                            Text(
                              l10n.authCodePinLabel,
                              style: GraniTheme.headingMedium.copyWith(
                                fontSize: 32 * scaleX,
                                color: GraniTheme.primaryText,
                              ),
                              textAlign: TextAlign.center,
                            ),
                            SizedBox(height: 24 * scaleY),
                            
                            // Ошибка только при реальной ошибке (после неудачной проверки кода)
                            if (_isErrorState)
                              Padding(
                                padding: EdgeInsets.only(bottom: 8 * scaleY),
                                child: Consumer<AuthService>(
                                  builder: (context, authService, _) => ErrorMessage(
                                    message: authService.lastError ??
                                        context.l10n.authCodeErrorInvalidFallback,
                                    visible: true,
                                  ),
                                ),
                              ),

                            if (_isLoading)
                              Padding(
                                padding: EdgeInsets.only(bottom: 8 * scaleY),
                                child: Text(
                                  l10n.authCodeVerifying,
                                  style: GraniTheme.bodySmall.copyWith(
                                    fontSize: 14 * scaleX,
                                    color: GraniTheme.primaryText.withOpacity(0.8),
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            
                            // PIN-код блок
                            PinCodeInput(
                              key: _pinCodeKey,
                              scaleX: scaleX,
                              scaleY: scaleY,
                              isError: _isErrorState,
                              onChanged: (pin) {
                                if (_isErrorState && pin.isNotEmpty) {
                                  _shortErrorTimer?.cancel();
                                  setState(() => _isErrorState = false);
                                }
                              },
                              onCompleted: (pin) {
                                if (_loginSucceeded || _isBusy) return;
                                if (pin.length == 4) {
                                  _verifyCode(pin);
                                }
                              },
                              onFocusChanged: (hasFocus) {
                                if (hasFocus && !_didScrollOnFirstPinFocus) {
                                  _didScrollOnFirstPinFocus = true;
                                  _scrollToPinCard();
                                }
                              },
                            ),
                            
                            SizedBox(height: 24 * scaleY),
                            Container(
                              key: _resendBlockKey,
                              alignment: Alignment.center,
                              child: _secondsLeft > 0
                                ? Text(
                                    l10n.authCodeResendWithCountdown(_secondsLeft),
                                    style: GraniTheme.bodySmall.copyWith(
                                      fontSize: 14 * scaleX,
                                      color: GraniTheme.primaryText.withOpacity(0.5),
                                    ),
                                    textAlign: TextAlign.center,
                                  )
                                : GestureDetector(
                                    onTap: _isBusy ? null : _requestNewCode,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (_isResending) ...[
                                          SizedBox(
                                            width: 12 * scaleX,
                                            height: 12 * scaleY,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor: AlwaysStoppedAnimation<Color>(
                                                GraniTheme.primaryText.withOpacity(0.7),
                                              ),
                                            ),
                                          ),
                                          SizedBox(width: 8 * scaleX),
                                        ],
                                        Text(
                                          l10n.authCodeResend,
                                          style: GraniTheme.bodySmall.copyWith(
                                            fontSize: 14 * scaleX,
                                            color: const Color(0xFF192F3F),
                                            decoration: TextDecoration.underline,
                                            decorationColor: const Color(0xFF192F3F),
                                          ),
                                          textAlign: TextAlign.center,
                                        ),
                                      ],
                                    ),
                                  ),
                            ),
                      ],
                    ),
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
    );
  }
}
