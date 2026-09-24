import 'dart:convert';
import 'dart:io';

import '../core/storage/shared_preferences_holder.dart';

const windowsSplitTunnelModeExclude = 'exclude';
const windowsSplitTunnelModeInclude = 'include';

class WindowsSplitTunnelSettingsData {
  const WindowsSplitTunnelSettingsData({
    this.mode = windowsSplitTunnelModeExclude,
    this.processNames = const <String>[],
    this.directDomains = const <String>[],
  });

  final String mode;
  final List<String> processNames;
  final List<String> directDomains;

  bool get isIncludeMode => mode == windowsSplitTunnelModeInclude;

  bool get hasRules =>
      processNames.isNotEmpty || directDomains.isNotEmpty || isIncludeMode;
}

class WindowsSplitTunnelSettings {
  WindowsSplitTunnelSettings._();

  static const _modeKey = 'windows_split_tunnel_mode';
  static const _processesKey = 'windows_split_tunnel_process_names';
  static const _domainsKey = 'windows_split_tunnel_direct_domains';

  static Future<WindowsSplitTunnelSettingsData> load() async {
    final prefs = await getSharedPreferences();
    final rawMode = prefs.getString(_modeKey);
    final mode = rawMode == windowsSplitTunnelModeInclude
        ? windowsSplitTunnelModeInclude
        : windowsSplitTunnelModeExclude;
    return WindowsSplitTunnelSettingsData(
      mode: mode,
      processNames: _normalizedProcesses(prefs.getStringList(_processesKey)),
      directDomains: _normalizedDomains(prefs.getStringList(_domainsKey)),
    );
  }

  static Future<void> saveProcesses(Iterable<String> processNames) async {
    final prefs = await getSharedPreferences();
    await prefs.setStringList(
      _processesKey,
      _normalizedProcesses(processNames),
    );
  }

  static Future<void> saveMode(String mode) async {
    final prefs = await getSharedPreferences();
    await prefs.setString(
      _modeKey,
      mode == windowsSplitTunnelModeInclude
          ? windowsSplitTunnelModeInclude
          : windowsSplitTunnelModeExclude,
    );
  }

  static Future<void> saveDirectDomains(Iterable<String> domains) async {
    final prefs = await getSharedPreferences();
    await prefs.setStringList(_domainsKey, _normalizedDomains(domains));
  }

  /// Lists visible running desktop apps. A manual process entry is still
  /// supported in the UI because not every installed app is running.
  static Future<List<Map<String, String>>> listRunningApps() async {
    if (!Platform.isWindows) return const <Map<String, String>>[];
    const script = r'''
$ErrorActionPreference = "SilentlyContinue"
Get-Process |
  Where-Object { $_.MainWindowHandle -ne 0 -and $_.ProcessName } |
  Sort-Object ProcessName -Unique |
  ForEach-Object {
    [PSCustomObject]@{
      process = ($_.ProcessName + ".exe")
      label = $(if ($_.MainWindowTitle) { $_.MainWindowTitle } else { $_.ProcessName })
    } | ConvertTo-Json -Compress
  }
''';
    try {
      final result = await Process.run(
        'powershell.exe',
        const <String>[
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ],
      ).timeout(const Duration(seconds: 5));
      if (result.exitCode != 0) return _fallbackApps;

      final apps = <Map<String, String>>[];
      for (final line in result.stdout.toString().split(RegExp(r'[\r\n]+'))) {
        if (line.trim().isEmpty) continue;
        final decoded = jsonDecode(line);
        if (decoded is! Map) continue;
        final process = normalizeProcessName(decoded['process']?.toString());
        if (process.isEmpty) continue;
        final label = decoded['label']?.toString().trim();
        apps.add(<String, String>{
          'package': process,
          'label': label?.isNotEmpty == true ? label! : process,
        });
      }
      final byProcess = <String, Map<String, String>>{
        for (final app in <Map<String, String>>[..._fallbackApps, ...apps])
          app['package']!: app,
      };
      final resultApps = byProcess.values.toList()
        ..sort((a, b) => a['label']!.compareTo(b['label']!));
      return resultApps;
    } catch (_) {
      return _fallbackApps;
    }
  }

  static String normalizeProcessName(String? raw) {
    var value = raw?.trim().toLowerCase() ?? '';
    if (value.isEmpty) return '';
    value = value.replaceAll('\\', '/').split('/').last;
    if (!value.endsWith('.exe')) value = '$value.exe';
    if (!RegExp(r'^[a-z0-9_.+ -]+\.exe$').hasMatch(value)) return '';
    return value;
  }

  static List<String> _normalizedProcesses(Iterable<String>? values) {
    final result = <String>{};
    for (final value in values ?? const <String>[]) {
      final normalized = normalizeProcessName(value);
      if (normalized.isNotEmpty) result.add(normalized);
    }
    return result.toList()..sort();
  }

  static List<String> _normalizedDomains(Iterable<String>? values) {
    final result = <String>{};
    for (final value in values ?? const <String>[]) {
      final normalized = value.trim().toLowerCase();
      if (normalized.isNotEmpty) result.add(normalized);
    }
    return result.toList()..sort();
  }

  static const List<Map<String, String>> _fallbackApps = <Map<String, String>>[
    <String, String>{'package': 'chrome.exe', 'label': 'Google Chrome'},
    <String, String>{'package': 'msedge.exe', 'label': 'Microsoft Edge'},
    <String, String>{'package': 'firefox.exe', 'label': 'Mozilla Firefox'},
    <String, String>{'package': 'telegram.exe', 'label': 'Telegram'},
    <String, String>{'package': 'whatsapp.exe', 'label': 'WhatsApp'},
    <String, String>{'package': 'discord.exe', 'label': 'Discord'},
  ];
}
