/// Фасад транзакции CONNECT (BEGIN → PREPARE → tunnelReady → VERIFY → COMMIT).
///
/// Реализация: [VpnService] — методы `_connectStep1Prerequisites`, `_connectStep2GetConfig`,
/// `_connectStep3ApplyAndVerify`, этапы `_connectStageApplyProtocol`, `_connectStageVerify`,
/// `_connectStageOnSuccess`; состояния [VpnConnectionState.tunnelReady] / [VpnConnectionState.tunnelVerifying].
library;

export 'vpn_orchestration_spec.dart';
export 'vpn_orchestration_runtime.dart';
export 'network_policy_engine.dart';
export 'network_budget_controller.dart';
export 'control_plane_client.dart';
