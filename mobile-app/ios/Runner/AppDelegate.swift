import Flutter
import NetworkExtension
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var vpnBridge: IOSVpnBridge?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      vpnBridge = IOSVpnBridge(messenger: controller.binaryMessenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

private final class IOSVpnBridge {
  private static let channelName = "com.granivpn.mobile/vpn"
  private static let packetTunnelBundleIdentifier =
    "com.granivpn.mobile.PacketTunnel"
  private static let packetTunnelProductName = "GRANIPacketTunnel.appex"
  private static let tunnelName = "GRANI VPN"

  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(
      name: Self.channelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "connectAmneziaWg":
      guard
        let arguments = call.arguments as? [String: Any],
        let config = arguments["config"] as? String,
        !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        result(error("IOS_VPN_CONFIG_MISSING", "WireGuard obf config is missing."))
        return
      }
      connect(
        config: config,
        sessionId: arguments["connection_session_id"] as? String,
        source: arguments["source"] as? String,
        result: result
      )
    case "disconnectAmneziaWg", "disconnect":
      disconnect(result: result)
    case "getAmneziaWgStatus", "getStatus":
      loadManager { manager, loadError in
        if let loadError {
          result(self.error("IOS_VPN_STATUS_FAILED", loadError.localizedDescription))
          return
        }
        result(self.statusMap(manager))
      }
    case "getTrafficStats":
      trafficStats(result: result)
    case "getDesktopVpnDiagnostics", "getRuntimeDiagnostics":
      diagnostics(result: result)
    case "isPermissionRequired":
      loadManager { manager, _ in result(manager == nil) }
    case "requestPermission":
      // iOS presents Network Extension consent while saving/starting the first
      // NETunnelProviderManager configuration.
      result(true)
    case "getPlatformCapabilities":
      result([
        "platform": "ios",
        "runtime_mode": "network_extension",
        "protocols": ["graniwg"],
        "app_split_tunnel": false,
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func connect(
    config: String,
    sessionId: String?,
    source: String?,
    result: @escaping FlutterResult
  ) {
    guard isPacketTunnelEmbedded else {
      result(error(
        "IOS_PACKET_TUNNEL_NOT_EMBEDDED",
        "GRANI Packet Tunnel is not embedded in this build.",
        details: diagnosticsBase()
      ))
      return
    }

    loadManager { existingManager, loadError in
      if let loadError {
        result(self.error(
          "IOS_VPN_LOAD_FAILED",
          loadError.localizedDescription,
          details: self.diagnosticsBase()
        ))
        return
      }

      let manager = existingManager ?? NETunnelProviderManager()
      let tunnelProtocol = NETunnelProviderProtocol()
      tunnelProtocol.providerBundleIdentifier = Self.packetTunnelBundleIdentifier
      tunnelProtocol.serverAddress = self.serverAddress(config)
      tunnelProtocol.disconnectOnSleep = false
      tunnelProtocol.providerConfiguration = [
        "WgQuickConfig": config,
        "connection_session_id": sessionId ?? "",
        "source": source ?? "",
        "created_at": ISO8601DateFormatter().string(from: Date()),
      ]
      manager.localizedDescription = Self.tunnelName
      manager.protocolConfiguration = tunnelProtocol
      manager.isEnabled = true

      manager.saveToPreferences { saveError in
        if let saveError {
          result(self.error(
            "IOS_VPN_SAVE_FAILED",
            saveError.localizedDescription,
            details: self.diagnosticsBase()
          ))
          return
        }
        manager.loadFromPreferences { reloadError in
          if let reloadError {
            result(self.error(
              "IOS_VPN_RELOAD_FAILED",
              reloadError.localizedDescription,
              details: self.diagnosticsBase()
            ))
            return
          }
          guard let session = manager.connection as? NETunnelProviderSession else {
            result(self.error(
              "IOS_VPN_SESSION_MISSING",
              "NETunnelProviderSession is unavailable.",
              details: self.diagnosticsBase()
            ))
            return
          }
          do {
            try session.startTunnel(options: [
              "activationAttemptId": UUID().uuidString as NSString,
              "connection_session_id": (sessionId ?? "") as NSString,
              "source": (source ?? "") as NSString,
            ])
            result(true)
          } catch {
            result(self.error(
              "IOS_VPN_START_FAILED",
              error.localizedDescription,
              details: self.diagnosticsBase()
            ))
          }
        }
      }
    }
  }

  private func disconnect(result: @escaping FlutterResult) {
    loadManager { manager, loadError in
      if let loadError {
        result(self.error("IOS_VPN_STOP_FAILED", loadError.localizedDescription))
        return
      }
      manager?.connection.stopVPNTunnel()
      result(true)
    }
  }

  private func loadManager(
    completion: @escaping (NETunnelProviderManager?, Error?) -> Void
  ) {
    NETunnelProviderManager.loadAllFromPreferences { managers, loadError in
      let manager = managers?.first { candidate in
        guard let tunnelProtocol =
          candidate.protocolConfiguration as? NETunnelProviderProtocol
        else {
          return false
        }
        return tunnelProtocol.providerBundleIdentifier ==
          Self.packetTunnelBundleIdentifier
      }
      completion(manager, loadError)
    }
  }

  private func trafficStats(result: @escaping FlutterResult) {
    loadManager { manager, loadError in
      if let loadError {
        result(self.error("IOS_VPN_TRAFFIC_FAILED", loadError.localizedDescription))
        return
      }
      guard
        let session = manager?.connection as? NETunnelProviderSession,
        manager?.connection.status == .connected ||
          manager?.connection.status == .reasserting
      else {
        result(["rx_bytes": 0, "tx_bytes": 0])
        return
      }
      do {
        try session.sendProviderMessage(Data([0])) { data in
          result(self.parseTrafficStats(data))
        }
      } catch {
        result(["rx_bytes": 0, "tx_bytes": 0])
      }
    }
  }

  private func diagnostics(result: @escaping FlutterResult) {
    loadManager { manager, loadError in
      var value = self.diagnosticsBase()
      value["manager_configured"] = manager != nil
      value["service_state"] = self.statusName(
        manager?.connection.status ?? .invalid
      )
      if let tunnelProtocol =
        manager?.protocolConfiguration as? NETunnelProviderProtocol
      {
        value["provider_bundle_id_configured"] =
          tunnelProtocol.providerBundleIdentifier ?? ""
        value["server_address"] = tunnelProtocol.serverAddress ?? ""
        value["has_wg_quick_config"] =
          (tunnelProtocol.providerConfiguration?["WgQuickConfig"] as? String)?
            .isEmpty == false
      }
      if let loadError { value["diagnostics_error"] = loadError.localizedDescription }
      result(value)
    }
  }

  private func statusMap(_ manager: NETunnelProviderManager?) -> [String: Any] {
    let status = manager?.connection.status ?? .invalid
    return [
      "connected": status == .connected || status == .reasserting,
      "service_state": statusName(status),
      "rx_bytes": 0,
      "tx_bytes": 0,
      "runner": "network_extension",
      "packet_tunnel_embedded": isPacketTunnelEmbedded,
    ]
  }

  private var packetTunnelURL: URL? {
    Bundle.main.builtInPlugInsURL?.appendingPathComponent(
      Self.packetTunnelProductName
    )
  }

  private var isPacketTunnelEmbedded: Bool {
    guard let packetTunnelURL else { return false }
    return FileManager.default.fileExists(atPath: packetTunnelURL.path)
  }

  private func diagnosticsBase() -> [String: Any] {
    [
      "platform": "ios",
      "runtime_mode": "network_extension",
      "packet_tunnel_bundle_id": Self.packetTunnelBundleIdentifier,
      "packet_tunnel_embedded": isPacketTunnelEmbedded,
      "packet_tunnel_path": packetTunnelURL?.path ?? "",
      "supported_protocols": ["graniwg"],
    ]
  }

  private func serverAddress(_ config: String) -> String {
    for rawLine in config.split(whereSeparator: { $0.isNewline }) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard line.lowercased().hasPrefix("endpoint") else { continue }
      guard let equals = line.firstIndex(of: "=") else { continue }
      let endpoint = line[line.index(after: equals)...]
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !endpoint.isEmpty { return endpoint }
    }
    return Self.tunnelName
  }

  private func parseTrafficStats(_ data: Data?) -> [String: Int64] {
    guard let data, let settings = String(data: data, encoding: .utf8) else {
      return ["rx_bytes": 0, "tx_bytes": 0]
    }
    var rx: Int64 = 0
    var tx: Int64 = 0
    for line in settings.split(whereSeparator: { $0.isNewline }) {
      if line.hasPrefix("rx_bytes="),
         let value = Int64(line.dropFirst("rx_bytes=".count)) {
        rx += value
      } else if line.hasPrefix("tx_bytes="),
                let value = Int64(line.dropFirst("tx_bytes=".count)) {
        tx += value
      }
    }
    return ["rx_bytes": rx, "tx_bytes": tx]
  }

  private func statusName(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid: return "invalid"
    case .disconnected: return "disconnected"
    case .connecting: return "connecting"
    case .connected: return "connected"
    case .reasserting: return "reasserting"
    case .disconnecting: return "disconnecting"
    @unknown default: return "unknown"
    }
  }

  private func error(
    _ code: String,
    _ message: String,
    details: Any? = nil
  ) -> FlutterError {
    FlutterError(code: code, message: message, details: details)
  }
}
