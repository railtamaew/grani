import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

enum PostAuthPreparationStep {
  network,
  account,
  notifications,
  device,
  access,
  servers,
  ready,
}

class PostAuthPreparationScreen extends StatefulWidget {
  const PostAuthPreparationScreen({
    super.key,
    this.step = PostAuthPreparationStep.account,
    this.progress,
    this.source = 'unknown',
  });

  final PostAuthPreparationStep step;
  final double? progress;
  final String source;

  @override
  State<PostAuthPreparationScreen> createState() =>
      _PostAuthPreparationScreenState();
}

class _PostAuthPreparationScreenState extends State<PostAuthPreparationScreen>
    with TickerProviderStateMixin {
  late final AnimationController _logoPulseController;
  late final AnimationController _activeDotController;
  late final Timer _timer;
  int _elapsedSeconds = 0;

  bool get _isReady => widget.step == PostAuthPreparationStep.ready;

  @override
  void initState() {
    super.initState();
    _logoPulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _activeDotController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1050),
    )..repeat(reverse: true);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _elapsedSeconds++);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _logoPulseController.dispose();
    _activeDotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = _PostAuthPreparationCopy.of(context);
    final disableAnimations = MediaQuery.of(context).disableAnimations;
    final progress = widget.progress ?? _progressForStep(widget.step);

    return PopScope(
      canPop: false,
      child: Scaffold(
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white,
                GraniTheme.surfaceSoft,
                GraniTheme.surfaceBase,
              ],
              stops: [0.0, 0.62, 1.0],
            ),
          ),
          child: SafeArea(
            bottom: true,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final height = constraints.maxHeight;
                final compact = height < 760;
                final topGap = (height * (compact ? 0.055 : 0.085)).clamp(
                  24.0,
                  76.0,
                );
                final logoSize = (height * (compact ? 0.155 : 0.17)).clamp(
                  108.0,
                  154.0,
                );

                return Center(
                  child: SingleChildScrollView(
                    physics: const ClampingScrollPhysics(),
                    padding: EdgeInsets.fromLTRB(
                      24,
                      topGap,
                      24,
                      compact ? 18 : 28,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _PreparationLogo(
                            controller: _logoPulseController,
                            size: logoSize,
                            isReady: _isReady,
                            disableAnimations: disableAnimations,
                          ),
                          SizedBox(height: compact ? 32 : 42),
                          _TitleBlock(
                            title: _title(copy),
                            subtitle: _subtitle(copy),
                          ),
                          SizedBox(height: compact ? 24 : 34),
                          _PreparationSteps(
                            copy: copy,
                            activeStep: widget.step,
                            activeDotController: _activeDotController,
                            disableAnimations: disableAnimations,
                          ),
                          SizedBox(height: compact ? 24 : 34),
                          _PreparationProgress(value: progress),
                          SizedBox(height: compact ? 18 : 28),
                          _HelperNote(
                            text: _helper(copy),
                            visible: _elapsedSeconds >= 3 || compact,
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  String _title(_PostAuthPreparationCopy copy) {
    if (_isReady) return copy.readyTitle;
    if (widget.source == 'google') return copy.googleTitle;
    if (widget.source == 'email') return copy.emailTitle;
    return copy.title;
  }

  String _subtitle(_PostAuthPreparationCopy copy) {
    if (_isReady) return copy.readySubtitle;
    if (_elapsedSeconds >= 8) return copy.slowSubtitle;
    if (widget.source == 'google') return copy.googleSubtitle;
    if (widget.source == 'email') return copy.emailSubtitle;
    return copy.subtitle;
  }

  String _helper(_PostAuthPreparationCopy copy) {
    if (_elapsedSeconds >= 12) return copy.verySlowHelper;
    return copy.helper;
  }

  double _progressForStep(PostAuthPreparationStep step) {
    switch (step) {
      case PostAuthPreparationStep.network:
        return 0.14;
      case PostAuthPreparationStep.account:
        return 0.30;
      case PostAuthPreparationStep.notifications:
        return 0.40;
      case PostAuthPreparationStep.device:
        return 0.52;
      case PostAuthPreparationStep.access:
        return 0.68;
      case PostAuthPreparationStep.servers:
        return 0.86;
      case PostAuthPreparationStep.ready:
        return 1.0;
    }
  }
}

class _PreparationLogo extends StatelessWidget {
  const _PreparationLogo({
    required this.controller,
    required this.size,
    required this.isReady,
    required this.disableAnimations,
  });

  final AnimationController controller;
  final double size;
  final bool isReady;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    final pulse = Tween<double>(
      begin: 1.0,
      end: isReady ? 0.965 : 1.025,
    ).animate(CurvedAnimation(parent: controller, curve: Curves.easeInOut));

    final logo = SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        'assets/images/figma/logo_grani_launcher_foreground.png',
        width: size,
        height: size,
        fit: BoxFit.contain,
      ),
    );

    if (disableAnimations) return logo;
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        return Transform.scale(scale: pulse.value, child: child);
      },
      child: logo,
    );
  }
}

