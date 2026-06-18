# VPN Session Policy

Document describes how device limits, active sessions, and "already connected" are handled for support and tests.

## Device limit

- A user can have up to **N registered devices** (see `DeviceManager._DEVICE_LIMIT`, default 5).
- Registering a new device when at limit raises **DeviceLimitExceededError** / API returns an error with the list of devices.
- The client (mobile app) shows a bottom sheet: user picks a device to **deactivate** (log out). After deactivation, the user can connect again (same or another device).
- **One active VPN tunnel per device**: at any time, a device is either connected to one server or disconnected. There is no "multiple simultaneous tunnels" on one device.

## One active tunnel per device

- Backend tracks `Device.is_active` and `Device.current_server_id`. When a device connects, it is marked active; when it disconnects, it is cleared.
- If the client sends **connect** for a device that is already active (e.g. stale state or another tab), the backend:
  1. Tries **force disconnect** (clear peer on server, set `device.is_active = False`).
  2. Then proceeds with the new connect.
- So the model is **"last session wins"**: the newest connect request wins; the previous session is force-disconnected. The client may receive a 400 "Устройство уже подключено" if force disconnect failed; in that case the client can show "отключите на другом устройстве или попробуйте снова" and/or offer the device-limit sheet.

## Parallel sessions (multiple devices)

- Different devices of the same user can be connected at the same time (each to its own server, one tunnel per device).
- No limit on "concurrent connected devices" other than the total device limit (N); e.g. all N devices could be connected simultaneously.

## Support / testing

- **Connection logs**: `connection_logs` table stores connect/disconnect events (user, device, server, time). Use admin "События" or diagnostics by user to inspect.
- **Force disconnect**: Admin or API can force-disconnect a device; backend clears `device.is_active` and removes the peer on the server (WireGuard/Xray). If peer removal fails (e.g. SSH error), the DB state is still cleared so the next connect does not see "already connected".
- **Resolve by fingerprint**: After app reinstall, the client can call `POST /vpn/device/resolve` with fingerprint; backend returns existing device_id so the user does not lose the device slot.
