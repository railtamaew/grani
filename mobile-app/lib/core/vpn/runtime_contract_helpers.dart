part of '../../services/vpn_service.dart';

/// Runtime contract validation helpers for [VpnService].
extension VpnRuntimeContractHelpers on VpnService {
  Map<String, dynamic>? _runtimeContractServerExpectation() {
    final rc = _lastRuntimeContract;
    if (rc == null) return null;
    final raw = rc['server_expectation'];
    if (raw is! Map) return null;
    return Map<String, dynamic>.from(raw);
  }

  Map<String, String>? _parseProxyOutbound(String effectiveOutbounds) {
    final parts = effectiveOutbounds
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    for (final part in parts) {
      final tokens = part.split('/');
      if (tokens.length < 4) continue;
      if (tokens[0].trim().toLowerCase() != 'proxy') continue;
      final addressPort = tokens[2].trim();
      final idx = addressPort.lastIndexOf(':');
      if (idx <= 0 || idx >= addressPort.length - 1) continue;
      return <String, String>{
        'protocol': tokens[1].trim().toLowerCase(),
        'host': addressPort.substring(0, idx).trim(),
        'port': addressPort.substring(idx + 1).trim(),
        'security': tokens[3].trim().toLowerCase(),
      };
    }
    return null;
  }

  String _normalizeContractSecurity(dynamic tlsRaw) {
    final tls = (tlsRaw ?? '').toString().trim().toLowerCase();
    if (tls.isEmpty) return 'none';
    if (tls == 'none') return 'none';
    if (tls == 'reality') return 'reality';
    return tls;
  }

  Future<void> _enforceRuntimeContractAgainstEffectiveOutbounds() async {
    if (!_isXrayProtocol || !Platform.isAndroid) return;
    final expectation = _runtimeContractServerExpectation();
    if (expectation == null || expectation.isEmpty) return;

    final expectedHost = (expectation['host'] ?? '').toString().trim();
    final expectedPort = (expectation['port'] ?? '').toString().trim();
    final expectedSecurity = _normalizeContractSecurity(expectation['tls']);
    final expectedProtocol = (_lastRuntimeContract?['protocol'] ?? '')
        .toString()
        .trim()
        .toLowerCase();

    String? effectiveOutbounds = _cachedEffectiveOutbounds;
    if (effectiveOutbounds == null || effectiveOutbounds.isEmpty) {
      for (var i = 0; i < 3; i++) {
        final fetched = await NativeVpnService.getEffectiveOutbounds();
        if (fetched != null && fetched.isNotEmpty) {
          effectiveOutbounds = fetched;
          _cachedEffectiveOutbounds = fetched;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    if (effectiveOutbounds == null || effectiveOutbounds.isEmpty) return;

    final proxy = _parseProxyOutbound(effectiveOutbounds);
    if (proxy == null) return;
    final mismatchFields = <String>[];
    final effectiveProtocol = proxy['protocol'] ?? '';
    final effectiveSecurity = proxy['security'] ?? '';
    final protocolMatches = expectedProtocol.isEmpty ||
        effectiveProtocol == expectedProtocol ||
        (expectedProtocol == 'reality' &&
            effectiveProtocol == 'vless' &&
            effectiveSecurity == 'reality');
    if (!protocolMatches) {
      mismatchFields.add('protocol');
    }
    if (expectedHost.isNotEmpty && proxy['host'] != expectedHost) {
      mismatchFields.add('host');
    }
    if (expectedPort.isNotEmpty && proxy['port'] != expectedPort) {
      mismatchFields.add('port');
    }
    if (expectedSecurity.isNotEmpty && proxy['security'] != expectedSecurity) {
      mismatchFields.add('tls');
    }
    if (mismatchFields.isEmpty) return;

    _log(
      'VpnService: runtime_contract_effective_mismatch '
      'correlation_id=${_lastRuntimeCorrelationId ?? "-"} fields=$mismatchFields',
    );
    if (_deviceId != null && _selectedServer != null) {
      _connectionLogger.logConnectionError(
        deviceId: _deviceId!,
        protocol: _selectedProtocol.apiValue,
        errorMessage: 'runtime_contract_effective_mismatch',
        errorCode: 'runtime_contract_mismatch',
        clientId: _clientId,
        serverId: int.tryParse(_selectedServer!.id),
        errorDetails: <String, dynamic>{
          'correlation_id': _lastRuntimeCorrelationId,
          'mismatch_fields': mismatchFields,
          'expected_protocol': expectedProtocol,
          'expected_host': expectedHost,
          'expected_port': expectedPort,
          'expected_tls': expectedSecurity,
          'effective_protocol': effectiveProtocol,
          'effective_host': proxy['host'],
          'effective_port': proxy['port'],
          'effective_tls': effectiveSecurity,
          'effective_outbounds': effectiveOutbounds,
        },
        connectionSessionId: _connectionSessionId,
        trigger: _connectionTrigger,
      );
    }
    throw Exception('Runtime contract mismatch after tunnel start');
  }
}
