part of '../../services/vpn_service.dart';

/// Post-connect datapath commit, probe classification, and degraded-connectivity helpers for [VpnService].
extension VpnPostConnectCommitHelpers on VpnService {
  bool _hasActiveProxyTunneling() {
    final outbounds = (_cachedEffectiveOutbounds ?? '').toLowerCase();
    if (outbounds.isEmpty) return false;
    return outbounds.contains('proxy/') || outbounds.contains('->proxy');
  }

  String _classifyProbeFailure(String errorText) {
    if (errorText.isEmpty) return 'none';
    if (errorText.contains('unknownhost') ||
        errorText.contains('unable to resolve host') ||
        errorText.contains('name or service not known') ||
        errorText.contains('no address associated')) {
      return 'dns_error';
    }
    if (errorText.contains('ssl') ||
        errorText.contains('tls') ||
        errorText.contains('handshake')) {
      return 'tls_error';
    }
    if (errorText.contains('connection refused') ||
        errorText.contains('connect failed')) {
      return 'tcp_refused';
    }
    if (errorText.contains('timed out') || errorText.contains('timeout')) {
      return 'timeout';
    }
    if (errorText.contains('network is unreachable') ||
        errorText.contains('no route to host')) {
      return 'network_unreachable';
    }
    return 'other';
  }

  String _datapathLayerForEvent(String eventName) {
    final normalized = eventName.trim().toLowerCase();
    if (normalized.isEmpty) return 'unknown';
    if (normalized == 'runtime_fail') return 'runtime';
    if (normalized == 'tun_state' ||
        normalized.contains('tun2socks') ||
        normalized.contains('closed_pipe') ||
        normalized.contains('cleanup_tun')) {
      return 'tun2socks_bridge';
    }
    if (normalized.contains('xray')) return 'libxray';
    return 'native';
  }

  void _logDatapathCheckpoint({
    required String source,
    required String eventName,
    Map<String, dynamic>? payload,
  }) {
    final did = _deviceId;
    if (did == null) return;
    final serverId =
        _selectedServer != null ? int.tryParse(_selectedServer!.id) : null;
    final details = <String, dynamic>{
      'checkpoint_source': source,
      'checkpoint_event': eventName,
      'checkpoint_seq': ++_datapathCheckpointSeq,
      'datapath_layer': _datapathLayerForEvent(eventName),
      'tun_rx_bytes': _totalBytesReceived,
      'tun_tx_bytes': _totalBytesSent,
      'traffic_seen': _hasEverSeenTraffic,
      'public_ok': _postConnectPublicOk == true,
      'api_ok': _postConnectApiOk == true,
      'failed_probe_count': _postConnectFailedProbeCount,
      if (_lastConnectivityProbeAt != null)
        'probe_age_ms':
            DateTime.now().difference(_lastConnectivityProbeAt!).inMilliseconds,
      if (_lastRuntimeCorrelationId != null &&
          _lastRuntimeCorrelationId!.isNotEmpty)
        'runtime_correlation_id': _lastRuntimeCorrelationId,
      if (_cachedEffectiveOutbounds != null &&
          _cachedEffectiveOutbounds!.isNotEmpty)
        'effective_outbounds': _cachedEffectiveOutbounds,
    };
    if (payload != null && payload.isNotEmpty) {
      details.addAll(payload);
    }
    _connectionLogger.logConnectionStage(
      deviceId: did,
      protocol: _selectedProtocol.apiValue,
      stage: 'datapath_checkpoint',
      clientId: _clientId,
      serverId: serverId,
      connectionSessionId: _connectionSessionId,
      trigger: _connectionTrigger,
      extraDetails: details,
    );
  }

  void _resetPostConnectCommitState() {
    _postConnectCommitTimer?.cancel();
    _postConnectCommitTimer = null;
    _postConnectCommitLogged = false;
    _postConnectPublicOk = null;
    _postConnectApiOk = null;
    _postConnectConnectivityDegraded = false;
    _postConnectDegradedReason = null;
    _lastConnectivityProbeAt = null;
    _postConnectFirstFailedProbeAt = null;
    _postConnectFailedProbeCount = 0;
    _datapathCheckpointSeq = 0;
  }

