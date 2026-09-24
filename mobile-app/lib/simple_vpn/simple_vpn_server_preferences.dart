import 'dart:convert';
import '../core/cache/cache_service.dart';

/// Device-local server choices, isolated by signed-in account.
class SimpleVpnServerPreferences {
  SimpleVpnServerPreferences._(this.scope, this.selectedId, this.manual,
      this.successfulId, this.successfulAddress);

  final String scope;
  final int? selectedId;
  final bool manual;
  final int? successfulId;
  final String? successfulAddress;
  static final _cache = CacheService();
  static Future<void> _writes = Future<void>.value();
  static const legacySelectionKey = 'simple_vpn_selected_server_id_v1';
  static const _legacyOwnerKey = 'simple_vpn_legacy_selection_owner_v1';

  static Future<String> _scope() async {
    final value = (await _cache.getString('user_id'))?.trim();
    return value == null || value.isEmpty ? 'anonymous' : value;
  }

  static Future<void> waitForPendingWrites() => _writes;

  static Map<String, dynamic> _decode(String? raw) {
    try {
      final value = raw == null ? null : jsonDecode(raw);
      return value is Map<String, dynamic> ? value : {};
    } catch (_) {
      return {};
    }
  }

  static int? _id(Object? value) {
    final id = int.tryParse(value?.toString() ?? '');
    return id != null && id > 0 ? id : null;
  }

  static Future<SimpleVpnServerPreferences> load() async {
    await _writes;
    final scope = await _scope();
    final selection =
        _decode(await _cache.getString('simple_vpn_selection_v2:$scope'));
    var selectedId = _id(selection['server_id']);
    var manual = selectedId != null && selection['manual'] == true;
    if (selection.isEmpty) {
      final owner = await _cache.getString(_legacyOwnerKey);
      if (owner == null || owner == scope) {
        selectedId = _id(await _cache.getString(legacySelectionKey));
        // Older builds cannot distinguish an explicit choice from a default.
        // Preserve the existing choice once on upgrade, but never share it
        // with a different account. New installations start in automatic mode.
        manual = selectedId != null;
        if (owner == null) await _cache.setString(_legacyOwnerKey, scope);
      }
    }
    final success = _decode(
        await _cache.getString('simple_vpn_successful_server_v1:$scope'));
    return SimpleVpnServerPreferences._(
        scope,
        selectedId,
        manual,
        _id(success['server_id']),
        success['address'] is String ? success['address'] as String : null);
  }

  Future<void> _write(Future<void> Function() action) {
    final next = _writes.then((_) async {
      if (await _scope() == scope) await action();
    });
    _writes = next.catchError((Object _) {});
    return _writes;
  }

  Future<void> saveSelection(int id, {required bool manual}) =>
      _write(() async {
        await _cache.setString('simple_vpn_selection_v2:$scope',
            jsonEncode({'server_id': id, 'manual': manual}));
        await _cache.setString(legacySelectionKey, id.toString());
      });

  Future<void> saveSuccessfulServer(int id, String address) => _write(() async {
        await _cache.setString('simple_vpn_successful_server_v1:$scope',
            jsonEncode({'server_id': id, 'address': address}));
      });
}
