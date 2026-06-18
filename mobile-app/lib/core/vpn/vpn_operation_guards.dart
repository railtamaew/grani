class ConnectGuardDecision {
  const ConnectGuardDecision.allow()
      : isAllowed = true,
        message = null,
        code = null;

  const ConnectGuardDecision.block(this.message, this.code) : isAllowed = false;

  final bool isAllowed;
  final String? message;
  final String? code;
}

class DisconnectGuardDecision {
  const DisconnectGuardDecision.allow()
      : isAllowed = true,
        code = null;

  const DisconnectGuardDecision.block(this.code) : isAllowed = false;

  final bool isAllowed;
  final String? code;
}

class VpnOperationGuards {
  const VpnOperationGuards._();

  static ConnectGuardDecision evaluateConnect({
    required bool isConnected,
    required bool isConnecting,
    required bool isResumeSyncGuardActive,
    required bool isDisconnectInProgress,
    required bool isVpnStatusSyncInFlight,
    required bool hasPendingDeviceLimit,
    String? pendingDeviceLimitMessage,
  }) {
    if (isConnected || isConnecting) {
      return const ConnectGuardDecision.block(
        'Подключение уже выполняется или VPN активен.',
        'already_connected_or_connecting',
      );
    }
    if (isResumeSyncGuardActive) {
      return const ConnectGuardDecision.block(
        'Синхронизируем состояние VPN. Повторите через секунду.',
        'resume_sync_guard',
      );
    }
    if (isDisconnectInProgress) {
      return const ConnectGuardDecision.block(
        'Выполняется отключение. Подождите и повторите.',
        'disconnect_in_progress',
      );
    }
    if (isVpnStatusSyncInFlight) {
      return const ConnectGuardDecision.block(
        'Идет проверка состояния VPN. Повторите через пару секунд.',
        'status_sync_in_flight',
      );
    }
    if (hasPendingDeviceLimit) {
      return ConnectGuardDecision.block(
        pendingDeviceLimitMessage ?? 'Достигнут лимит устройств.',
        'pending_device_limit',
      );
    }
    return const ConnectGuardDecision.allow();
  }

  static DisconnectGuardDecision evaluateDisconnect({
    required bool isUserReason,
    required bool isAllowedServiceReason,
    required bool isInBackground,
    required String source,
    required bool connectInProgress,
    required Duration? sinceConnected,
    required Duration debounceWindow,
  }) {
    if (!isUserReason && !isAllowedServiceReason) {
      return const DisconnectGuardDecision.block(
        'unsupported_disconnect_reason',
      );
    }
    if (isUserReason &&
        isInBackground &&
        source != 'ui_tap' &&
        source != 'quick_tile' &&
        source != 'system_panel') {
      return const DisconnectGuardDecision.block(
        'background_non_explicit_user_action',
      );
    }
    if (isUserReason && connectInProgress) {
      return const DisconnectGuardDecision.block('connect_in_progress');
    }
    if (isUserReason &&
        sinceConnected != null &&
        sinceConnected < debounceWindow) {
      return const DisconnectGuardDecision.block('post_connect_window');
    }
    return const DisconnectGuardDecision.allow();
  }
}
