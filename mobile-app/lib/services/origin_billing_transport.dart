import 'dart:convert';
import 'package:flutter/services.dart';

/// Only billing-region requests use the physical Android network.
/// No process-wide route change, third-party IP lookup, or token persistence.
class OriginBillingTransport {
  static const _channel = MethodChannel('com.granivpn.mobile/billing_origin');

  static Future<Map<String, dynamic>> post(
      String path, Map<String, dynamic> body, String token) async {
    final value = await _channel.invokeMethod<String>('post', {
      'path': path,
      'body': jsonEncode(body),
      'token': token,
    }).timeout(const Duration(seconds: 15));
    final decoded = jsonDecode(value ?? '');
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid region response');
    }
    return decoded;
  }
}
