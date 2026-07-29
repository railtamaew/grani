import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../config/app_config.dart';
import '../../screens/post_auth_preparation_screen.dart';
import '../../services/analytics_service.dart';
import '../../services/auth_service.dart';
import '../../services/push_notification_service.dart';
import '../../services/vpn_service.dart';
import '../../services/install_attribution_service.dart';
import 'app_session_controller.dart';
import 'device_limit_flow.dart' show registerDeviceAfterLoginBackground;

class PostAuthPreparationArguments {
  const PostAuthPreparationArguments({
    required this.source,
  });

  final String source;
}

class PostAuthPreparationCoordinatorScreen extends StatefulWidget {
  const PostAuthPreparationCoordinatorScreen({
    super.key,
    required this.source,
  });

  final String source;

  @override
  State<PostAuthPreparationCoordinatorScreen> createState() =>
      _PostAuthPreparationCoordinatorScreenState();
}

class _PostAuthPreparationCoordinatorScreenState
    extends State<PostAuthPreparationCoordinatorScreen> {
  PostAuthPreparationStep _step = PostAuthPreparationStep.network;
  int _runRevision = 0;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _run();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PostAuthPreparationScreen(
      step: _step,
      source: widget.source,
    );
  }

  Future<void> _run() async {
    if (_running) return;
    final revision = ++_runRevision;
    final visibleSince = DateTime.now();
    setState(() {
      _running = true;
      _step = PostAuthPreparationStep.network;
    });

    final authService = context.read<AuthService>();
    final vpnService = context.read<VpnService>();
    final total = Stopwatch()..start();
    debugPrint(
      '[auth-timing] post_auth_preparation_start '
      'source=${widget.source} build=${AppConfig.buildNumber}',
    );

    try {
      await _runSoftStep(
        PostAuthPreparationStep.network,
        () => authService.ensureNetworkReady(),
        timeout: AppConfig.postAuthPreparationNetworkSoftTimeout,
      );

      final hasAccount = await _runAccountStep(authService);
      if (!hasAccount) {
        total.stop();
        debugPrint(
          '[auth-timing] post_auth_preparation_missing_account '
          'source=${widget.source} total_ms=${total.elapsedMilliseconds}',
        );
        await _logoutToStart();
        return;
      }

      await _runSoftStep(PostAuthPreparationStep.device, () async {
        debugPrint(
          '[auth-timing] post_auth_preparation_device_background_start '
          'source=${widget.source}',
        );
        unawaited(registerDeviceAfterLoginBackground(
          authService: authService,
          vpnService: vpnService,
        ));
      });

      await _runSoftStep(
        PostAuthPreparationStep.access,
        () => authService.refreshUserStatus(force: true),
        timeout: AppConfig.postAuthPreparationAccessSoftTimeout,
      );
      if ((authService.trialSecondsLeft ?? 0) > 0) {
        unawaited(InstallAttributionService.instance
            .logLifecycleEvent('trial_started'));
      }

      await _runSoftStep(
        PostAuthPreparationStep.servers,
        () => vpnService.refreshControlPlaneSnapshot(authService, force: true),
        timeout: AppConfig.postAuthPreparationServersSoftTimeout,
      );

      if (!mounted || revision != _runRevision) return;
      setState(() => _step = PostAuthPreparationStep.ready);
      _schedulePostAuthBackgroundTasks(authService);
      await _finishPreparation(
        authService: authService,
        total: total,
        visibleSince: visibleSince,
        revision: revision,
        reason: 'done',
      );
    } catch (e, st) {
      debugPrint('[auth-timing] post_auth_preparation_unexpected $e\n$st');
      if (!mounted || revision != _runRevision) return;
      if (authService.isAuthenticated) {
        await _finishPreparation(
          authService: authService,
          total: total,
          visibleSince: visibleSince,
          revision: revision,
          reason: 'unexpected_recovered',
        );
      } else {
        total.stop();
        await _logoutToStart();
      }
    } finally {
      if (mounted && revision == _runRevision) {
        setState(() => _running = false);
      }
    }
  }

  Future<bool> _runAccountStep(AuthService authService) async {
    if (!mounted) return false;
    setState(() => _step = PostAuthPreparationStep.account);
    final stepStarted = DateTime.now();
    final sw = Stopwatch()..start();
    final waitForAuthSession =
        widget.source == 'google' || widget.source == 'email';

    var ok = _hasValidAuthSession(authService);
    if (!ok && waitForAuthSession) {
      final deadline = DateTime.now().add(
        AppConfig.postAuthPreparationAccountWaitTimeout,
      );
      debugPrint(
        '[auth-timing] post_auth_preparation_account_wait_begin '
        'source=${widget.source}',
      );
      while (mounted && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        ok = _hasValidAuthSession(authService);
        if (ok) break;
      }
    }

    sw.stop();
    final status = ok
        ? 'ok'
        : (waitForAuthSession ? 'timeout_missing_token' : 'missing_token');
    debugPrint(
      '[auth-timing] post_auth_preparation_step_done '
      'step=account status=$status elapsed_ms=${sw.elapsedMilliseconds}',
    );
    await _waitStepVisible(stepStarted);
    return ok;
  }

  bool _hasValidAuthSession(AuthService authService) {
    final token = authService.token;
    return authService.isAuthenticated && token != null && token.isNotEmpty;
  }

  Future<bool> _runSoftStep(
    PostAuthPreparationStep step,
    Future<void> Function() action, {
    Duration? timeout,
  }) async {
    if (!mounted) return false;
    setState(() {
      _step = step;
    });
    final sw = Stopwatch()..start();
    final stepStarted = DateTime.now();
    try {
      final future = action();
      if (timeout == null) {
        await future;
      } else {
        await future.timeout(timeout);
      }
      sw.stop();
      debugPrint(
        '[auth-timing] post_auth_preparation_step_done '
        'step=${step.name} elapsed_ms=${sw.elapsedMilliseconds}',
      );
      await _waitStepVisible(stepStarted);
      return true;
    } catch (e) {
      sw.stop();
      debugPrint(
        '[auth-timing] post_auth_preparation_step_soft_failed '
        'step=${step.name} elapsed_ms=${sw.elapsedMilliseconds} error=$e',
      );
      await _waitStepVisible(stepStarted);
      return false;
    }
  }

  Future<void> _waitMinimumVisible(DateTime visibleSince) async {
    final elapsed = DateTime.now().difference(visibleSince);
    final remaining = AppConfig.postAuthPreparationMinVisible - elapsed;
    if (remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }
  }

  Future<void> _waitStepVisible(DateTime stepStarted) async {
    final elapsed = DateTime.now().difference(stepStarted);
    final remaining = AppConfig.postAuthPreparationStepMinVisible - elapsed;
    if (remaining > Duration.zero) {
      await Future<void>.delayed(remaining);
    }
  }

  Future<void> _finishPreparation({
    required AuthService authService,
    required Stopwatch total,
    required DateTime visibleSince,
    required int revision,
    required String reason,
  }) async {
    await _waitMinimumVisible(visibleSince);
    if (!mounted || revision != _runRevision) return;
    final pendingAppLink = await InstallAttributionService.instance
        .takePendingRouteIfAuthorized(authService.isAuthenticated);
    final route = pendingAppLink ??
        AppSessionController.targetRouteForAuthenticatedUser(authService);
    total.stop();
    debugPrint(
      '[auth-timing] post_auth_preparation_done '
      'source=${widget.source} total_ms=${total.elapsedMilliseconds} '
      'route=$route reason=$reason',
    );
    Navigator.pushNamedAndRemoveUntil(context, route, (_) => false);
  }

  void _schedulePostAuthBackgroundTasks(AuthService authService) {
    try {
      AnalyticsService().logLogin(widget.source);
      AnalyticsService().setUserId(authService.user?.id);
      InstallAttributionService.instance
          .logLifecycleEvent('authorization_completed');
    } catch (e) {
      debugPrint('PostAuthPreparation: analytics error: $e');
    }

    unawaited(
      Future<void>.delayed(const Duration(seconds: 20), () async {
        try {
          await PushNotificationService().syncPushTokenWithCurrentSession();
          debugPrint(
              '[auth-timing] post_auth_push_token_bg_done status=success');
        } catch (e) {
          debugPrint('[auth-timing] post_auth_push_token_bg_done error=$e');
        }
      }),
    );
  }

  Future<void> _logoutToStart() async {
    try {
      await context.read<AuthService>().logout();
    } catch (e) {
      debugPrint('PostAuthPreparation: logout error: $e');
    }
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, '/', (_) => false);
  }
}
