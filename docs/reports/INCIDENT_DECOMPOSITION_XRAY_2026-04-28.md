# Incident Decomposition: All Xray Protocols

Date: `2026-04-28`  
Scope: `xray_vless`, `xray_reality`, `xray_vmess`  
Path analyzed: client -> nginx -> api -> db -> vpn node

## 1) Unified Test Scenario and Correlation IDs

Single user/device window was reconstructed from `client_logs` and nginx/api request IDs:

| Protocol | connection_session_id | Approx UTC window | Outcome |
|---|---|---|---|
| `xray_vless` | `1777357412971_168a` | `06:24:16` - `06:25:22` | Connected state reached, public internet probe failed |
| `xray_reality` | `1777357500405_94d8` | `06:25:24` - `06:36:26` | Connected state reached, public internet probe failed |
| `xray_vmess` | `1777357592486_f361` | `06:36:27+` | Start recorded, no successful completion in window |

Normalized correlation keys used in this analysis:
- `request_id` (nginx + api)
- `protocol`
- `device_id`
- `server_id`
- `vpn_session_id` / `connection_session_id`
- UTC timestamps

## 2) Control-Plane Validation (Nginx/API/DB)

### Nginx + API (`2026-04-28` log window)

`POST /api/vpn/session/prepare` by protocol:
- `xray_vless`: 7 calls, all `200`
- `xray_reality`: 4 calls, all `200`
- `xray_vmess`: 1 call, `200`

Latency pattern:
- Slow `prepare` calls are present across all protocols (`>2s`, sometimes `>5s`), but no protocol-specific HTTP failure pattern.
- `GET /api/vpn/xray/apply-state` observed (18 requests), endpoint healthy.

### API structured telemetry

`session_prepare_metric` is present for all three protocols; cache behavior includes both `hit` and `miss`, no evidence of permanent stuck path in API for one protocol only.

### DB (`edge_node_assignments`)

Recent records for `apply_xray_config` are `completed/ok`.
Latest entries:
- `cfg16=sha256:5b8b2944c...`, `xray_reloaded_at=2026-04-28 06:16:39 UTC`, `result_message=config applied`
- Earlier: `cfg16=sha256:fa6d981e2...`, also `completed/ok`

No failing assignment chain (`created/dispatched/completed`) was found in current incident window.

## 3) Config Consistency (Issued vs Applied vs Active)

### Active node config (`HU-BUD-01`)

Active hash on node:
- `/usr/local/etc/xray/config.json` -> `5b8b2944c430b87fbf4d6488a40fe8e9db7e9da85afdd816dabdb167cec28bad`

Current inbounds:
- `4443` `vless`
- `2053` `vless`
- `8443` `vmess`

### Backend apply hash consistency

Top assignment hash prefix in DB:
- `sha256:5b8b2944c...`

This matches active node config hash prefix, which means:
- backend-applied config and active node config are aligned,
- no direct evidence of config desynchronization in the current snapshot.

### Limitation (important)

`session/prepare` response payload bodies are not persisted in current backend logs, so full field-by-field diff (`uuid/security/sni/shortIds`) cannot be proven post-factum from server logs alone.  
Action item is included in remediation: persist safe payload fingerprint for deterministic comparison.

## 4) Data-Plane Error Classification

Node journal extraction (`07:30+ CEST` window) shows:

- Massive VMESS failures:
  - `proxy/vmess/encoding: failed to read request header ... i/o timeout`
  - count in captured window: `1178`
  - dominant source IP in incident slice: `94.180.243.40` (user traffic window)

- VLESS/VMESS invalid-version/invalid-user events exist, but mostly from unrelated scanner IPs (`44.222...`, `3.101...`, `100.28...`, etc.), not the user test flow.

- Client-side for VLESS/Reality consistently shows:
  - `connectivity_probe: api_ok=true, public_ok=false`
  - `public_err=SocketTimeoutException: Read timed out`
  - frequent `ACK timeout` at `apply_protocol` stage in some attempts

Interpretation:
- Control plane is mostly alive.
- Tunnel lifecycle may transition to connected locally, but data plane cannot deliver stable public egress.
- VMESS has explicit server-side handshake/read-header timeout storm.
- VLESS/Reality fail user-visible connectivity checks even when API remains healthy.

## 5) Hypothesis Check: “Sessions Corrupt Configs”

Hypothesis status: **not confirmed** in this incident window.

Evidence:
1. Latest successful apply hash in DB matches active hash on node.
2. No failed apply assignments in the examined window.
3. Reload event (`08:16:39 CEST`) is correlated with planned apply, but mass VMESS timeout storm observed later (`08:27+ CEST`) without a new matching apply burst.
4. Failures appear as data-plane/protocol behavior, not as immediate config mismatch signal.

What remains unresolved:
- Cannot fully exclude per-request payload divergence because `session/prepare` payload fingerprint is not logged.

## 6) Remediation Pack (Prioritized)

### A. Deterministic observability for config consistency (P0)
- Log and return a safe `payload_fingerprint` for each `session/prepare`.
- Persist mapping:
  - `request_id`
  - `protocol`
  - `config_revision`
  - `payload_fingerprint`
  - `active_config_hash`
- This closes the current blind spot in “issued vs active config” diff.

### B. ACK/apply behavior hardening (P0)
- Keep `prepare` in stage-only mode by default.
- Gate commit/apply during active session unless explicit override.
- Add strict timeout reason codes in `apply-state` and surface them to client without generic timeout text.

### C. Protocol-specific validation guards (P1)
- Server-side preflight validation before returning config:
  - VMESS: user id existence + port/inbound readiness
  - VLESS/Reality: required security/reality fields sanity checks
- Reject invalid payload generation early with explicit reason codes.

### D. Data-plane egress diagnostics (P1)
- Add lightweight periodic egress probe from node and expose status to backend.
- If probe fails, short-circuit client flow with `node_egress_degraded` instead of allowing long user timeout loops.

### E. Client retry policy alignment (P2)
- Separate retry policies:
  - `apply_ack_timeout`
  - `handshake_timeout`
  - `public_probe_timeout`
- Prevent repeated long loops when `public_ok=false` is already confirmed.

## 7) Closure Criteria for This Incident

For each protocol (`vless/reality/vmess`), pass all:
1. 5 sequential `prepare -> connect -> speedtest` runs without timeout.
2. `api_ok=true` and `public_ok=true` in connectivity probes.
3. No burst of protocol-specific critical errors in node journal during run window.
4. `payload_fingerprint == active_config_hash` lineage traceable for each attempt.
