import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../theme.dart';
import '../widgets/device_card.dart';
import '../widgets/snackbar_utils.dart';
import '../services/vpn_service.dart';
import '../services/auth_service.dart';
import '../config/app_config.dart';
import '../core/api/dio_error_detail.dart';
import '../core/errors/error_handler.dart';
import '../l10n/l10n.dart';
import '../utils/device_last_activity_label.dart';
import '../utils/device_current_match.dart';

class DevicesScreen extends StatefulWidget {
  const DevicesScreen({super.key});

  @override
  State<DevicesScreen> createState() => _DevicesScreenState();
}

class _DevicesScreenState extends State<DevicesScreen> {
  List<Map<String, dynamic>> _devices = [];
  bool _isLoading = true;
  String? _error;
  String? _confirmDeviceId;
  String? _deletingDeviceId;
  String? _inlineError;
  Future<void>? _loadDevicesInFlight;
  final GlobalKey<SliverAnimatedListState> _animatedListKey =
      GlobalKey<SliverAnimatedListState>();

  @override
  void initState() {
    super.initState();
    _loadDevices();
  }

  String? get _currentDeviceId {
    try {
      return context.read<VpnService>().deviceId;
    } catch (_) {
      return null;
    }
  }

  /// Лимит из профиля/подписки (`/auth/me` → max_devices), иначе [AppConfig.maxDevices].
  int get _devicesLimit {
    try {
      return context.watch<AuthService>().maxDevices;
    } catch (_) {
      return AppConfig.maxDevices;
    }
  }

