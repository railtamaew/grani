import 'package:flutter/material.dart';
import '../services/native_vpn_service.dart';
import 'tv_ui.dart';
import '../widgets/split_tunnel/split_tunnel_ui_kit.dart';

class TvSplitTunnelScreen extends StatefulWidget {
  const TvSplitTunnelScreen({super.key});
  @override
  State<TvSplitTunnelScreen> createState() => _TvSplitTunnelScreenState();
}

class _TvSplitTunnelScreenState extends State<TvSplitTunnelScreen> {
  List<Map<String, String>> _apps = [];
  Set<String> _selected = {};
  String _mode = NativeVpnService.splitTunnelModeExclude;
  bool _busy = true;
  bool _loaded = false;
  bool _connected = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<bool> _vpnActive() async {
    final awg = await NativeVpnService.getAmneziaWgStatus();
    final native = await NativeVpnService.getNativeConnectionStatus();
    if (awg == true || native == true) return true;
    if (awg == null || native == null) {
      throw StateError('VPN status is unavailable');
    }
    return false;
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _loaded = false;
      _error = null;
    });
    try {
      final apps = await NativeVpnService.getInstalledApps(strict: true);
      final packages =
          await NativeVpnService.getSplitTunnelExcludedApps(strict: true);
      final mode = await NativeVpnService.getSplitTunnelMode(strict: true);
      final active = await _vpnActive();
      final known = apps.map((a) => a['package']).toSet();
      // Preserve rules for packages hidden by package visibility or an OEM
      // launcher. They must remain visible and removable instead of vanishing.
      for (final p in packages.where((p) => !known.contains(p))) {
        apps.add({
          'package': p,
          'label': tvText(context, 'Недоступное приложение', 'Unavailable app')
        });
      }
      if (mounted)
        setState(() {
          _apps = apps;
          _selected = packages.toSet();
          _mode = mode;
          _connected = active;
          _loaded = true;
        });
    } catch (_) {
      if (mounted)
        setState(
          () => _error = tvText(
            context,
            'Не удалось загрузить настройки.',
            'Could not load settings.',
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_busy || _connected || !_loaded) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (await _vpnActive()) {
        if (mounted) setState(() => _connected = true);
        return;
      }
      await NativeVpnService.setSplitTunnelMode(_mode);
      await NativeVpnService.setSplitTunnelExcludedApps(
        _selected.toList()..sort(),
      );
      final savedMode = await NativeVpnService.getSplitTunnelMode(strict: true);
      final savedPackages =
          (await NativeVpnService.getSplitTunnelExcludedApps(strict: true))
              .toSet();
      if (savedMode != _mode ||
          savedPackages.length != _selected.length ||
          !savedPackages.containsAll(_selected)) {
        throw StateError('Settings were not persisted');
      }
      if (mounted) Navigator.pop(context);
    } catch (_) {
      if (mounted)
        setState(
          () => _error = tvText(
            context,
            'Настройки не сохранились. Попробуйте ещё раз.',
            'Settings were not saved. Please try again.',
          ),
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final locked = _busy || _connected || !_loaded;
    return TvPage(
      title: tvText(context, 'Исключения приложений', 'App exclusions'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_connected) ...[
            TvNotice(
              tvText(
                context,
                'Отключите VPN, чтобы изменить настройки.',
                'Disconnect VPN to change settings.',
              ),
            ),
            const SizedBox(height: 14),
          ],
          Row(
            children: [
              Expanded(
                child: _TvSplitMode(
                  label: tvText(
                    context,
                    'Выбранные обходят VPN',
                    'Selected apps bypass VPN',
                  ),
                  selected: _mode == NativeVpnService.splitTunnelModeExclude,
                  autofocus: true,
                  onPressed: locked
                      ? null
                      : () => setState(
                            () =>
                                _mode = NativeVpnService.splitTunnelModeExclude,
                          ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _TvSplitMode(
                  label: tvText(
                    context,
                    'Только выбранные через VPN',
                    'Only selected apps use VPN',
                  ),
                  selected: _mode == NativeVpnService.splitTunnelModeInclude,
                  onPressed: locked
                      ? null
                      : () => setState(
                            () =>
                                _mode = NativeVpnService.splitTunnelModeInclude,
                          ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            tvText(
              context,
              'Если ничего не выбрано, VPN работает для всех приложений.',
              'If no apps are selected, all apps use VPN.',
            ),
            style: const TextStyle(fontSize: 16, color: tvMuted),
          ),
          const SizedBox(height: 16),
          if (_error != null) ...[
            TvNotice(_error!, error: true),
            if (!_loaded) ...[
              const SizedBox(height: 12),
              TvButton(
                label: tvText(context, 'Повторить', 'Retry'),
                autofocus: true,
                onPressed: _busy ? null : _load,
              ),
            ],
            const SizedBox(height: 12),
          ],
          if (_busy) const LinearProgressIndicator(),
          Expanded(
            child: ListView.separated(
              itemCount: _apps.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final app = _apps[index];
                final package = app['package']!;
                final selected = _selected.contains(package);
                return _TvSplitApp(
                  key: ValueKey('tv-app-$package'),
                  packageName: package,
                  label: app['label'] ?? package,
                  selected: selected,
                  onPressed: locked
                      ? null
                      : () => setState(() {
                            if (selected) {
                              _selected.remove(package);
                            } else {
                              _selected.add(package);
                            }
                          }),
                );
              },
            ),
          ),
          const SizedBox(height: 16),
          TvButton(
            label: tvText(context, 'Сохранить', 'Save'),
            primary: true,
            onPressed: locked ? null : _save,
          ),
        ],
      ),
    );
  }
}

class _TvSplitMode extends StatelessWidget {
  const _TvSplitMode(
      {required this.label,
      required this.selected,
      required this.onPressed,
      this.autofocus = false});
  final String label;
  final bool selected, autofocus;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => TvRemoteControl(
      autofocus: autofocus,
      onPressed: onPressed,
      child: GraniSplitModeButton(
          label: label, selected: selected, onTap: onPressed));
}

class _TvSplitApp extends StatelessWidget {
  const _TvSplitApp(
      {super.key,
      required this.label,
      required this.packageName,
      required this.selected,
      required this.onPressed});
  final String label, packageName;
  final bool selected;
  final VoidCallback? onPressed;
  @override
  Widget build(BuildContext context) => TvRemoteControl(
      onPressed: onPressed,
      child: GraniSplitAppRow(
          label: label,
          packageName: packageName,
          selected: selected,
          onTap: onPressed));
}
