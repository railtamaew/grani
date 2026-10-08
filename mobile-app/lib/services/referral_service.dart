import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../config/app_config.dart';
import '../core/storage/shared_preferences_holder.dart';

class ReferralFailure implements Exception {
  const ReferralFailure(this.code);
  final String code;
}

/// Pending invitation survives sign-in and process restarts. Rewards are server-owned.
class ReferralService {
  ReferralService._();
  @visibleForTesting
  ReferralService.test(http.Client client, {DateTime Function()? now})
    : _client = client,
      _now = now ?? DateTime.now;
  static final instance = ReferralService._();
  static const _resultKey = 'grani_referral_result_v2';
  static const _returnKey = 'grani_gift_return_v2';
  static const _pendingKey = 'grani_pending_referral_v1';
  static const _channel = MethodChannel('com.granivpn.mobile/referrals');
  final _proofSessions = <String>{};
  final _proofInFlight = <String>{};
  final _proofRetryAfter = <String, DateTime>{};
  final _claimInFlight = <String, Future<bool>>{};
  http.Client? _client;
  DateTime Function() _now = DateTime.now;

  static String? normalizeCode(String? raw) {
    final value = raw?.trim().toUpperCase() ?? '';
    return RegExp(r'^[A-Z0-9]{8,16}$').hasMatch(value) ? value : null;
  }

  static String? codeFromUri(Uri uri) {
    if (uri.scheme != 'https' || uri.host != 'granilink.com') return null;
    if (uri.pathSegments.length == 2 && uri.pathSegments.first == 'r') {
      return normalizeCode(uri.pathSegments[1]);
    }
    if (uri.path == '/open/invite') {
      return normalizeCode(uri.queryParameters['referral_code']);
    }
    return null;
  }

  Future<void> capture(String? raw) async {
    final code = normalizeCode(raw);
    if (code == null) return;
    final prefs = await getSharedPreferences();
    // First valid pending invitation wins; the server is the final authority.
    if (prefs.getString(_pendingKey) == null) {
      await prefs.setString(_pendingKey, code);
      await prefs.remove(_resultKey);
    }
    await prefs.setBool(_returnKey, true);
  }

  Future<String?> pendingCode() async =>
      (await getSharedPreferences()).getString(_pendingKey);

  /// Explicitly entered replacement; passive incoming links keep first-code policy.
  Future<void> replacePendingCode(String raw) async {
    final code = normalizeCode(raw);
    if (code == null) throw const ReferralFailure('invalid_code');
    final prefs = await getSharedPreferences();
    await prefs.setString(_pendingKey, code);
    await prefs.remove(_resultKey);
    await prefs.setBool(_returnKey, true);
  }

  Future<void> clearClaimNotice() async =>
      (await getSharedPreferences()).remove(_resultKey);

  String presentationAccount(String token) => _accountKey(token);

  Future<Map<String, dynamic>> _request(
    String token,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('${AppConfig.apiBaseUrl}/referrals/$path');
    final headers = {
      'Authorization': 'Bearer $token',
      'Content-Type': 'application/json',
    };
    final response =
        await (body == null
                ? (_client?.get(uri, headers: headers) ??
                      http.get(uri, headers: headers))
                : (_client?.post(
                        uri,
                        headers: headers,
                        body: jsonEncode(body),
                      ) ??
                      http.post(uri, headers: headers, body: jsonEncode(body))))
            .timeout(const Duration(seconds: 8));
    final value = jsonDecode(response.body);
    if (response.statusCode != 200) {
      // Production middleware wraps FastAPI's detail in error.message.
      final error = value is Map ? value['error'] : null;
      final code = value is Map
          ? value['detail'] ?? (error is Map ? error['message'] : null)
          : null;
      throw ReferralFailure(code is String ? code : 'unavailable');
    }
    return Map<String, dynamic>.from(value as Map);
  }

  Future<Map<String, dynamic>> summary(String token) =>
      _request(token, 'me?client_version=2');

  Future<Map<String, dynamic>> claim(String token, String raw) async {
    final code = normalizeCode(raw);
    if (code == null) throw const ReferralFailure('invalid_code');
    final result = await _request(
      token,
      'claim',
      body: {'code': code, 'client_version': 2},
    );
    _proofSessions.clear();
    await _rememberResult(token, 'applied');
    final prefs = await getSharedPreferences();
    if (prefs.getString(_pendingKey) == code) await prefs.remove(_pendingKey);
    return result;
  }

  Future<bool> claimPending(String? token) {
    if (token == null || token.isEmpty) return Future.value(false);
    final account = _accountKey(token);
    return _claimInFlight[account] ??= _claimPending(token).whenComplete(() {
      _claimInFlight.remove(account);
    });
  }

