import 'dart:async';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/api/dio_error_detail.dart';
import '../core/api/network_timeouts.dart';
import '../theme.dart';
import '../services/auth_service.dart';
import '../services/vpn_service.dart';
import '../widgets/device_card.dart';
import '../l10n/l10n.dart';
import '../utils/device_last_activity_label.dart';
import '../utils/device_current_match.dart';

/// Результат экрана лимита устройств.
enum DeviceLimitResult {
  /// Пользователь освободил слот — можно продолжить.
  resolved,

  /// Пользователь вышел из текущего устройства — нужен logout + welcome screen.
  loggedOutCurrentDevice,
}

/// Показывает blocking modal bottom sheet «Лимит устройств».
/// По ТЗ: высота 85–90%, закрыть нельзя, единственный выход — удаление устройства.
Future<DeviceLimitResult?> showDeviceLimitModal(
  BuildContext context, {
  required List<dynamic> initialDevices,
  required int maxDevices,
}) {
  return showModalBottomSheet<DeviceLimitResult>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withOpacity(0.45),
    builder: (ctx) => _DeviceLimitSheet(
      initialDevices: initialDevices,
      maxDevices: maxDevices,
    ),
  );
}

/// Содержимое bottom sheet «Лимит устройств».
class _DeviceLimitSheet extends StatefulWidget {
  final List<dynamic> initialDevices;
  final int maxDevices;

  /// true = полноэкранный route (нельзя закрыть), false = modal bottom sheet.
  final bool fullScreen;

  const _DeviceLimitSheet({
    required this.initialDevices,
    required this.maxDevices,
    this.fullScreen = false,
  });

  @override
  State<_DeviceLimitSheet> createState() => _DeviceLimitSheetState();
}

class _DeviceLimitSheetState extends State<_DeviceLimitSheet> {
  late List<Map<String, dynamic>> _devices;
  bool _isLoading = false;
  String? _loadError;
  String? _deletingDeviceId;
  String? _confirmDeviceId; // устройство в режиме подтверждения
  String? _inlineError; // ошибка удаления для конкретной карточки
  Future<void>? _loadDevicesInFlight;

  @override
  void initState() {
    super.initState();
    _devices = widget.initialDevices.whereType<Map<String, dynamic>>().toList();
    if (_devices.isEmpty) {
      _loadDevices();
    }
  }