  Future<void> _loadDevices() async {
    final inFlight = _loadDevicesInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final fut = () async {
      setState(() {
        _isLoading = true;
        _error = null;
      });
      try {
        final vpnService = context.read<VpnService>();
        final list = await vpnService.fetchDevicesWithAuth();
        if (mounted) {
          setState(() {
            _devices = list.whereType<Map<String, dynamic>>().toList();
            _isLoading = false;
          });
        }
      } on TimeoutException {
        if (mounted) {
          setState(() {
            _error = context.l10n.errorTimeoutGeneric;
            _isLoading = false;
            // Не затираем _devices — показываем ранее загруженный список при сетевом таймауте.
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() {
            _error = ErrorHandler().userMessageForConnectionError(e);
            _isLoading = false;
            // Не затираем _devices при ошибке обновления (таймаут/Dio): оставляем последний успешный список.
          });
        }
      }
    }();
    _loadDevicesInFlight = fut;
    try {
      await fut;
    } finally {
      if (identical(_loadDevicesInFlight, fut)) {
        _loadDevicesInFlight = null;
      }
    }
  }

  /// Сортировка: текущее устройство первым, остальные по lastSeenAt (новые выше).
  List<Map<String, dynamic>> get _sortedDevices {
    final currentId = _currentDeviceId?.trim();
    final current = _devices.where((d) {
      final id = (d['device_id'] as String? ?? '').trim();
      return currentId != null &&
          currentId.isNotEmpty &&
          id == currentId &&
          isCurrentDeviceCard(d, _currentDeviceId, _devices);
    }).toList();
    final others = _devices.where((d) {
      final id = (d['device_id'] as String? ?? '').trim();
      return currentId == null ||
          currentId.isEmpty ||
          id != currentId ||
          !isCurrentDeviceCard(d, _currentDeviceId, _devices);
    }).toList();
    others.sort((a, b) {
      final aTime = _parseLastSeen(a);
      final bTime = _parseLastSeen(b);
      return bTime.compareTo(aTime);
    });
    return [...current, ...others];
  }

  int _parseLastSeen(Map<String, dynamic> d) {
    final lastSeen = d['last_seen'] ?? d['last_activity'] ?? d['updated_at'];
    if (lastSeen is int) return lastSeen;
    if (lastSeen is String)
      return DateTime.tryParse(lastSeen)?.millisecondsSinceEpoch ?? 0;
    return 0;
  }

  void _onDeleteTap(String deviceId, String name) {
    if (_confirmDeviceId == deviceId) {
      _performDelete(deviceId, name);
    } else {
      setState(() {
        _confirmDeviceId = deviceId;
        _inlineError = null;
      });
    }
  }

  void _cancelConfirm() {
    setState(() {
      _confirmDeviceId = null;
      _inlineError = null;
    });
  }

  Future<void> _performDelete(String deviceId, String name) async {
    setState(() {
      _deletingDeviceId = deviceId;
      _inlineError = null;
    });
    try {
      final vpnService = context.read<VpnService>();
      await vpnService.deleteDeviceWithAuth(deviceId).timeout(
            const Duration(seconds: 4),
            onTimeout: () => throw TimeoutException('timeout'),
          );
      if (!mounted) return;
      final oldSorted = List<Map<String, dynamic>>.from(_sortedDevices);
      final index = oldSorted
          .indexWhere((d) => (d['device_id'] as String? ?? '') == deviceId);
      if (index >= 0) {
        setState(() {
          _devices.removeWhere(
              (d) => (d['device_id'] as String? ?? '') == deviceId);
          _confirmDeviceId = null;
          _deletingDeviceId = null;
        });
        _animatedListKey.currentState?.removeItem(
          index,
          (context, animation) => _buildRemovingCard(
            context,
            oldSorted[index],
            animation,
          ),
          duration: const Duration(milliseconds: 280),
        );
        if (mounted) {
          showErrorSnackBar(context, context.l10n.devicesDeletedSnackbar);
        }
      } else {
        await _loadDevices();
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _inlineError = context.l10n.deviceListConnectionError;
          _deletingDeviceId = null;
        });
      }
    } catch (e) {
      if (!mounted) return;
      final fromServer =
          e is DioException ? userVisibleMessageFromDioResponse(e) : null;
      setState(() {
        _inlineError = (fromServer != null && fromServer.isNotEmpty)
            ? fromServer
            : context.l10n.deviceDeleteFailedGeneric;
        _deletingDeviceId = null;
      });
    }
  }

  Widget _buildRemovingCard(
    BuildContext context,
    Map<String, dynamic> device,
    Animation<double> animation,
  ) {
    return FadeTransition(
      opacity: animation,
      child: SizeTransition(
        sizeFactor: animation,
        axisAlignment: -1,
        child: DeviceCard(
          device: device,
          isCurrentDevice: isCurrentDeviceCard(
            device,
            _currentDeviceId,
            _devices,
          ),
          isConfirming: false,
          isDeleting: false,
          otherButtonsBlocked: true,
          lastActivityLabel: deviceLastActivityLabel(
            device,
            context.l10n,
            whenNoTimestamp: context.l10n.deviceRecentlyActive,
          ),
          onDeleteTap: (_, __) {},
          onCancelConfirm: () {},
          onPerformDelete: (_, __) async {},
        ),
      ),
    );
  }

  Color _limitColor() {
    final count = _devices.length;
    final limit = _devicesLimit;
    if (count > limit) return GraniTheme.deviceLimitIndicatorRed;
    if (count == limit) return GraniTheme.devicesCountOrange;
    return GraniTheme.successGreen;
  }

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: const SystemUiOverlayStyle(
        statusBarColor: Color(0xFFFFFFFF),
        statusBarIconBrightness: Brightness.dark,
        statusBarBrightness: Brightness.light,
        systemNavigationBarColor: Color(0xFFF7F9FA),
        systemNavigationBarIconBrightness: Brightness.dark,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: Scaffold(
        body: Container(
          decoration: const BoxDecoration(
            gradient: GraniTheme.devicesScreenBackgroundGradient,
          ),
          child: SafeArea(
            child: Column(
              children: [
                AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  leading: IconButton(
                    icon: const Icon(Icons.arrow_back,
                        color: GraniTheme.primaryText),
                    onPressed: () => Navigator.pop(context),
                  ),
                  centerTitle: true,
                  title: Text(
                    context.l10n.devicesScreenTitle,
                    style: GraniTheme.bodyMedium.copyWith(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: GraniTheme.primaryText,
                    ),
                  ),
                ),
                Expanded(child: _buildContent()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline,
                size: 48, color: GraniTheme.warningOrange),
            const SizedBox(height: 16),
            Text(_error!,
                textAlign: TextAlign.center, style: GraniTheme.bodyMedium),
            const SizedBox(height: 16),
            _SurfaceActionButton(
              label: context.l10n.devicesRetry,
              onPressed: _loadDevices,
            ),
          ],
        ),
      );
    }
    if (_devices.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.devices_other, size: 64, color: Colors.grey[400]),
              const SizedBox(height: 16),
              Text(
                context.l10n.devicesEmptyTitle,
                style: GraniTheme.bodyMedium.copyWith(fontSize: 18),
              ),
              const SizedBox(height: 8),
              Text(
                context.l10n.devicesEmptySubtitle,
                textAlign: TextAlign.center,
                style: GraniTheme.bodyMedium.copyWith(
                  fontSize: 14,
                  color: GraniTheme.secondaryText,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _loadDevices,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _buildLimitBlock()),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            sliver: SliverAnimatedList(
              key: _animatedListKey,
              initialItemCount: _sortedDevices.length,
              itemBuilder: (context, index, animation) {
                if (index >= _sortedDevices.length) {
                  return const SizedBox.shrink();
                }
                final d = _sortedDevices[index];
                return FadeTransition(
                  opacity: animation,
                  child: SizeTransition(
                    sizeFactor: animation,
                    axisAlignment: -1,
                    child: DeviceCard(
                      device: d,
                      isCurrentDevice: isCurrentDeviceCard(
                        d,
                        _currentDeviceId,
                        _devices,
                      ),
                      isConfirming:
                          _confirmDeviceId == (d['device_id'] as String? ?? ''),
                      isDeleting: _deletingDeviceId ==
                          (d['device_id'] as String? ?? ''),
                      inlineError:
                          _confirmDeviceId == (d['device_id'] as String? ?? '')
                              ? _inlineError
                              : null,
                      otherButtonsBlocked: _confirmDeviceId != null,
                      lastActivityLabel: deviceLastActivityLabel(
                        d,
                        context.l10n,
                        whenNoTimestamp: context.l10n.deviceRecentlyActive,
                      ),
                      onDeleteTap: _onDeleteTap,
                      onCancelConfirm: _cancelConfirm,
                      onPerformDelete: _performDelete,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLimitBlock() {
    final l10n = context.l10n;
    final count = _devices.length;
    final limit = _devicesLimit;
    final isExceeded = count > limit;
    final limitColor = _limitColor();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: child,
        ),
        child: Container(
          key: ValueKey('$count-$limit'),
          padding: const EdgeInsets.all(16),
          decoration: GraniTheme.graniSurfaceDecoration(
            radius: GraniTheme.profileCardRadius,
            borderColor: isExceeded
                ? GraniTheme.deviceLimitIndicatorRed
                : GraniTheme.surfaceControlBorder,
            borderOpacity: isExceeded ? 0.22 : 0.82,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              RichText(
                text: TextSpan(
                  style: GraniTheme.bodyMedium.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                    color: GraniTheme.primaryText,
                  ),
                  children: [
                    TextSpan(text: l10n.devicesConnectedPrefix),
                    TextSpan(
                      text: '$count / $limit',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w500,
                        color: limitColor,
                      ),
                    ),
                    TextSpan(text: l10n.devicesConnectedSuffix),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.devicesHintChangePhone,
                style: GraniTheme.bodySmall.copyWith(
                  fontSize: 14,
                  fontWeight: FontWeight.w300,
                  color: GraniTheme.secondaryText,
                ),
              ),
              if (isExceeded) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.devicesLimitExceeded,
                  style: GraniTheme.bodySmall.copyWith(
                    fontSize: 14,
                    color: GraniTheme.deviceLimitErrorText,
                  ),
                ),
              ],
              if (!isExceeded && count == limit && count > 0) ...[
                const SizedBox(height: 8),
                Text(
                  l10n.devicesLimitReached,
                  style: GraniTheme.bodySmall.copyWith(
                    fontSize: 14,
                    fontWeight: FontWeight.w400,
                    color: GraniTheme.secondaryText,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SurfaceActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;

  const _SurfaceActionButton({
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: GraniTheme.graniSurfaceDecoration(
            radius: 18,
            shadows: GraniTheme.surfaceControlShadow,
          ),
          child: Text(
            label,
            style: GraniTheme.bodySmall.copyWith(
              color: GraniTheme.primaryText,
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
        ),
      ),
    );
  }
}
