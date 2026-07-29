import 'dart:async';

import 'package:flutter/material.dart';

import '../config/app_navigation.dart';
import '../l10n/localized_messages.dart';

enum InAppEventTone { success, warning, critical, info }

class InAppEventBannerService {
  InAppEventBannerService._();

  static final InAppEventBannerService instance = InAppEventBannerService._();

  final ValueNotifier<InAppEventBannerPayload?> activeBanner =
      ValueNotifier<InAppEventBannerPayload?>(null);

  Timer? _dismissTimer;
  int _nextBannerId = 0;

  void show({
    required String title,
    required String body,
    Map<String, dynamic>? data,
  }) {
    final eventName = (data?['event'] ?? data?['type'] ?? '').toString();
    final tone = _toneFor(data);
    final actionLabel =
        LocalizedMessages.currentLanguageCode == 'ru' ? 'Журнал' : 'Journal';

    _dismissTimer?.cancel();
    activeBanner.value = InAppEventBannerPayload(
      id: ++_nextBannerId,
      title: title,
      body: body,
      tone: tone,
      actionLabel: actionLabel,
      eventName: eventName,
    );
    if (_shouldAutoDismiss(tone)) {
      _dismissTimer = Timer(const Duration(seconds: 7), _dismissCurrent);
    }
    debugPrint('[IN_APP_EVENT] queued event=$eventName title="$title"');
  }

  void _dismissCurrent() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    activeBanner.value = null;
  }

  InAppEventTone _toneFor(Map<String, dynamic>? data) {
    final event = (data?['event'] ?? '').toString();
    final action = (data?['grani_action'] ?? '').toString();
    if (action == 'stop_vpn' ||
        event == 'subscription_expired' ||
        event == 'subscription_revoked' ||
        event == 'trial_ended' ||
        event == 'device_limit' ||
        event == 'device_limit_exceeded' ||
        event == 'device_revoked') {
      return InAppEventTone.critical;
    }
    if (event == 'payment_failed' ||
        event == 'subscription_expiry_warning' ||
        event == 'trial_expiry_warning' ||
        event == 'trial_ending') {
      return InAppEventTone.warning;
    }
    if (event == 'payment_completed' ||
        event == 'subscription_activated' ||
        event == 'access_changed') {
      return InAppEventTone.success;
    }
    if (event == 'trial_activated') {
      return InAppEventTone.info;
    }
    return InAppEventTone.info;
  }

  bool _shouldAutoDismiss(InAppEventTone tone) {
    return tone == InAppEventTone.info;
  }
}

class InAppEventBannerPayload {
  const InAppEventBannerPayload({
    required this.id,
    required this.title,
    required this.body,
    required this.tone,
    required this.actionLabel,
    required this.eventName,
  });

  final int id;
  final String title;
  final String body;
  final InAppEventTone tone;
  final String actionLabel;
  final String eventName;
}

class InAppEventBannerHost extends StatefulWidget {
  const InAppEventBannerHost({super.key, required this.child});

  final Widget child;

  @override
  State<InAppEventBannerHost> createState() => _InAppEventBannerHostState();
}

class _InAppEventBannerHostState extends State<InAppEventBannerHost> {
  int? _lastRenderedId;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        ValueListenableBuilder<InAppEventBannerPayload?>(
          valueListenable: InAppEventBannerService.instance.activeBanner,
          builder: (context, payload, _) {
            if (payload == null) return const SizedBox.shrink();
            if (_lastRenderedId != payload.id) {
              _lastRenderedId = payload.id;
              debugPrint(
                '[IN_APP_EVENT] rendered event=${payload.eventName} '
                'id=${payload.id}',
              );
            }
            final topInset = MediaQuery.paddingOf(context).top;
            return Positioned(
              top: topInset + 8,
              left: 14,
              right: 14,
              child: _SwipeDismissRegion(
                onDismiss: InAppEventBannerService.instance._dismissCurrent,
                child: _AnimatedInAppEventCard(
                  key: ValueKey<int>(payload.id),
                  title: payload.title,
                  body: payload.body,
                  tone: payload.tone,
                  actionLabel: payload.actionLabel,
                  onOpenJournal: () {
                    InAppEventBannerService.instance._dismissCurrent();
                    appNavigatorKey.currentState?.pushNamed(
                      '/notification-journal',
                    );
                  },
                  onDismiss: InAppEventBannerService.instance._dismissCurrent,
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _SwipeDismissRegion extends StatefulWidget {
  const _SwipeDismissRegion({
    required this.child,
    required this.onDismiss,
  });

  final Widget child;
  final VoidCallback onDismiss;

  @override
  State<_SwipeDismissRegion> createState() => _SwipeDismissRegionState();
}

class _SwipeDismissRegionState extends State<_SwipeDismissRegion> {
  static const double _horizontalThreshold = 76;
  static const double _upThreshold = 58;

  Offset _dragOffset = Offset.zero;
  bool _dismissed = false;

  void _handleUpdate(DragUpdateDetails details) {
    if (_dismissed) return;
    final next = _dragOffset + details.delta;
    setState(() {
      _dragOffset = Offset(
        next.dx.clamp(-140.0, 140.0).toDouble(),
        next.dy.clamp(-96.0, 0.0).toDouble(),
      );
    });
  }

  void _handleEnd(DragEndDetails details) {
    if (_dismissed) return;
    final shouldDismiss = _dragOffset.dx.abs() >= _horizontalThreshold ||
        _dragOffset.dy <= -_upThreshold;
    if (shouldDismiss) {
      _dismissed = true;
      widget.onDismiss();
      return;
    }
    setState(() => _dragOffset = Offset.zero);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanUpdate: _handleUpdate,
      onPanEnd: _handleEnd,
      onPanCancel: () {
        if (!_dismissed) {
          setState(() => _dragOffset = Offset.zero);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOutCubic,
        transform: Matrix4.translationValues(
          _dragOffset.dx,
          _dragOffset.dy,
          0,
        ),
        child: widget.child,
      ),
    );
  }
}

class _AnimatedInAppEventCard extends StatelessWidget {
  const _AnimatedInAppEventCard({
    super.key,
    required this.title,
    required this.body,
    required this.tone,
    required this.actionLabel,
    required this.onOpenJournal,
    required this.onDismiss,
  });

  final String title;
  final String body;
  final InAppEventTone tone;
  final String actionLabel;
  final VoidCallback onOpenJournal;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, -14 * (1 - value)),
            child: child,
          ),
        );
      },
      child: _InAppEventCard(
        title: title,
        body: body,
        tone: tone,
        actionLabel: actionLabel,
        onOpenJournal: onOpenJournal,
        onDismiss: onDismiss,
      ),
    );
  }
}

