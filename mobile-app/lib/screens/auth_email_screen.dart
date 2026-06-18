import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/l10n.dart';
import '../theme.dart';
import '../widgets/privacy_policy_bottom_sheet.dart';
import '../widgets/error_message.dart';
import '../services/auth_service.dart';
import '../widgets/ui_density.dart';
import '../widgets/adaptive_text.dart';
import 'auth_code_screen.dart';

class AuthEmailScreen extends StatefulWidget {
  const AuthEmailScreen({super.key});

  @override
  State<AuthEmailScreen> createState() => _AuthEmailScreenState();
}

class _AuthEmailScreenState extends State<AuthEmailScreen>
    with WidgetsBindingObserver {
  final emailController = TextEditingController();
  final _scrollController = ScrollController();
  final _emailFocusNode = FocusNode();
  final _formCardKey = GlobalKey();
  final _sendButtonKey = GlobalKey();
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Слушаем фокус на поле ввода для автоскролла
    _emailFocusNode.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    emailController.dispose();
    _scrollController.dispose();
    _emailFocusNode.removeListener(_onFocusChange);
    _emailFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && mounted) {
      Provider.of<AuthService>(context, listen: false)
          .cancelInFlightEmailAuth();
    }
  }

  void _onFocusChange() {
    if (_emailFocusNode.hasFocus) {
      _scrollToFormCard();
    }
  }

  void _scrollToFormCard() {
    // Ждём открытия клавиатуры, затем прокручиваем так, чтобы инпут и кнопка были над клавиатурой
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      if (_formCardKey.currentContext != null) {
        Scrollable.ensureVisible(
          _formCardKey.currentContext!,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          alignment:
              0.0, // блок формы к верху видимой области — инпут не за клавиатурой
        );
      }
      if (_sendButtonKey.currentContext != null) {
        Scrollable.ensureVisible(
          _sendButtonKey.currentContext!,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        );
      }
    });
  }

  Future<void> _sendCode() async {
    final l10n = context.l10n;
    setState(() {
      _errorMessage = null;
    });

    if (emailController.text.isEmpty) {
      setState(() {
        _errorMessage = l10n.authEmailErrorEmpty;
      });
      return;
    }

    // Валидация email
    final emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+');
    if (!emailRegex.hasMatch(emailController.text)) {
      setState(() {
        _errorMessage = l10n.authEmailErrorInvalidFormat;
      });
      return;
    }
    final authService = Provider.of<AuthService>(context, listen: false);
    final email = emailController.text.trim();

    // Fire-and-forget send-code: сразу открываем экран ввода кода, не ждём HTTP-ответ (медленный SMTP / receiveTimeout).
    unawaited(
      authService.sendCode(email, omitGlobalLoadingState: true).then((ok) {
        if (!mounted) return;
        if (!ok) {
          debugPrint(
              'Email Auth Screen: send-code в фоне завершился с ok=false (см. lastError на экране кода / повтор)');
        }
      }),
    );

    debugPrint(
        'Email Auth Screen: переход на экран ввода кода (без ожидания send-code)');
    Navigator.pushNamed(
      context,
      '/auth-code',
      arguments: AuthCodeScreenArguments(
        email: email,
        initialSeconds: authService.secondsUntilCodeResend,
        dailyRemaining: authService.dailyCodeRemaining,
      ),
    );
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

    // Размеры из макета Figma (базовый экран 412x917, node 516:206)
    const designWidth = 412.0;
    final scaleX = screenWidth / designWidth;
    final scaleY = screenHeight / 917.0;
    // Отступ лого → заголовок по макету AuthEmailScreen: 290px
    const logoToTitleGap = 290.0;

    final viewInsets = mq.viewInsets.bottom;

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
                // Зона A: фиксированный логотип (не скроллится)
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
                // Зона B + C: скроллируемый контент (при клавиатуре — padding.bottom = viewInsets)
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: EdgeInsets.fromLTRB(
                      GraniTheme.authScreenHorizontalPadding * scaleX,
                      logoToTitleGap * scaleY,
                      GraniTheme.authScreenHorizontalPadding * scaleX,
                      safeBottom + viewInsets + 80 * scaleY,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Заголовок и подзаголовок
                        SizedBox(
                          width: double.infinity,
                          child: AdaptiveTitleText(
                            text: l10n.authEmailTitle,
                            maxLines: tokens.titleMaxLines,
                            minScale: tokens.titleMinScale,
                            style: GraniTheme.headingLarge.copyWith(
                              fontSize: 36 * scaleX,
                              letterSpacing: -0.04 * 40 * scaleX,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        SizedBox(height: tokens.textGap * scaleY),
                        SizedBox(
                          width: double.infinity,
                          child: AdaptiveSubtitleText(
                            text: l10n.authEmailSubtitle,
                            maxLines: tokens.subtitleMaxLines,
                            style: GraniTheme.bodyLarge.copyWith(
                              fontSize: 16 * scaleX,
                              letterSpacing: 0.96 * scaleX,
                              color: GraniTheme.primaryText,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        SizedBox(height: 32 * scaleY),
                        // Поле ввода + ошибка + CTA (зона B); key для ensureVisible при фокусе
                        Column(
                          key: _formCardKey,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_errorMessage != null)
                              Padding(
                                padding: EdgeInsets.only(bottom: 8 * scaleY),
                                child: ErrorMessage(
                                  message: _errorMessage!,
                                  visible: true,
                                ),
                              ),
                            // Email Input Field
                            Container(
                              width: double.infinity,
                              height: GraniTheme.inputHeight * scaleY,
                              padding: EdgeInsets.symmetric(
                                horizontal: GraniTheme.paddingXLarge * scaleX,
                                vertical: GraniTheme.paddingLarge * scaleY,
                              ),
                              decoration: BoxDecoration(
                                gradient: GraniTheme.surfaceControlGradient,
                                borderRadius: BorderRadius.circular(
                                    GraniTheme.radiusButton * scaleX),
                                border: Border.all(
                                  color: _errorMessage != null
                                      ? GraniTheme.errorBorder.withOpacity(0.5)
                                      : (_emailFocusNode.hasFocus
                                          ? const Color(0xFF192F3F)
                                              .withOpacity(0.35)
                                          : GraniTheme.surfaceControlBorder
                                              .withOpacity(0.86)),
                                  width: _emailFocusNode.hasFocus ||
                                          _errorMessage != null
                                      ? 1.5
                                      : 1,
                                ),
                                boxShadow:
                                    GraniTheme.surfaceControlShadowStrong,
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.start,
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  SizedBox(
                                    width: GraniTheme.buttonIconSize * scaleX,
                                    height: GraniTheme.buttonIconSize * scaleY,
                                    child: Image.asset(
                                      'assets/images/figma/email_icon.png',
                                      fit: BoxFit.contain,
                                      errorBuilder:
                                          (context, error, stackTrace) {
                                        return Icon(
                                          Icons.email_outlined,
                                          size: GraniTheme.buttonIconSize *
                                              scaleX,
                                          color: GraniTheme.secondaryText,
                                        );
                                      },
                                    ),
                                  ),
                                  SizedBox(width: 10 * scaleX),
                                  Expanded(
                                    child: TextField(
                                      controller: emailController,
                                      focusNode: _emailFocusNode,
                                      keyboardType: TextInputType.emailAddress,
                                      textAlignVertical:
                                          TextAlignVertical.center,
                                      scrollPadding: const EdgeInsets.only(
                                        bottom: 280,
                                      ),
                                      style: GraniTheme.emailInputText.copyWith(
                                        fontSize: 16 * scaleX,
                                      ),
                                      decoration: InputDecoration(
                                        hintText: l10n.authEmailFieldHint,
                                        hintStyle: GraniTheme.emailPlaceholder
                                            .copyWith(
                                          fontSize: 16 * scaleX,
                                          color: GraniTheme.secondaryText
                                              .withOpacity(0.65),
                                        ),
                                        border: InputBorder.none,
                                        isDense: true,
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                      onChanged: (_) {
                                        setState(() {
                                          _errorMessage = null;
                                        });
                                      },
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: 16 * scaleY),
                            // Кнопка "Отправить код" (CTA — ключ для ensureVisible при клавиатуре)
                            Consumer<AuthService>(
                              builder: (context, authService, child) {
                                final isLoading = authService.isLoading;
                                return Material(
                                  key: _sendButtonKey,
                                  color: Colors.transparent,
                                  child: InkWell(
                                    onTap: isLoading ? null : _sendCode,
                                    borderRadius: BorderRadius.circular(
                                        GraniTheme.radiusButton * scaleX),
                                    child: Container(
                                      width: double.infinity,
                                      height: GraniTheme.buttonHeight * scaleY,
                                      padding: EdgeInsets.symmetric(
                                        horizontal:
                                            GraniTheme.paddingXLarge * scaleX,
                                        vertical:
                                            GraniTheme.paddingLarge * scaleY,
                                      ),
                                      decoration: BoxDecoration(
                                        color: isLoading
                                            ? GraniTheme.buttonPrimary
                                                .withOpacity(0.6)
                                            : GraniTheme.buttonPrimary,
                                        borderRadius: BorderRadius.circular(
                                            GraniTheme.radiusButton * scaleX),
                                        boxShadow: GraniTheme
                                            .primaryButtonShadowWithInset,
                                      ),
                                      alignment: Alignment.center,
                                      child: isLoading
                                          ? SizedBox(
                                              width: GraniTheme.buttonIconSize *
                                                  scaleX,
                                              height:
                                                  GraniTheme.buttonIconSize *
                                                      scaleY,
                                              child:
                                                  const CircularProgressIndicator(
                                                strokeWidth: 2,
                                                valueColor:
                                                    AlwaysStoppedAnimation<
                                                            Color>(
                                                        GraniTheme.white),
                                              ),
                                            )
                                          : Text(
                                              l10n.authEmailSendCode,
                                              style: GraniTheme.buttonTextMedium
                                                  .copyWith(
                                                fontSize: 22 * scaleX,
                                                letterSpacing:
                                                    0.06 * 22 * scaleX,
                                                color: GraniTheme.white,
                                                height: 1.1,
                                              ),
                                              textAlign: TextAlign.center,
                                            ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                        SizedBox(height: 16 * scaleY),
                        GestureDetector(
                          onTap: () => PrivacyPolicyBottomSheet.show(context),
                          child: Center(
                            child: Text(
                              l10n.startPrivacyMore,
                              style: GraniTheme.privacyLinkText.copyWith(
                                fontSize: 14 * scaleX,
                                color: const Color(0xFF192F3F),
                                decoration: TextDecoration.underline,
                                decorationColor: const Color(0xFF192F3F),
                              ),
                              textAlign: TextAlign.center,
                            ),
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
