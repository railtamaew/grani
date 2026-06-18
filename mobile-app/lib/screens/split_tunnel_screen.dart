import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import '../services/native_vpn_service.dart';
import '../widgets/split_tunnel/split_tunnel_ui_kit.dart';
import '../widgets/snackbar_utils.dart';
import '../widgets/info_banner.dart';
import '../l10n/app_localizations.dart';
import '../l10n/l10n.dart';

enum _SplitTunnelPresetId {
  banks,
  gov,
  maps,
  messengers,
  video,
  games,
}

String _splitTunnelPresetLabel(AppLocalizations l10n, _SplitTunnelPresetId id) {
  switch (id) {
    case _SplitTunnelPresetId.banks:
      return l10n.splitTunnelPresetBanks;
    case _SplitTunnelPresetId.gov:
      return l10n.splitTunnelPresetGov;
    case _SplitTunnelPresetId.maps:
      return l10n.splitTunnelPresetMaps;
    case _SplitTunnelPresetId.messengers:
      return l10n.splitTunnelPresetMessengers;
    case _SplitTunnelPresetId.video:
      return l10n.splitTunnelPresetVideo;
    case _SplitTunnelPresetId.games:
      return l10n.splitTunnelPresetGames;
  }
}

/// Экран выбора приложений, работающих в обход VPN (split tunnel).
/// Изменения применяются при следующем подключении VPN.
class SplitTunnelScreen extends StatefulWidget {
  const SplitTunnelScreen({super.key});

  @override
  State<SplitTunnelScreen> createState() => _SplitTunnelScreenState();
}

class _SplitTunnelScreenState extends State<SplitTunnelScreen> {
  List<Map<String, String>> _apps = [];
  Set<String> _selectedPackages = {};
  List<String> _directDomains = [];
  String _mode = NativeVpnService.splitTunnelModeExclude;
  bool _isLoading = true;
  String _searchQuery = '';
  int _activeTabIndex = 0;
  final TextEditingController _domainController = TextEditingController();

  /// Сообщение о переподключении VPN — только на этом экране (не через ScaffoldMessenger).
  String? _reconnectInfoMessage;
  bool _reconnectInfoVisible = false;