  void _startPostConnectCommitWatch() {
    _resetPostConnectCommitState();
    if (_minimalVpnMode) {
      _postConnectCommitLogged = true;
      _log(
          'VpnService.minimal_mode: post-connect commit watchdog disabled; local tunnel stays connected unless user disconnects');
      return;
    }
    _postConnectCommitTimer = Timer(
      VpnService._postConnectCommitWindow,
      _maybeFinalizePostConnectCommit,
    );
  }

  bool _isStrictConnectivityCommitted() {
    final probeAt = _lastConnectivityProbeAt;
    final probeFresh = probeAt != null &&
        DateTime.now().difference(probeAt) <=
            VpnService._postConnectProbeFreshness;
    return _hasEverSeenTraffic &&
        probeFresh &&
        _postConnectPublicOk == true &&
        _postConnectApiOk == true;
  }

  bool _shouldAbortStrictConnectivityCommit() {
    final timerExpired = !(_postConnectCommitTimer?.isActive ?? false);
    if (!timerExpired) return false;
    // Never hard-abort when dataplane probe is already green.
    // API/DNS health can be transiently degraded right after connect.
    if (_postConnectPublicOk == true) return false;
    if (_postConnectApiOk == true && _hasEverSeenTraffic) return false;
    if (_hasEverSeenTraffic && _hasActiveProxyTunneling()) return false;
    final firstFailAt = _postConnectFirstFailedProbeAt;
    final retryWindowPassed = firstFailAt != null &&
        DateTime.now().difference(firstFailAt) >=
            VpnService._postConnectMinRetryWindow;
    return _postConnectFailedProbeCount >=
            VpnService._postConnectMinFailedProbeCount &&
        retryWindowPassed;
  }

  void _markPostConnectConnectivityDegraded({required String reason}) {
    _postConnectConnectivityDegraded = true;
    _postConnectDegradedReason = reason;
    _setError(
        'degraded_connectivity: public internet probe failed, API health and VPN traffic are ok.');
    _connectionLogger.logConnectionStage(
      deviceId: _deviceId!,
      protocol: _selectedProtocol.apiValue,
      stage: 'connected_degraded_retry',
      clientId: _clientId,
      serverId:
          _selectedServer != null ? int.tryParse(_selectedServer!.id) : null,
      connectionSessionId: _connectionSessionId,
      trigger: _connectionTrigger,
      extraDetails: {
        'reason': reason,
        'traffic_seen': _hasEverSeenTraffic,
        'public_ok': _postConnectPublicOk == true,
        'api_ok': _postConnectApiOk == true,
        'failed_probe_count': _postConnectFailedProbeCount,
        'action': 'keep_connected_retry_public_probe',
      },
    );
    _connectionLogger.scheduleFlushAfter(const Duration(seconds: 1));
    _notifyListenersFromHelper();
  }

