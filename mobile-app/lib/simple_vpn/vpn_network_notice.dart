import 'dart:async';

enum VpnNetworkNotice { noNetwork, internetUnconfirmed, vpnUnconfirmed, signIn }

/// Diagnostic UI only: never changes the tunnel, catalog, or selected profile.
/// Two completed observations on the same underlying network are required.
class VpnNetworkNoticeMonitor {
  VpnNetworkNoticeMonitor({
    required this.check,
    required this.onChanged,
    this.initialDelay = const Duration(seconds: 8),
    this.confirmationDelay = const Duration(seconds: 3),
    this.checkTimeout = const Duration(seconds: 12),
    this.noticeLifetime = const Duration(seconds: 20),
  });

  final Future<Map<String, dynamic>> Function() check;
  final void Function() onChanged;
  final Duration initialDelay, confirmationDelay, checkTimeout, noticeLifetime;
  Timer? _timer;
  int _generation = 0;
  bool _disposed = false;
  bool _inFlight = false;
  VpnNetworkNotice? notice;
  bool get isRunning => _inFlight || (_timer?.isActive ?? false);

  void start({bool immediately = false}) {
    reset();
    final generation = _generation;
    _timer = Timer(immediately ? Duration.zero : initialDelay,
        () => unawaited(_observe(generation, null)));
  }

  void reset() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    if (notice != null) {
      notice = null;
      if (!_disposed) onChanged();
    }
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> _observe(int generation, Map<String, dynamic>? first) async {
    if (!_current(generation)) return;
    // A cancelled native operation may still be finishing. Do not overlap it.
    if (_inFlight) return;
    _inFlight = true;
    Map<String, dynamic> result;
    try {
      result = await check().timeout(checkTimeout);
    } catch (_) {
      return; // Diagnostics unavailable is unknown, never "no internet".
    } finally {
      _inFlight = false;
    }
    if (!_current(generation) || result['check_completed'] != true) return;
    if (first == null) {
      _timer = Timer(
          confirmationDelay, () => unawaited(_observe(generation, result)));
      return;
    }
    notice = classify(first, result);
    if (notice == null) return;
    onChanged();
    // Do not retain a claim indefinitely after a later network change.
    _timer = Timer(noticeLifetime, () {
      if (_current(generation)) reset();
    });
  }

  static VpnNetworkNotice? classify(
      Map<String, dynamic> first, Map<String, dynamic> second) {
    if (first['check_completed'] != true || second['check_completed'] != true) {
      return null;
    }
    final network = first['network_id'];
    if (network == null || network != second['network_id']) return null;
    if (first['network_available'] == false &&
        second['network_available'] == false &&
        network == 'none') {
      return VpnNetworkNotice.noNetwork;
    }
    if (first['network_available'] != true ||
        second['network_available'] != true) return null;
    if ((first['probe_successes'] is int && first['probe_successes'] > 0) ||
        (second['probe_successes'] is int && second['probe_successes'] > 0) ||
        first['validated'] == true ||
        second['validated'] == true) {
      return VpnNetworkNotice.vpnUnconfirmed;
    }
    if (first['network_type'] == 'wifi' &&
        second['network_type'] == 'wifi' &&
        first['captive_portal'] == true &&
        second['captive_portal'] == true &&
        first['probe_successes'] == 0 &&
        second['probe_successes'] == 0) {
      return VpnNetworkNotice.signIn;
    }
    if (first['probe_attempts'] == 2 &&
        second['probe_attempts'] == 2 &&
        first['probe_successes'] == 0 &&
        second['probe_successes'] == 0) {
      return VpnNetworkNotice.internetUnconfirmed;
    }
    return null;
  }

  void dispose() {
    _disposed = true;
    reset();
  }
}