  Future<bool> _claimPending(String token) async {
    final code = await pendingCode();
    if (code == null) return false;
    try {
      await claim(token, code);
      return true;
    } on ReferralFailure catch (e) {
      await _rememberResult(token, e.code);
      if (const {
        'invalid_code',
        'self_referral',
        'already_claimed',
        'claim_window_expired',
        'existing_customer',
        'device_already_used',
      }.contains(e.code)) {
        final prefs = await getSharedPreferences();
        if (prefs.getString(_pendingKey) == code)
          await prefs.remove(_pendingKey);
      }
      return false;
    } catch (_) {
      await _rememberResult(token, 'network_error');
      return false;
    }
  }

  // JWT subject scopes only a local UI notice. Server authorization remains authoritative.
  String _accountKey(String token) {
    try {
      final payload =
          jsonDecode(
                utf8.decode(
                  base64Url.decode(base64Url.normalize(token.split('.')[1])),
                ),
              )
              as Map;
      return payload['sub'].toString();
    } catch (_) {
      return 'session';
    }
  }

  Future<void> _rememberResult(String token, String status) async {
    await (await getSharedPreferences()).setString(
      _resultKey,
      jsonEncode({'account': _accountKey(token), 'status': status}),
    );
  }

  Future<String?> claimNotice(String token) async {
    final raw = (await getSharedPreferences()).getString(_resultKey);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw) as Map;
      return value['account'] == _accountKey(token)
          ? value['status'] as String?
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<void> rememberGiftReturn() async =>
      (await getSharedPreferences()).setBool(_returnKey, true);

  Future<bool> needsGiftReturn() async =>
      (await getSharedPreferences()).getBool(_returnKey) ?? false;

  Future<void> finishGiftView() async =>
      (await getSharedPreferences()).remove(_returnKey);

  Future<Map<String, dynamic>> offer(String code) async {
    final normalized = normalizeCode(code);
    if (normalized == null) throw const ReferralFailure('invalid_code');
    final uri = Uri.parse(
      '${AppConfig.apiBaseUrl}/referrals/offer/$normalized',
    );
    final response = await (_client?.get(uri) ?? http.get(uri)).timeout(
      const Duration(seconds: 8),
    );
    if (response.statusCode != 200) throw const ReferralFailure('unavailable');
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  /// Native code owns both proofs so leaving this screen does not cancel them.
  Future<void> proveConnection({
    required String token,
    required String userId,
    required String deviceId,
    required int serverId,
    required String protocol,
    required String sessionId,
    required bool Function() stillConnected,
  }) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final key = '$userId:$sessionId';
    if (_proofSessions.contains(key) || _proofInFlight.contains(key)) return;
    final retryAfter = _proofRetryAfter[key];
    if (retryAfter != null && _now().isBefore(retryAfter)) return;
    _proofInFlight.add(key);
    try {
      debugPrint('[GraniReferralProof] attempt=start');
      await claimPending(token);
      final state = await summary(token);
      debugPrint(
        '[GraniReferralProof] summary=${state['received'] is Map ? state['received']['status'] : 'not_referred'}',
      );
      if (state['received'] is! Map ||
          state['received']['status'] != 'pending') {
        _proofSessions.add(key);
        return;
      }
      if (!stillConnected()) {
        debugPrint('[GraniReferralProof] attempt=session_changed');
        return;
      }
      final args = <String, dynamic>{
        'token': token,
        'protocol': protocol,
        'body': jsonEncode({
          'device_id': deviceId,
          'server_id': serverId,
          'session_id': sessionId,
        }),
      };
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'proveConnectionPair',
        args,
      );
      debugPrint('[GraniReferralProof] result=${result?['status']}');
      if (const {
        'rewarded',
        'monthly_limit',
        'ineligible',
        'expired',
        'not_referred',
      }.contains(result?['status']))
        _proofSessions.add(key);
    } catch (error) {
      debugPrint('[GraniReferralProof] error=${error.runtimeType}');
      // A temporary failure must not poison this connection for the whole session.
    } finally {
      _proofInFlight.remove(key);
      if (_proofSessions.contains(key)) {
        _proofRetryAfter.remove(key);
      } else {
        _proofRetryAfter[key] = _now().add(const Duration(seconds: 30));
      }
      if (_proofSessions.length > 100)
        _proofSessions.remove(_proofSessions.first);
      if (_proofRetryAfter.length > 100)
        _proofRetryAfter.remove(_proofRetryAfter.keys.first);
    }
  }
}