  void _maybeFinalizePostConnectCommit() {
    if (_postConnectCommitLogged || !_isConnected || _deviceId == null) return;
    final serverId =
        _selectedServer != null ? int.tryParse(_selectedServer!.id) : null;
    final committed = _isStrictConnectivityCommitted();
    if (committed) {
      _postConnectCommitLogged = true;
      _connectionLogger.logConnectionSuccess(
        deviceId: _deviceId!,
        protocol: _selectedProtocol.apiValue,
        clientId: _clientId,
        serverId: serverId,
        connectionDurationMs: _connectionStartTime == null
            ? null
            : DateTime.now().difference(_connectionStartTime!).inMilliseconds,
        connectionSessionId: _connectionSessionId,
        trigger: _connectionTrigger,
        trafficVerified: true,
        connectionFlowType: _connectionFlowType.name,
      );
      _connectionLogger.logConnectionStage(
        deviceId: _deviceId!,
        protocol: _selectedProtocol.apiValue,
        stage: 'connected_validated',
        clientId: _clientId,
        serverId: serverId,
        connectionSessionId: _connectionSessionId,
        trigger: _connectionTrigger,
      );
      _connectionLogger.scheduleFlushAfter(const Duration(seconds: 1));
      return;
    }
    if ((_postConnectPublicOk == true) ||
        (_postConnectApiOk == true && _hasEverSeenTraffic) ||
        (_hasEverSeenTraffic && _hasActiveProxyTunneling())) {
      _markPostConnectConnectivityDegraded(
        reason: (_postConnectPublicOk == true)
            ? 'commit_window_expired_api_probe_failed_public_ok'
            : (_postConnectApiOk == true)
                ? 'commit_window_expired_public_probe_failed_api_ok_traffic_seen'
                : 'commit_window_expired_public_probe_failed_proxy_tunneling_seen',
      );
      return;
    }
    // Fail commit only after retry window with repeated failed probes.
    if (!_shouldAbortStrictConnectivityCommit()) return;
    _postConnectCommitLogged = true;
    final reasonClass = _classifyCommitFailureReason(
      publicOk: _postConnectPublicOk == true,
      apiOk: _postConnectApiOk == true,
      trafficSeen: _hasEverSeenTraffic,
    );
    _connectionLogger.logConnectionError(
      deviceId: _deviceId!,
      protocol: _selectedProtocol.apiValue,
      errorMessage: 'connectivity_commit_failed',
      errorCode: reasonClass,
      clientId: _clientId,
      serverId: serverId,
      errorDetails: _buildCommitFailureBundle(reasonClass)
        ..['retry_window_ms'] =
            VpnService._postConnectMinRetryWindow.inMilliseconds,
      connectionSessionId: _connectionSessionId,
      trigger: _connectionTrigger,
    );
    _connectionLogger.scheduleFlushAfter(const Duration(seconds: 1));
    if (_isConnected && !_isDisconnecting) {
      unawaited(_disconnectAfterConnectivityCommitFailure());
    }
  }

  void _scheduleMtuFallbackForDegradedConnectivity() {
    final next = _nextFallbackMtu(_lastNetworkType, _lastMtu);
    if (next == null || next == _lastMtu) return;
    _pendingMtuOverride = next;
    _pendingMtuReason = 'degraded_connectivity';
    _log(
      'VpnService: scheduling MTU fallback override next_connect_mtu=$next '
      '(current=$_lastMtu network=${_lastNetworkType ?? "unknown"})',
    );
  }

  Future<void> _disconnectAfterConnectivityCommitFailure() async {
    _scheduleMtuFallbackForDegradedConnectivity();
    final publicOk = _postConnectPublicOk == true;
    final apiOk = _postConnectApiOk == true;
    final reasonClass = _classifyCommitFailureReason(
      publicOk: publicOk,
      apiOk: apiOk,
      trafficSeen: _hasEverSeenTraffic,
    );
    final errorMessage = (!publicOk && apiOk)
        ? 'public_probe_timeout: публичный интернет недоступен через туннель.'
        : (!publicOk && !apiOk)
            ? 'node_unreachable: нет ответа от публичного интернета и API через туннель.'
            : 'connectivity_commit_failed: apply подтвержден, но трафик нестабилен.';
    _log(
      'VpnService: strict connectivity commit failed, keeping tunnel up '
      'session=${_connectionSessionId ?? "-"} reason_class=$reasonClass',
    );
    _setError(errorMessage);
    _log(
      'VpnService: connectivity_commit_gate stop suppressed by disconnect policy '
      'source=connectivity_commit_gate:$reasonClass',
    );
    _notifyListenersFromHelper();
  }

  String _classifyCommitFailureReason({
    required bool publicOk,
    required bool apiOk,
    required bool trafficSeen,
  }) {
    return VpnService.classifyCommitFailureReasonForTest(
      publicOk: publicOk,
      apiOk: apiOk,
      trafficSeen: trafficSeen,
    );
  }

  Map<String, dynamic> _buildCommitFailureBundle(String reasonClass) {
    return VpnService.buildCommitFailureBundleForTest(
      reasonClass: reasonClass,
      trafficSeen: _hasEverSeenTraffic,
      publicOk: _postConnectPublicOk == true,
      apiOk: _postConnectApiOk == true,
      failedProbeCount: _postConnectFailedProbeCount,
      connectionSessionId: _connectionSessionId,
      trigger: _connectionTrigger,
      effectiveOutbounds: _cachedEffectiveOutbounds,
      probeAt: _lastConnectivityProbeAt,
      runtimeDiagAt: _lastNativeRuntimeDiagAt,
      runtimeDiag: _lastNativeRuntimeDiag,
      now: DateTime.now(),
    );
  }
}