class _InAppEventCard extends StatelessWidget {
  const _InAppEventCard({
    required this.title,
    required this.body,
    required this.tone,
    required this.actionLabel,
    required this.onOpenJournal,
    required this.onDismiss,
  });

  final String title;
  final String body;
  final InAppEventTone tone;
  final String actionLabel;
  final VoidCallback onOpenJournal;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = _BannerColors.forTone(tone);
    final icon = _iconFor(tone);

    return Material(
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.12),
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: colors.background,
                border: Border.all(color: colors.border),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: DecoratedBox(
              decoration: BoxDecoration(color: colors.accent),
              child: const SizedBox(width: 3),
            ),
          ),
          Positioned(
            right: -24,
            top: -18,
            child: _SubtleFacet(color: colors.accent, size: 86, opacity: 0.045),
          ),
          Positioned(
            right: 58,
            bottom: -28,
            child: _SubtleFacet(color: colors.accent, size: 58, opacity: 0.04),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                _IconChip(colors: colors, icon: icon),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.primary,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          height: 1.15,
                        ),
                      ),
                      if (body.trim().isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          body,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.secondary,
                            fontSize: 13,
                            height: 1.22,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: onOpenJournal,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.primary.withValues(alpha: 0.78),
                    backgroundColor: colors.accent.withValues(alpha: 0.08),
                    minimumSize: const Size(0, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  child: Text(
                    actionLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: LocalizedMessages.currentLanguageCode == 'ru'
                      ? 'Закрыть'
                      : 'Close',
                  onPressed: onDismiss,
                  icon: Icon(
                    Icons.close_rounded,
                    color: colors.secondary,
                    size: 18,
                  ),
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  IconData _iconFor(InAppEventTone tone) {
    switch (tone) {
      case InAppEventTone.success:
        return Icons.check_rounded;
      case InAppEventTone.warning:
        return Icons.priority_high_rounded;
      case InAppEventTone.critical:
        return Icons.close_rounded;
      case InAppEventTone.info:
        return Icons.notifications_none_rounded;
    }
  }
}

class _IconChip extends StatelessWidget {
  const _IconChip({required this.colors, required this.icon});

  final _BannerColors colors;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.1),
        border: Border.all(color: colors.accent.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: SizedBox(
        width: 40,
        height: 40,
        child: Icon(icon, color: colors.accent, size: 23),
      ),
    );
  }
}

class _SubtleFacet extends StatelessWidget {
  const _SubtleFacet({
    required this.color,
    required this.size,
    required this.opacity,
  });

  final Color color;
  final double size;
  final double opacity;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Transform.rotate(
        angle: -0.58,
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: color.withValues(alpha: opacity),
            borderRadius: BorderRadius.circular(18),
          ),
        ),
      ),
    );
  }
}

class _BannerColors {
  const _BannerColors({
    required this.background,
    required this.primary,
    required this.secondary,
    required this.accent,
    required this.border,
  });

  final Color background;
  final Color primary;
  final Color secondary;
  final Color accent;
  final Color border;

  static _BannerColors forTone(InAppEventTone tone) {
    switch (tone) {
      case InAppEventTone.success:
        return const _BannerColors(
          background: Color(0xFFF6FBF8),
          primary: Color(0xFF182D3D),
          secondary: Color(0xFF5E6B73),
          accent: Color(0xFF2FBF7A),
          border: Color(0xFFDCEBE3),
        );
      case InAppEventTone.warning:
        return const _BannerColors(
          background: Color(0xFFFFF8EA),
          primary: Color(0xFF182D3D),
          secondary: Color(0xFF5E6B73),
          accent: Color(0xFFE09B2D),
          border: Color(0xFFF1DFC0),
        );
      case InAppEventTone.critical:
        return const _BannerColors(
          background: Color(0xFFFFF0EE),
          primary: Color(0xFF182D3D),
          secondary: Color(0xFF5E6B73),
          accent: Color(0xFFE05A4F),
          border: Color(0xFFF0CDC8),
        );
      case InAppEventTone.info:
        return const _BannerColors(
          background: Color(0xFFEAF2FF),
          primary: Color(0xFF182D3D),
          secondary: Color(0xFF5E6B73),
          accent: Color(0xFF3A7BD5),
          border: Color(0xFFD6E3F8),
        );
    }
  }
}