  String? get _currentDeviceId {
    try {
      return context.read<VpnService>().deviceId;
    } catch (_) {
      return null;
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
        _loadError = null;
      });
      try {
        final vpnService = context.read<VpnService>();
        final wall = await NetworkTimeouts.deviceLimitWallOperationTimeout();
        final list = await vpnService.fetchDevicesWithAuth().timeout(
              wall,
              onTimeout: () => throw TimeoutException('timeout'),
            );
        if (!mounted) return;
        final devices = list.whereType<Map<String, dynamic>>().toList();
        setState(() {
          _devices = devices;
          _isLoading = false;
          if (devices.isEmpty) {
            _loadError = context.l10n.deviceLimitEmptyList;
          }
        });
      } on TimeoutException {
        if (!mounted) return;
        _onLoadDevicesNetworkError();
      } catch (_) {
        if (!mounted) return;
        _onLoadDevicesNetworkError();
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

  /// При ошибке сети: если есть initialDevices — используем их без повторного запроса.
  void _onLoadDevicesNetworkError() {
    if (widget.initialDevices.isNotEmpty) {
      final fromInitial =
          widget.initialDevices.whereType<Map<String, dynamic>>().toList();
      setState(() {
        _devices = fromInitial;
        _isLoading = false;
        _loadError = null;
      });
    } else {
      setState(() {
        _loadError = context.l10n.deviceListConnectionError;
        _isLoading = false;
      });
    }
  }

  /// Сортировка: самые старые выше, текущее устройство — всегда внизу
  List<Map<String, dynamic>> get _sortedDevices {
    final currentId = _currentDeviceId?.trim();
    final others = _devices.where((d) {
      final id = (d['device_id'] as String? ?? '').trim();
      return currentId == null ||
          currentId.isEmpty ||
          id != currentId ||
          !isCurrentDeviceCard(d, _currentDeviceId, _devices);
    }).toList();
    final current = _devices.where((d) {
      final id = (d['device_id'] as String? ?? '').trim();
      return currentId != null &&
          currentId.isNotEmpty &&
          id == currentId &&
          isCurrentDeviceCard(d, _currentDeviceId, _devices);
    }).toList();
    // Сортируем остальные по давности (last_seen / last_activity)
    others.sort((a, b) {
      final aTime = _parseLastSeen(a);
      final bTime = _parseLastSeen(b);
      return aTime.compareTo(bTime);
    });
    return [...others, ...current];
  }

  int _parseLastSeen(Map<String, dynamic> d) {
    final lastSeen = d['last_seen'] ??
        d['last_activity'] ??
        d['last_connected'] ??
        d['updated_at'];
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
      final wall = await NetworkTimeouts.deviceLimitWallOperationTimeout();
      final remaining = await vpnService.deleteDeviceWithAuth(deviceId).timeout(
            wall,
            onTimeout: () => throw TimeoutException('timeout'),
          );
      if (!mounted) return;
      setState(() {
        _devices = _devices
            .where((d) => (d['device_id'] as String?) != deviceId)
            .toList();
        _confirmDeviceId = null;
        _deletingDeviceId = null;
      });
      // UX: после успешного delete закрываем модалку сразу.
      // Фактическая проверка лимита/возможности регистрации выполняется следующим шагом
      // (ensureDeviceRegistered), и при необходимости модалка откроется повторно.
      debugPrint(
        'DeviceLimitSheet: delete success device_id=$deviceId remaining=$remaining local_count=${_devices.length}',
      );
      // Сбрасываем pending лимит сразу после успешного удаления:
      // дальнейшая валидация лимита будет на шаге ensureDeviceRegistered.
      context.read<AuthService>().clearPendingDeviceLimit();
      await Future.delayed(const Duration(milliseconds: 250));
      if (mounted) {
        Navigator.of(context).pop(DeviceLimitResult.resolved);
      }
    } on TimeoutException {
      if (!mounted) return;
      setState(() {
        _inlineError = context.l10n.deviceListConnectionError;
        _deletingDeviceId = null;
      });
    } catch (e) {
      if (!mounted) return;
      final dio = e is DioException ? e : null;
      if (dio?.response?.statusCode == 404) {
        setState(() {
          _devices = _devices
              .where((d) => (d['device_id'] as String?) != deviceId)
              .toList();
          _confirmDeviceId = null;
          _deletingDeviceId = null;
          _inlineError = null;
        });
        await _loadDevices();
        return;
      }
      final fromServer =
          dio != null ? userVisibleMessageFromDioResponse(dio) : null;
      setState(() {
        _inlineError = (fromServer != null && fromServer.isNotEmpty)
            ? fromServer
            : context.l10n.deviceDeleteFailedGeneric;
        _deletingDeviceId = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final maxH = widget.fullScreen ? 1.0 : 0.9;
    return PopScope(
      canPop: false,
      child: Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * maxH,
        ),
        decoration: BoxDecoration(
          gradient: GraniTheme.startScreenBackgroundGradient,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(
            color: GraniTheme.surfaceControlBorder.withOpacity(0.78),
          ),
          boxShadow: GraniTheme.surfaceRaisedShadow,
        ),
        // Фиксированный размер — по ТЗ экран жёсткий, сворачивать нельзя.
        child: DraggableScrollableSheet(
          initialChildSize: maxH,
          minChildSize: maxH,
          maxChildSize: maxH,
          expand: false,
          builder: (_, scrollController) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: CustomScrollView(
                controller: scrollController,
                slivers: [
                  const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  _buildHeader(),
                  const SliverToBoxAdapter(child: SizedBox(height: 20)),
                  _buildLimitIndicator(),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  _buildDeviceList(),
                  const SliverToBoxAdapter(child: SizedBox(height: 16)),
                  _buildBottomText(),
                  const SliverToBoxAdapter(child: SizedBox(height: 24)),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final l10n = context.l10n;
    return SliverToBoxAdapter(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.devices,
                  size: 28, color: GraniTheme.primaryText),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  l10n.deviceLimitTitle,
                  style: GraniTheme.bodyMedium.copyWith(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                    color: GraniTheme.primaryText,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            l10n.deviceLimitSubtitle(
              _devices.length.toString(),
              widget.maxDevices.toString(),
            ),
            style: GraniTheme.bodyMedium.copyWith(
              fontSize: 14,
              color: GraniTheme.secondaryText,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLimitIndicator() {
    final l10n = context.l10n;
    final count = _devices.length;
    final limit = widget.maxDevices;
    final isExceeded = count > limit;
    return SliverToBoxAdapter(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: child,
        ),
        child: Container(
          key: ValueKey('$count-$limit-$isExceeded'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: GraniTheme.graniSurfaceDecoration(
            radius: 16,
            borderColor: isExceeded
                ? GraniTheme.deviceLimitIndicatorRed
                : GraniTheme.surfaceControlBorder,
            borderOpacity: isExceeded ? 0.22 : 0.82,
            shadows: GraniTheme.surfaceControlShadow,
          ),
          child: Text(
            l10n.deviceLimitCount(count.toString(), limit.toString()),
            style: GraniTheme.bodyMedium.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w500,
              color: isExceeded
                  ? GraniTheme.deviceLimitIndicatorRed
                  : GraniTheme.primaryText,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceList() {
    if (_isLoading && _devices.isEmpty) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          (_, i) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _buildSkeletonCard(),
          ),
          childCount: 3,
        ),
      );
    }
    if (_loadError != null && _devices.isEmpty) {
      return SliverFillRemaining(
        hasScrollBody: false,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _loadError!,
              textAlign: TextAlign.center,
              style: GraniTheme.bodyMedium
                  .copyWith(color: GraniTheme.secondaryText),
            ),
            const SizedBox(height: 16),
            _DeviceLimitSurfaceButton(
              label: context.l10n.devicesRetry,
              onTap: _loadDevices,
            ),
          ],
        ),
      );
    }
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (_, index) {
          final d = _sortedDevices[index];
          return DeviceCard(
            device: d,
            isCurrentDevice: isCurrentDeviceCard(
              d,
              _currentDeviceId,
              _devices,
            ),
            isConfirming: _confirmDeviceId == (d['device_id'] as String? ?? ''),
            isDeleting: _deletingDeviceId == (d['device_id'] as String? ?? ''),
            inlineError: _confirmDeviceId == (d['device_id'] as String? ?? '')
                ? _inlineError
                : null,
            otherButtonsBlocked: _confirmDeviceId != null,
            lastActivityLabel: deviceLastActivityLabel(d, context.l10n),
            onDeleteTap: _onDeleteTap,
            onCancelConfirm: _cancelConfirm,
            onPerformDelete: _performDelete,
          );
        },
        childCount: _sortedDevices.length,
      ),
    );
  }

  Widget _buildSkeletonCard() {
    return Container(
      height: 80,
      decoration: GraniTheme.graniSurfaceDecoration(
        radius: GraniTheme.profileCardRadius,
        borderOpacity: 0.58,
        shadows: GraniTheme.surfaceControlShadow,
      ),
    );
  }

  Widget _buildBottomText() {
    return SliverToBoxAdapter(
      child: Text(
        context.l10n.deviceLimitBottomHint,
        style: GraniTheme.bodySmall.copyWith(
          color: GraniTheme.secondaryText,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _DeviceLimitSurfaceButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _DeviceLimitSurfaceButton({
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
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

/// Оставлен для совместимости с route /device-limit.
/// В новых местах вызывайте [showDeviceLimitModal].
/// При использовании как route — полноэкранный жёсткий экран (нельзя закрыть).
class DeviceLimitScreen extends StatelessWidget {
  final List<dynamic> initialDevices;
  final int maxDevices;

  const DeviceLimitScreen({
    super.key,
    required this.initialDevices,
    this.maxDevices = 5,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: GraniTheme.white,
      body: SafeArea(
        child: _DeviceLimitSheet(
          initialDevices: initialDevices,
          maxDevices: maxDevices,
          fullScreen: true,
        ),
      ),
    );
  }
}