  static const List<_PresetGroup> _presetGroups = [
    _PresetGroup(
      id: _SplitTunnelPresetId.banks,
      icon: Icons.account_balance_outlined,
      packages: [
        'ru.sberbankmobile',
        'com.idamob.tinkoff.android',
        'ru.vtb24.mobile',
        'com.alfabank.mobile',
      ],
    ),
    _PresetGroup(
      id: _SplitTunnelPresetId.gov,
      icon: Icons.badge_outlined,
      packages: [
        'ru.gov.services.app',
        'ru.gosuslugi',
        'ru.mos.pgu',
      ],
    ),
    _PresetGroup(
      id: _SplitTunnelPresetId.maps,
      icon: Icons.map_outlined,
      packages: [
        'ru.yandex.yandexmaps',
        'com.google.android.apps.maps',
        'com.mapswithme.maps.pro',
        'com.didi.rider',
      ],
    ),
    _PresetGroup(
      id: _SplitTunnelPresetId.messengers,
      icon: Icons.forum_outlined,
      packages: [
        'org.telegram.messenger',
        'com.whatsapp',
        'org.thunderdog.challegram',
        'com.discord',
      ],
    ),
    _PresetGroup(
      id: _SplitTunnelPresetId.video,
      icon: Icons.ondemand_video_outlined,
      packages: [
        'org.videolan.vlc',
        'com.google.android.youtube',
        'com.netflix.mediaclient',
        'com.ss.android.ugc.trill',
      ],
    ),
    _PresetGroup(
      id: _SplitTunnelPresetId.games,
      icon: Icons.sports_esports_outlined,
      packages: [
        'com.supercell.clashofclans',
        'com.tencent.ig',
        'com.activision.callofduty.shooter',
        'com.mobile.legends',
      ],
    ),
  ];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _domainController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!Platform.isAndroid) {
      setState(() => _isLoading = false);
      return;
    }
    setState(() => _isLoading = true);
    try {
      final apps = await NativeVpnService.getInstalledApps();
      final selected = await NativeVpnService.getSplitTunnelExcludedApps();
      final mode = await NativeVpnService.getSplitTunnelMode();
      final domains = await NativeVpnService.getSplitTunnelDirectDomains();
      if (mounted) {
        setState(() {
          _apps = apps;
          _selectedPackages = selected.toSet();
          _mode = mode;
          _directDomains = domains;
          _isLoading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _notifyReconnectHintIfNeeded({String? changeMessage}) async {
    final connectedNow = await NativeVpnService.getAmneziaWgStatus();
    if (!mounted) return;
    final l10n = context.l10n;

    final reconnectMessage = connectedNow == true
        ? l10n.splitTunnelReconnectConnected
        : l10n.splitTunnelReconnectDisconnected;
    final message = changeMessage == null
        ? reconnectMessage
        : '$changeMessage\n$reconnectMessage';
    _showReconnectInfoBanner(message);
  }

  void _dismissReconnectInfoBanner() {
    if (!mounted) return;
    setState(() {
      _reconnectInfoVisible = false;
      _reconnectInfoMessage = null;
    });
  }

  void _showReconnectInfoBanner(String message) {
    if (!mounted) return;
    setState(() {
      _reconnectInfoMessage = message;
      _reconnectInfoVisible = true;
    });
  }

  Future<void> _toggleApp(String package) async {
    if (!Platform.isAndroid) return;
    final newSet = Set<String>.from(_selectedPackages);
    final wasSelected = newSet.contains(package);
    if (wasSelected) {
      newSet.remove(package);
    } else {
      newSet.add(package);
    }
    setState(() => _selectedPackages = newSet);
    await NativeVpnService.setSplitTunnelExcludedApps(newSet.toList());
    await _notifyReconnectHintIfNeeded(
      changeMessage: wasSelected
          ? context.l10n.splitTunnelAppRemoved
          : context.l10n.splitTunnelAppAdded,
    );
  }

  Future<void> _toggleMode() async {
    if (!Platform.isAndroid) return;
    final newMode = _mode == NativeVpnService.splitTunnelModeExclude
        ? NativeVpnService.splitTunnelModeInclude
        : NativeVpnService.splitTunnelModeExclude;
    setState(() => _mode = newMode);
    await NativeVpnService.setSplitTunnelMode(newMode);
    await _notifyReconnectHintIfNeeded(
      changeMessage: newMode == NativeVpnService.splitTunnelModeExclude
          ? context.l10n.splitTunnelModeExcludeChanged
          : context.l10n.splitTunnelModeIncludeChanged,
    );
  }

  Future<void> _addDomain(String domain) async {
    if (!Platform.isAndroid) return;
    final d = _normalizeDirectDomain(domain);
    if (d.isEmpty || _directDomains.contains(d)) return;
    final newList = List<String>.from(_directDomains)..add(d);
    setState(() {
      _directDomains = newList;
      _domainController.clear();
    });
    await NativeVpnService.setSplitTunnelDirectDomains(newList);
    await _notifyReconnectHintIfNeeded(
        changeMessage: context.l10n.splitTunnelDomainAdded);
  }

  String _normalizeDirectDomain(String raw) {
    var value = raw.trim().toLowerCase();
    if (value.contains('://')) {
      value = value.split('://').last;
    }
    value = value
        .split('/')
        .first
        .split('?')
        .first
        .split('#')
        .first
        .split('@')
        .last
        .split(':')
        .first
        .trim();
    while (value.startsWith('.')) {
      value = value.substring(1);
    }
    while (value.endsWith('.')) {
      value = value.substring(0, value.length - 1);
    }
    final wildcard = value.startsWith('*.');
    final host = wildcard ? value.substring(2) : value;
    if (host.isEmpty || !host.contains('.')) return '';
    final labels = host.split('.');
    final valid = labels.every((label) {
      if (label.isEmpty || label.length > 63) return false;
      if (label.startsWith('-') || label.endsWith('-')) return false;
      return RegExp(r'^[a-z0-9-]+$').hasMatch(label);
    });
    if (!valid) return '';
    return wildcard ? '*.$host' : host;
  }

  Future<void> _removeDomain(String domain) async {
    if (!Platform.isAndroid) return;
    final newList = _directDomains.where((x) => x != domain).toList();
    setState(() => _directDomains = newList);
    await NativeVpnService.setSplitTunnelDirectDomains(newList);
    await _notifyReconnectHintIfNeeded(
        changeMessage: context.l10n.splitTunnelDomainRemoved);
  }

  Future<void> _addPreset(_PresetGroup group) async {
    final l10n = context.l10n;
    final label = _splitTunnelPresetLabel(l10n, group.id);
    final installed =
        _apps.map((a) => a['package']).whereType<String>().toSet();
    final current = Set<String>.from(_selectedPackages);
    final matched = group.packages.where((p) => installed.contains(p)).toSet();
    if (matched.isEmpty) {
      if (!mounted) return;
      showErrorSnackBar(context, l10n.splitTunnelPresetNoApps(label));
      return;
    }

    final toAdd = matched.where((p) => !current.contains(p)).toSet();
    if (toAdd.isEmpty) {
      if (!mounted) return;
      showInfoSnackBar(context, l10n.splitTunnelPresetGroupAlreadyAdded(label));
      return;
    }

    final newSet = Set<String>.from(_selectedPackages)..addAll(toAdd);
    setState(() => _selectedPackages = newSet);
    await NativeVpnService.setSplitTunnelExcludedApps(newSet.toList());
    await _notifyReconnectHintIfNeeded(
      changeMessage: l10n.splitTunnelPresetGroupAddedApps(label, toAdd.length),
    );
  }

  List<Map<String, String>> get _filteredApps {
    if (_searchQuery.isEmpty) return _apps;
    final q = _searchQuery.toLowerCase();
    return _apps.where((a) {
      final label = (a['label'] ?? '').toLowerCase();
      final pkg = (a['package'] ?? '').toLowerCase();
      return label.contains(q) || pkg.contains(q);
    }).toList();
  }

  bool _isPresetFullySelected(_PresetGroup group) {
    final installed =
        _apps.map((a) => a['package']).whereType<String>().toSet();
    final matched = group.packages.where(installed.contains).toList();
    if (matched.isEmpty) return false;
    return matched.every(_selectedPackages.contains);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    if (!Platform.isAndroid) {
      return Scaffold(
        backgroundColor: const Color(0xFFF7F9FA),
        appBar: AppBar(
          backgroundColor: const Color(0xFFF7F9FA),
          surfaceTintColor: Colors.transparent,
          centerTitle: true,
          title: Text(
            l10n.splitTunnelTitle,
            style: GraniTheme.bodyMedium.copyWith(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: GraniTheme.primaryText,
            ),
          ),
        ),
        body: Center(
          child: Text(l10n.splitTunnelAndroidOnly),
        ),
      );
    }

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
        backgroundColor: const Color(0xFFF7F9FA),
        appBar: AppBar(
          systemOverlayStyle: const SystemUiOverlayStyle(
            statusBarColor: Color(0xFFF7F9FA),
            statusBarIconBrightness: Brightness.dark,
            statusBarBrightness: Brightness.light,
          ),
          centerTitle: true,
          title: Text(
            l10n.splitTunnelTitle,
            style: GraniTheme.bodyMedium.copyWith(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              color: GraniTheme.primaryText,
            ),
          ),
          backgroundColor: const Color(0xFFF7F9FA),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: GraniTheme.primaryText),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              decoration: const BoxDecoration(
                gradient: GraniTheme.startScreenBackgroundGradient,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
                    child: GraniSegmentedChoice(
                      firstLabel: l10n.splitTunnelTabApps,
                      secondLabel: l10n.splitTunnelTabDomains,
                      firstSelected: _activeTabIndex == 0,
                      onFirstTap: _activeTabIndex == 0
                          ? null
                          : () => setState(() => _activeTabIndex = 0),
                      onSecondTap: _activeTabIndex == 1
                          ? null
                          : () => setState(() => _activeTabIndex = 1),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                    child: Text(
                      _mode == NativeVpnService.splitTunnelModeExclude
                          ? l10n.splitTunnelModeHintExclude
                          : l10n.splitTunnelModeHintInclude,
                      style: GraniTheme.bodySmall.copyWith(
                        color: GraniTheme.secondaryText,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Row(
                      children: [
                        Expanded(
                          child: GraniSplitModeButton(
                            label: l10n.splitTunnelModeExclude,
                            selected: _mode ==
                                NativeVpnService.splitTunnelModeExclude,
                            icon: Icons.alt_route,
                            onTap:
                                _mode == NativeVpnService.splitTunnelModeExclude
                                    ? null
                                    : _toggleMode,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GraniSplitModeButton(
                            label: l10n.splitTunnelModeInclude,
                            selected: _mode ==
                                NativeVpnService.splitTunnelModeInclude,
                            icon: Icons.shield_outlined,
                            onTap:
                                _mode == NativeVpnService.splitTunnelModeInclude
                                    ? null
                                    : _toggleMode,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: SizedBox(
                      height: 40,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _presetGroups.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        physics: const BouncingScrollPhysics(),
                        itemBuilder: (context, i) {
                          final group = _presetGroups[i];
                          final presetLabel =
                              _splitTunnelPresetLabel(context.l10n, group.id);
                          return _PresetChip(
                            group: group,
                            localizedLabel: presetLabel,
                            onTap: _addPreset,
                            isFullySelected: _isPresetFullySelected(group),
                          );
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      l10n.splitTunnelPresetsHint,
                      style: GraniTheme.bodySmall.copyWith(
                        fontSize: 12,
                        color: GraniTheme.secondaryText,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (_activeTabIndex == 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 0),
                      child: Container(
                        decoration: GraniTheme.graniSurfaceDecoration(
                          radius: 18,
                          shadows: GraniTheme.surfaceControlShadow,
                        ),
                        child: TextField(
                          decoration: InputDecoration(
                            hintText: l10n.splitTunnelSearchApps,
                            prefixIcon: const Icon(Icons.search, size: 22),
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                          ),
                          onChanged: (v) => setState(() => _searchQuery = v),
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: _activeTabIndex == 0
                        ? _isLoading
                            ? const Center(child: CircularProgressIndicator())
                            : _filteredApps.isEmpty
                                ? Center(
                                    child: Text(
                                      _searchQuery.isEmpty
                                          ? l10n.splitTunnelNoApps
                                          : l10n.splitTunnelNothingFound,
                                      style: TextStyle(
                                          color: GraniTheme.secondaryText),
                                    ),
                                  )
                                : ListView.builder(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 16, vertical: 8),
                                    itemCount: _filteredApps.length,
                                    itemBuilder: (context, i) {
                                      final app = _filteredApps[i];
                                      final pkg = app['package'] ?? '';
                                      final label = app['label'] ?? pkg;
                                      final selected =
                                          _selectedPackages.contains(pkg);
                                      return Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 8),
                                        child: GraniSplitAppRow(
                                          label: label,
                                          packageName: pkg,
                                          selected: selected,
                                          onTap: () => _toggleApp(pkg),
                                        ),
                                      );
                                    },
                                  )
                        : _DomainSplitView(
                            domains: _directDomains,
                            controller: _domainController,
                            onAddDomain: _addDomain,
                            onRemoveDomain: _removeDomain,
                          ),
                  ),
                ],
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: InfoBanner(
                  message: _reconnectInfoMessage ?? '',
                  visible: _reconnectInfoVisible,
                  onDismiss: _dismissReconnectInfoBanner,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DomainSplitView extends StatelessWidget {
  final List<String> domains;
  final TextEditingController controller;
  final void Function(String) onAddDomain;
  final void Function(String) onRemoveDomain;

  const _DomainSplitView({
    required this.domains,
    required this.controller,
    required this.onAddDomain,
    required this.onRemoveDomain,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: GraniTheme.graniSurfaceDecoration(
            radius: 18,
            shadows: GraniTheme.surfaceControlShadow,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: GraniTheme.infoBannerForeground,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.splitTunnelDomainsHint,
                  style:
                      TextStyle(color: GraniTheme.secondaryText, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Container(
                decoration: GraniTheme.graniSurfaceDecoration(
                  radius: 18,
                  shadows: GraniTheme.surfaceControlShadow,
                ),
                child: TextField(
                  controller: controller,
                  decoration: InputDecoration(
                    hintText: l10n.splitTunnelSearchDomains,
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                  onSubmitted: (v) {
                    if (v.trim().isNotEmpty) onAddDomain(v);
                  },
                ),
              ),
            ),
            const SizedBox(width: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: controller,
              builder: (_, value, __) => Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: value.text.trim().isEmpty
                      ? null
                      : () => onAddDomain(value.text),
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: GraniTheme.graniSurfaceDecoration(
                      radius: 18,
                      shadows: GraniTheme.surfaceControlShadow,
                    ),
                    child: Icon(
                      Icons.add,
                      color: value.text.trim().isEmpty
                          ? GraniTheme.secondaryText
                          : GraniTheme.primaryText,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (domains.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                l10n.splitTunnelNoDomains,
                style: TextStyle(color: GraniTheme.secondaryText),
              ),
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: domains
                .map(
                  (d) => Container(
                    decoration: GraniTheme.graniSurfaceDecoration(
                      radius: 16,
                      shadows: GraniTheme.surfaceControlShadow,
                    ),
                    child: Chip(
                      label: Text(d),
                      deleteIcon: const Icon(Icons.close, size: 18),
                      onDeleted: () => onRemoveDomain(d),
                      backgroundColor: Colors.transparent,
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}

class _PresetGroup {
  final _SplitTunnelPresetId id;
  final IconData icon;
  final List<String> packages;

  const _PresetGroup({
    required this.id,
    required this.icon,
    required this.packages,
  });
}

class _PresetChip extends StatelessWidget {
  final _PresetGroup group;
  final String localizedLabel;
  final void Function(_PresetGroup) onTap;
  final bool isFullySelected;

  const _PresetChip({
    required this.group,
    required this.localizedLabel,
    required this.onTap,
    required this.isFullySelected,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onTap(group),
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: GraniTheme.graniSurfaceDecoration(
            radius: 16,
            borderColor: isFullySelected
                ? GraniTheme.buttonPrimary
                : GraniTheme.surfaceControlBorder,
            borderOpacity: isFullySelected ? 0.3 : 0.82,
            shadows: GraniTheme.surfaceControlShadow,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                group.icon,
                size: 16,
                color: GraniTheme.primaryText,
              ),
              const SizedBox(width: 6),
              Text(
                '$localizedLabel (${group.packages.length})',
                style: GraniTheme.bodySmall.copyWith(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: GraniTheme.primaryText,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
