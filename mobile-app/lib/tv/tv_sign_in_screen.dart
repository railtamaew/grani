import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../core/session/app_session_controller.dart';
import '../services/auth_service.dart';
import '../l10n/l10n.dart';
import '../theme.dart';
import '../widgets/pin_code_input.dart';
import 'tv_ui.dart';

class TvSignInScreen extends StatefulWidget {
  const TvSignInScreen({super.key});

  @override
  State<TvSignInScreen> createState() => _TvSignInScreenState();
}

class _TvSignInScreenState extends State<TvSignInScreen> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  final _emailFocus = FocusNode();
  final _pin = GlobalKey<PinCodeInputState>();
  int _step = 0;
  bool _busy = false;
  String? _error;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    _email.dispose();
    _code.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  void _setStep(int step) {
    setState(() {
      _step = step;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (step == 1) _emailFocus.requestFocus();
      if (step == 2) _pin.currentState?.clear();
    });
  }

  Future<void> _sendCode({bool resend = false}) async {
    if (_busy) return;
    final email = _email.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email)) {
      setState(
        () => _error = email.isEmpty
            ? context.l10n.authEmailErrorEmpty
            : context.l10n.authEmailErrorInvalidFormat,
      );
      return;
    }
    final auth = context.read<AuthService>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sent = resend
          ? await auth.resendCode(email)
          : await auth.sendCode(email, omitGlobalLoadingState: true);
      if (!mounted) return;
      if (sent) {
        _code.clear();
        _setStep(2);
        _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
          if (mounted && _step == 2) setState(() {});
        });
      } else {
        setState(
          () => _error = auth.lastError ??
              tvText(
                context,
                'Не удалось отправить код. Попробуйте ещё раз.',
                'Could not send the code. Please try again.',
              ),
        );
      }
    } catch (_) {
      if (mounted)
        setState(
          () => _error = tvText(
            context,
            'Не удалось связаться с сервером. Попробуйте ещё раз.',
            'Could not reach the server. Please try again.',
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _verify() async {
    if (_busy) return;
    if (_code.text.trim().length < 4) {
      setState(
        () => _error = tvText(
          context,
          'Введите код из письма.',
          'Enter the email code.',
        ),
      );
      return;
    }
    final auth = context.read<AuthService>();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final success = await auth.verifyCode(
        _email.text.trim(),
        _code.text.trim(),
      );
      if (!mounted) return;
      if (success && auth.isAuthenticated) {
        Navigator.pushNamedAndRemoveUntil(
          context,
          AppSessionController.targetRouteForAuthenticatedUser(auth),
          (_) => false,
        );
      } else {
        setState(
          () => _error = auth.lastError ??
              tvText(
                context,
                'Код не подошёл. Проверьте письмо.',
                'Check the code in your email.',
              ),
        );
      }
    } catch (_) {
      if (mounted)
        setState(
          () => _error = tvText(
            context,
            'Не удалось проверить код. Попробуйте ещё раз.',
            'Could not verify the code. Please try again.',
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // On a single-line field the vertical arrows should leave the editor once
  // the TV keyboard is dismissed. The IME handles its own arrows while open.
  Widget _remoteInput(Widget field) => Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
          SingleActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
        },
        child: field,
      );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cooldown = context.read<AuthService>().secondsUntilCodeResend;
    final title = _step == 0
        ? l10n.startHeadline
        : _step == 1
            ? l10n.authEmailTitle
            : l10n.authCodeTitle;
    final subtitle = _step == 0
        ? l10n.startSubtitle
        : _step == 1
            ? l10n.authEmailSubtitle
            : l10n.authCodeSubtitle;
    return PopScope(
      canPop: _step == 0 && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy && _step > 0) _setStep(_step - 1);
      },
      child: TvPage(
        title: '',
        showBack: false,
        contentWidth: 520,
        child: Center(
            child: SingleChildScrollView(
                child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title,
                textAlign: TextAlign.center,
                style: GraniTheme.headingLarge
                    .copyWith(fontSize: _step == 0 ? 40 : 36, height: 1.1)),
            const SizedBox(height: 18),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 16,
                    height: 1.35,
                    fontWeight: FontWeight.w300,
                    color: GraniTheme.secondaryText)),
            const SizedBox(height: 32),
            if (_step == 1)
              DecoratedBox(
                decoration: GraniTheme.graniSurfaceDecoration(radius: 32),
                child: _remoteInput(TextField(
                  key: const ValueKey('tv-email'),
                  controller: _email,
                  focusNode: _emailFocus,
                  enabled: !_busy,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.done,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      color: GraniTheme.primaryText),
                  decoration: InputDecoration(
                      hintText: l10n.authEmailFieldHint,
                      prefixIcon: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Image.asset(
                              'assets/images/figma/email_icon.png',
                              width: 22,
                              height: 22))),
                  onSubmitted: (_) => _sendCode(),
                )),
              ),
            if (_step == 2)
              KeyedSubtree(
                  key: const ValueKey('tv-code'),
                  child: IgnorePointer(
                      ignoring: _busy,
                      child: ExcludeFocus(
                          excluding: _busy,
                          child: Shortcuts(
                              shortcuts: const {
                                SingleActivator(LogicalKeyboardKey.arrowDown):
                                    DirectionalFocusIntent(
                                        TraversalDirection.down),
                                SingleActivator(LogicalKeyboardKey.arrowUp):
                                    DirectionalFocusIntent(
                                        TraversalDirection.up),
                              },
                              child: PinCodeInput(
                                  key: _pin,
                                  scaleX: 1,
                                  scaleY: .85,
                                  isError: _error != null,
                                  onChanged: (value) => _code.text = value,
                                  onCompleted: (_) => _verify()))))),
            if (_error != null) ...[
              const SizedBox(height: 16),
              TvNotice(_error!, error: true)
            ],
            if (_busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator()
            ],
            const SizedBox(height: 24),
            TvButton(
                label: _step == 0
                    ? l10n.startContinueEmail
                    : _step == 1
                        ? l10n.authEmailSendCode
                        : l10n.startSignIn,
                primary: true,
                autofocus: _step == 0,
                onPressed: _busy
                    ? null
                    : () {
                        if (_step == 0) {
                          _setStep(1);
                        } else if (_step == 1) {
                          _sendCode();
                        } else {
                          _verify();
                        }
                      }),
            if (_step == 2) ...[
              const SizedBox(height: 12),
              TvButton(
                  textOnly: true,
                  label: cooldown > 0
                      ? tvText(context, 'Новый код через $cooldown с',
                          'New code in ${cooldown}s')
                      : l10n.authCodeResend,
                  onPressed: _busy || cooldown > 0
                      ? null
                      : () => _sendCode(resend: true)),
            ],
            const SizedBox(height: 12),
            TvButton(
                textOnly: true,
                label: _step == 0
                    ? l10n.startPrivacyMore
                    : tvText(context, 'Назад', 'Back'),
                onPressed: _busy
                    ? null
                    : () {
                        if (_step == 0) {
                          Navigator.pushNamed(context, '/privacy');
                        } else {
                          _setStep(_step - 1);
                        }
                      }),
          ],
        ))),
      ),
    );
  }
}
