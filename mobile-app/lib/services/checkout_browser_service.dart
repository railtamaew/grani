import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// A browser dismissal is navigation, never a payment result.
class CheckoutBrowserService {
  CheckoutBrowserService._(this._channel, this._android);
  static final instance = CheckoutBrowserService._(
      const MethodChannel('com.granivpn.mobile/checkout_browser'),
      Platform.isAndroid);
  @visibleForTesting
  factory CheckoutBrowserService.forTesting(MethodChannel channel) =>
      CheckoutBrowserService._(channel, true);

  final MethodChannel _channel;
  final bool _android;
  final _closed = StreamController<void>.broadcast();
  bool _active = false;
  bool _registered = false;
  bool get isActive => _active;
  Stream<void> get closed => _closed.stream;

  Future<bool> canLaunch() async {
    if (_active) return false;
    if (!_android) return true;
    try {
      return await _channel
              .invokeMethod<bool>('isActive')
              .timeout(const Duration(seconds: 3)) ==
          false;
    } catch (_) {
      return false;
    }
  }

  Future<bool> open(Uri uri) async {
    if (_active) return false;
    if (!_android) return launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!_registered) {
      _registered = true;
      _channel.setMethodCallHandler((call) async {
        if (call.method == 'closed' && _active) {
          _active = false;
          _closed.add(null);
        }
      });
    }
    _active = true;
    try {
      final opened = await _channel.invokeMethod<bool>(
          'open', {'url': uri.toString()}).timeout(const Duration(seconds: 5));
      if (opened != true) _active = false;
      return opened == true;
    } catch (_) {
      _active = false;
      return false;
    }
  }

  @visibleForTesting
  Future<void> disposeForTesting() async {
    if (_registered) _channel.setMethodCallHandler(null);
    await _closed.close();
  }
}
