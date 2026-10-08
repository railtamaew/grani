import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Detect the device form factor, rather than treating a large phone as a TV.
class TvPlatform {
  TvPlatform._();

  static bool _isTv = const bool.fromEnvironment('GRANI_TV');
  static bool get isTv => _isTv;

  static Future<void> initialize() async {
    if (_isTv || kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return;
    }
    try {
      _isTv = await const MethodChannel(
            'com.granivpn.mobile/form_factor',
          ).invokeMethod<bool>('isTv').timeout(const Duration(seconds: 2)) ??
          false;
    } catch (_) {
      _isTv = false;
    }
  }
}