class _TitleBlock extends StatelessWidget {
  const _TitleBlock({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontFamily: 'Montserrat',
            color: GraniTheme.primaryText,
            fontSize: 28,
            fontWeight: FontWeight.w400,
            height: 1.04,
            letterSpacing: 0,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          subtitle,
          textAlign: TextAlign.center,
          style: GraniTheme.bodyLarge.copyWith(
            color: const Color(0xFF687586),
            fontSize: 16,
            fontWeight: FontWeight.w300,
            height: 1.36,
            letterSpacing: 0,
          ),
        ),
      ],
    );
  }
}

class _PreparationSteps extends StatelessWidget {
  const _PreparationSteps({
    required this.copy,
    required this.activeStep,
    required this.activeDotController,
    required this.disableAnimations,
  });

  final _PostAuthPreparationCopy copy;
  final PostAuthPreparationStep activeStep;
  final AnimationController activeDotController;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    final steps = [
      (PostAuthPreparationStep.network, copy.stepNetwork),
      (PostAuthPreparationStep.account, copy.stepAccount),
      (PostAuthPreparationStep.notifications, copy.stepNotifications),
      (PostAuthPreparationStep.device, copy.stepDevice),
      (PostAuthPreparationStep.access, copy.stepAccess),
      (PostAuthPreparationStep.servers, copy.stepServers),
      (PostAuthPreparationStep.ready, copy.stepReady),
    ];
    final activeIndex = activeStep == PostAuthPreparationStep.ready
        ? steps.length - 1
        : activeStep.index.clamp(0, steps.length - 2).toInt();
    final firstVisible = (activeIndex - 1)
        .clamp(0, math.max(0, steps.length - 3))
        .toInt();
    final visibleSteps = steps.skip(firstVisible).take(3).toList();

    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 246),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) {
            return currentChild ?? const SizedBox.shrink();
          },
          transitionBuilder: (child, animation) {
            final offset = Tween<Offset>(
              begin: const Offset(0, 0.08),
              end: Offset.zero,
            ).animate(animation);
            return FadeTransition(
              opacity: animation,
              child: SlideTransition(position: offset, child: child),
            );
          },
          child: Column(
            key: ValueKey(activeStep),
            children: [
              for (var i = 0; i < visibleSteps.length; i++)
                _PreparationStepRow(
                  label: visibleSteps[i].$2,
                  isCompleted: visibleSteps[i].$1.index < activeStep.index,
                  isActive: visibleSteps[i].$1 == activeStep,
                  showConnector: i < visibleSteps.length - 1,
                  activeDotController: activeDotController,
                  disableAnimations: disableAnimations,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreparationStepRow extends StatelessWidget {
  const _PreparationStepRow({
    required this.label,
    required this.isCompleted,
    required this.isActive,
    required this.showConnector,
    required this.activeDotController,
    required this.disableAnimations,
  });

  final String label;
  final bool isCompleted;
  final bool isActive;
  final bool showConnector;
  final AnimationController activeDotController;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    final textColor = isCompleted || isActive
        ? GraniTheme.primaryText
        : const Color(0xFF8A96A6);
    final fontWeight = isActive ? FontWeight.w500 : FontWeight.w400;
    final opacity = isActive ? 1.0 : (isCompleted ? 0.58 : 0.48);
    final fontSize = isActive ? 16.0 : 14.5;

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 240),
      opacity: opacity,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 38,
            child: Column(
              children: [
                _StepMark(
                  isCompleted: isCompleted,
                  isActive: isActive,
                  controller: activeDotController,
                  disableAnimations: disableAnimations,
                ),
                if (showConnector)
                  Container(
                    width: 2,
                    height: 16,
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE5E9EF),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                top: isActive ? 3 : 5,
                bottom: showConnector ? 10 : 0,
              ),
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GraniTheme.bodyLarge.copyWith(
                  color: textColor,
                  fontSize: fontSize,
                  height: 1.24,
                  fontWeight: fontWeight,
                  letterSpacing: 0,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepMark extends StatelessWidget {
  const _StepMark({
    required this.isCompleted,
    required this.isActive,
    required this.controller,
    required this.disableAnimations,
  });

  final bool isCompleted;
  final bool isActive;
  final AnimationController controller;
  final bool disableAnimations;

  @override
  Widget build(BuildContext context) {
    if (isCompleted) {
      return const _StepCircle(
        child: Icon(
          Icons.check_rounded,
          size: 20,
          color: GraniTheme.primaryText,
        ),
      );
    }

    if (!isActive) {
      return _StepCircle(
        child: Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFD2D8E0), width: 2),
          ),
        ),
      );
    }

    final dot = AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = disableAnimations ? 1.0 : controller.value;
        final scale = 0.82 + (math.sin(t * math.pi) * 0.26);
        final opacity = 0.48 + (math.sin(t * math.pi) * 0.52);
        return Transform.scale(
          scale: scale,
          child: Opacity(
            opacity: opacity.clamp(0.0, 1.0).toDouble(),
            child: Container(
              width: 13,
              height: 13,
              decoration: const BoxDecoration(
                color: GraniTheme.warmAccent,
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      },
    );

    return _StepCircle(child: dot);
  }
}

class _StepCircle extends StatelessWidget {
  const _StepCircle({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: GraniTheme.graniSurfaceDecoration(
        radius: 19,
        borderOpacity: 0.78,
        shadows: GraniTheme.surfaceSoftShadow,
      ),
      child: child,
    );
  }
}

class _PreparationProgress extends StatelessWidget {
  const _PreparationProgress({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final clamped = value.clamp(0.0, 1.0).toDouble();
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 4,
        color: const Color(0xFFE5E9EF),
        child: LayoutBuilder(
          builder: (context, constraints) {
            return TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: clamped),
              duration: const Duration(milliseconds: 520),
              curve: Curves.easeOutCubic,
              builder: (context, animatedValue, _) {
                return Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: constraints.maxWidth * animatedValue,
                    decoration: BoxDecoration(
                      color: GraniTheme.warmAccent,
                      borderRadius: BorderRadius.circular(999),
                      boxShadow: [
                        BoxShadow(
                          color: GraniTheme.warmAccent.withOpacity(0.34),
                          blurRadius: 12,
                          spreadRadius: 0,
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _HelperNote extends StatelessWidget {
  const _HelperNote({required this.text, required this.visible});

  final String text;
  final bool visible;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 260),
      opacity: visible ? 1 : 0,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.lock_outline_rounded,
            size: 17,
            color: const Color(0xFF8A96A6).withOpacity(0.78),
          ),
          const SizedBox(width: 9),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: GraniTheme.bodySmall.copyWith(
                color: const Color(0xFF8A96A6),
                fontSize: 13.5,
                height: 1.25,
                letterSpacing: 0,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PostAuthPreparationCopy {
  const _PostAuthPreparationCopy({
    required this.title,
    required this.subtitle,
    required this.googleTitle,
    required this.googleSubtitle,
    required this.emailTitle,
    required this.emailSubtitle,
    required this.slowSubtitle,
    required this.readyTitle,
    required this.readySubtitle,
    required this.stepNetwork,
    required this.stepAccount,
    required this.stepNotifications,
    required this.stepDevice,
    required this.stepAccess,
    required this.stepServers,
    required this.stepReady,
    required this.helper,
    required this.verySlowHelper,
  });

  final String title;
  final String subtitle;
  final String googleTitle;
  final String googleSubtitle;
  final String emailTitle;
  final String emailSubtitle;
  final String slowSubtitle;
  final String readyTitle;
  final String readySubtitle;
  final String stepNetwork;
  final String stepAccount;
  final String stepNotifications;
  final String stepDevice;
  final String stepAccess;
  final String stepServers;
  final String stepReady;
  final String helper;
  final String verySlowHelper;

  static _PostAuthPreparationCopy of(BuildContext context) {
    final isRu = Localizations.localeOf(context).languageCode == 'ru';
    return isRu ? ru : en;
  }

  static const ru = _PostAuthPreparationCopy(
    title: 'Подготавливаем защиту',
    subtitle: 'Проверяем аккаунт и загружаем данные',
    googleTitle: 'Завершаем вход через Google',
    googleSubtitle: 'Синхронизируем аккаунт и устройство',
    emailTitle: 'Завершаем вход через email',
    emailSubtitle: 'Подтверждаем сессию и готовим приложение',
    slowSubtitle: 'Сеть отвечает медленнее обычного. Продолжаем подготовку.',
    readyTitle: 'Готово',
    readySubtitle: 'GRANI готов к защищённому подключению',
    stepNetwork: 'Проверяем соединение',
    stepAccount: 'Подтверждаем вход',
    stepNotifications: 'Настраиваем уведомления',
    stepDevice: 'Синхронизируем устройство',
    stepAccess: 'Проверяем доступ',
    stepServers: 'Загружаем серверы',
    stepReady: 'Готово',
    helper: 'При мобильной сети это может занять несколько секунд',
    verySlowHelper:
        'Если сеть нестабильна, подготовка может занять чуть дольше',
  );

  static const en = _PostAuthPreparationCopy(
    title: 'Preparing protection',
    subtitle: 'Checking your account and loading data',
    googleTitle: 'Finishing Google sign-in',
    googleSubtitle: 'Syncing your account and this device',
    emailTitle: 'Finishing email sign-in',
    emailSubtitle: 'Confirming your session and preparing the app',
    slowSubtitle:
        'The network is responding slower than usual. Still preparing.',
    readyTitle: 'Ready',
    readySubtitle: 'GRANI is ready for a protected connection',
    stepNetwork: 'Checking connection',
    stepAccount: 'Confirming sign-in',
    stepNotifications: 'Setting up notifications',
    stepDevice: 'Syncing this device',
    stepAccess: 'Checking access',
    stepServers: 'Loading servers',
    stepReady: 'Ready',
    helper: 'On mobile networks this may take a few seconds',
    verySlowHelper:
        'If the network is unstable, preparation can take a bit longer',
  );
}
