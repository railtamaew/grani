# VPN Core Architecture Contract

This document defines the current layering for VPN connect/disconnect flow.
Follow it when changing code in `lib/services/vpn_service.dart` and `lib/core/vpn/*`.

## Goals

- Keep `VpnService` as the orchestration facade and state owner.
- Keep heavy operational logic in dedicated executors/helpers.
- Avoid returning to one giant method with mixed responsibilities.

## Current Layering

- `services/vpn_service.dart`
  - Public API and high-level orchestration.
  - Owns mutable state (`_currentState`, `_connectionSessionId`, flags, caches).
  - Delegates heavy logic to part files.

- `core/vpn/vpn_operation_guards.dart`
  - Pure guard decisions for connect/disconnect preconditions.
  - No side effects.

- `core/vpn/connect_attempt_executor.dart`
  - Connect retry loop executor (`_ConnectAttemptExecutor`).
  - Runs stage pipeline with retries, timeouts, telemetry and failure paths.

- `core/vpn/disconnect_pipeline_executor.dart`
  - Disconnect operation executor (`_DisconnectPipelineExecutor`).
  - Runs stop pipeline and delegates final state handling.

- `core/vpn/connect_state_helpers.dart`
  - Connect-side helper operations:
    - preflight setup
    - native precheck sync
    - bootstrap wait
    - timeout/error telemetry helpers
    - failure state application

- `core/vpn/disconnect_state_helpers.dart`
  - Disconnect-side helper operations:
    - wait for connect completion
    - UI transition prep
    - success/error finalization
    - disconnect end logging

## Connect Flow (High-Level)

1. `VpnService._executeConnect()`
2. Guard checks (`VpnOperationGuards.evaluateConnect`)
3. Native sync short-circuit (`_syncConnectedFromNativePrecheck`)
4. Preflight preparation (`_prepareConnectPreflight`)
5. Stage preparation (`_prepareConnectStageExecution`)
6. Bootstrap wait (`_awaitBootstrapForConnect`)
7. Retry execution (`_runConnectAttempts` -> `_ConnectAttemptExecutor.run`)
8. Final cleanup in `finally` (reset transitioning/session flags)

## Disconnect Flow (High-Level)

1. `VpnService.disconnect()`
2. Guard checks (`VpnOperationGuards.evaluateDisconnect`)
3. Cancel stale prepare flights
4. Wait connect completion (`_awaitConnectCompletionBeforeDisconnect`)
5. UI transition prep (`_prepareDisconnectUiTransition`)
6. Pipeline execution (`_runDisconnectPipeline` -> `_DisconnectPipelineExecutor.run`)
7. Finalizer path:
   - success -> `_finalizeDisconnectSuccess`
   - error -> `_finalizeDisconnectError`

## Modification Rules

- Do not add new heavy business blocks directly into `VpnService` methods.
- If logic has retries/timeouts/stage branching, place it in executor/helper.
- Keep guard logic pure (no side effects) in `vpn_operation_guards.dart`.
- Keep user-facing error text mapping centralized in existing helper paths.
- Preserve existing logging semantics (`_log`, stage logs, perf records).
- Preserve state transitions order; do not reorder without strong reason.

## Safe Refactor Checklist

- No behavior changes unless explicitly requested.
- Keep existing transition states and telemetry fields.
- Run lints after edits.
- Verify connect/disconnect happy-path and error-path manually.

