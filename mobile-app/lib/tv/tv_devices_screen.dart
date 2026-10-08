import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/auth_service.dart';
import '../services/vpn_service.dart';
import 'tv_ui.dart';

class TvDevicesScreen extends StatefulWidget {
  const TvDevicesScreen({super.key, this.resolveLimit = false});
  final bool resolveLimit;
  @override
  State<TvDevicesScreen> createState() => _TvDevicesScreenState();
}

class _TvDevicesScreenState extends State<TvDevicesScreen> {
  List<Map<String, dynamic>> _devices = [];
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await context.read<VpnService>().fetchDevicesWithAuth(
            forceRefresh: true,
          );
      if (mounted)
        setState(
          () => _devices = result.whereType<Map<String, dynamic>>().toList(),
        );
    } catch (_) {
      if (mounted)
        setState(
          () => _error = tvText(
            context,
            'Не удалось загрузить устройства.',
            'Could not load devices.',
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(Map<String, dynamic> device) async {
    final id = device['device_id']?.toString();
    if (id == null || id.isEmpty) return;
    final name =
        device['device_name']?.toString() ?? device['name']?.toString() ?? id;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tvText(context, 'Отключить устройство?', 'Remove device?')),
        content: Text(name),
        actions: [
          TvButton(
            label: tvText(context, 'Отмена', 'Cancel'),
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
          ),
          TvButton(
            label: tvText(context, 'Отключить', 'Remove'),
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await context.read<VpnService>().deleteDeviceWithAuth(id);
      await _load();
    } catch (_) {
      if (mounted)
        setState(
          () => _error = tvText(
            context,
            'Не удалось отключить устройство.',
            'Could not remove the device.',
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _continue() async {
    if (_busy) return;
    final auth = context.read<AuthService>();
    final vpn = context.read<VpnService>();
    final token = auth.token;
    if (token == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await vpn.ensureDeviceRegistered(token, force: true);
      auth.clearPendingDeviceLimit();
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted)
        setState(
          () => _error = tvText(
            context,
            'Освободите место для телевизора и попробуйте ещё раз.',
            'Free a device slot for this TV and try again.',
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentId = context.read<VpnService>().deviceId;
    return TvPage(
      title: tvText(
        context,
        widget.resolveLimit ? 'Лимит устройств' : 'Мои устройства',
        widget.resolveLimit ? 'Device limit' : 'My devices',
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.resolveLimit) ...[
            TvNotice(
              tvText(
                context,
                'Отключите одно из других устройств, чтобы подключить телевизор.',
                'Remove another device to connect this TV.',
              ),
            ),
            const SizedBox(height: 18),
          ],
          if (_error != null) ...[
            TvNotice(_error!, error: true),
            const SizedBox(height: 14),
          ],
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: ListView.separated(
              itemCount: _devices.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, index) {
                final d = _devices[index];
                final current = d['device_id']?.toString() == currentId;
                final name = d['device_name']?.toString() ??
                    d['name']?.toString() ??
                    d['device_id']?.toString() ??
                    '—';
                return TvProfileRow(
                  label:
                      '$name${current ? tvText(context, ' · этот телевизор', ' · this TV') : ''}',
                  asset: 'monitor_new.svg',
                  autofocus: index == 0,
                  onPressed: _busy || current ? null : () => _remove(d),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          TvButton(
            label: tvText(
              context,
              widget.resolveLimit ? 'Продолжить' : 'Обновить',
              widget.resolveLimit ? 'Continue' : 'Refresh',
            ),
            onPressed: _busy
                ? null
                : widget.resolveLimit
                    ? _continue
                    : _load,
          ),
        ],
      ),
    );
  }
}
