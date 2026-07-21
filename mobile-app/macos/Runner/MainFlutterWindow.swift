import Cocoa
import FlutterMacOS
import NetworkExtension

class MainFlutterWindow: NSWindow {
  private static let vpnChannelName = "com.granivpn.mobile/vpn"
  private static let packetTunnelBundleIdentifier =
    "com.granivpn.mobileApp.PacketTunnel"
  private static let packetTunnelProductName = "GRANIPacketTunnel.appex"
  private static let tunnelName = "GRANI VPN"

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerVpnChannel(with: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  private func registerVpnChannel(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: Self.vpnChannelName,
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handleVpnMethod(call, result: result)
    }
  }

  private func handleVpnMethod(
    _ call: FlutterMethodCall,
    result: @escaping FlutterResult
  ) {
    switch call.method {
    case "connectAmneziaWg":
      guard
        let arguments = call.arguments as? [String: Any],
        let config = arguments["config"] as? String,
        !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        result(FlutterError(
          code: "MACOS_VPN_CONFIG_MISSING",
          message: "GRANIwg config is missing.",
          details: nil
        ))
        return
      }
      connectManagedTunnel(
        config: config,
        sessionId: arguments["connection_session_id"] as? String,
        source: arguments["source"] as? String,
        result: result
      )
    case "disconnectAmneziaWg", "disconnect":
      disconnectManagedTunnel(result: result)
    case "getAmneziaWgStatus", "getStatus":
      loadManagedTunnel { manager, error in
        if let error {
          result(FlutterError(
            code: "MACOS_VPN_STATUS_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
          return
        }
        result(self.statusMap(for: manager))
      }
    case "getTrafficStats":
      loadTrafficStats(result: result)
    case "getDesktopVpnDiagnostics", "getRuntimeDiagnostics":
      desktopDiagnostics(result: result)
    case "requestPermission":
      result(true)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func connectManagedTunnel(
    config: String,
    sessionId: String?,
    source: String?,
    result: @escaping FlutterResult
  ) {
    guard isPacketTunnelEmbedded else {
      result(FlutterError(
        code: "MACOS_PACKET_TUNNEL_NOT_EMBEDDED",
        message: "The GRANI Packet Tunnel extension is not embedded in this build.",
        details: diagnosticsBase()
      ))
      return
    }

    loadManagedTunnel { [weak self] existingManager, error in
      guard let self else { return }
      if let error {
        result(FlutterError(
          code: "MACOS_VPN_LOAD_FAILED",
          message: error.localizedDescription,
          details: self.diagnosticsBase()
        ))
        return
      }

      let manager = existingManager ?? NETunnelProviderManager()
      let tunnelProtocol = NETunnelProviderProtocol()
      tunnelProtocol.providerBundleIdentifier = Self.packetTunnelBundleIdentifier
      tunnelProtocol.serverAddress = self.serverAddress(from: config)
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
          result(FlutterError(
            code: "MACOS_VPN_SAVE_FAILED",
            message: saveError.localizedDescription,
            details: self.diagnosticsBase()
          ))
          return
        }
        manager.loadFromPreferences { loadError in
          if let loadError {
            result(FlutterError(
              code: "MACOS_VPN_RELOAD_FAILED",
              message: loadError.localizedDescription,
              details: self.diagnosticsBase()
            ))
            return
          }
          guard let session = manager.connection as? NETunnelProviderSession else {
            result(FlutterError(
              code: "MACOS_VPN_SESSION_MISSING",
              message: "NETunnelProviderSession is unavailable.",
              details: self.diagnosticsBase()
            ))
            return
          }
          do {
            let options: [String: NSObject] = [
              "activationAttemptId": UUID().uuidString as NSString,
              "connection_session_id": (sessionId ?? "") as NSString,
              "source": (source ?? "") as NSString,
            ]
            try session.startTunnel(options: options)
            result(true)
          } catch {
            result(FlutterError(
              code: "MACOS_VPN_START_FAILED",
              message: error.localizedDescription,
              details: self.diagnosticsBase()
            ))
          }
        }
      }
    }
  }

  private func loadManagedTunnel(
    completion: @escaping (NETunnelProviderManager?, Error?) -> Void
  ) {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      let manager = managers?.first(where: { candidate in
        guard let tunnelProtocol =
          candidate.protocolConfiguration as? NETunnelProviderProtocol
        else {
          return false
        }
        return tunnelProtocol.providerBundleIdentifier ==
          Self.packetTunnelBundleIdentifier
      })
      completion(manager, error)
    }
  }

  private func statusMap(for manager: NETunnelProviderManager?) -> [String: Any] {
    let status = manager?.connection.status ?? .invalid
    let connected = status == .connected || status == .reasserting
    return [
      "connected": connected,
      "service_state": statusName(status),
      "rx_bytes": 0,
      "tx_bytes": 0,
      "runner": "network_extension",
      "packet_tunnel_embedded": isPacketTunnelEmbedded,
    ]
  }

  private func disconnectManagedTunnel(result: @escaping FlutterResult) {
    loadManagedTunnel { manager, error in
      if let error {
        result(FlutterError(
          code: "MACOS_VPN_STOP_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
        return
      }
      manager?.connection.stopVPNTunnel()
      result(true)
    }
  }

  private func loadTrafficStats(result: @escaping FlutterResult) {
    loadManagedTunnel { manager, error in
      if let error {
        result(FlutterError(
          code: "MACOS_VPN_TRAFFIC_FAILED",
          message: error.localizedDescription,
          details: nil
        ))
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
          let stats = self.parseTrafficStats(from: data)
          result(stats)
        }
      } catch {
        result(["rx_bytes": 0, "tx_bytes": 0])
      }
    }
  }

  private func desktopDiagnostics(result: @escaping FlutterResult) {
    loadManagedTunnel { manager, error in
      var diagnostics = self.diagnosticsBase()
      diagnostics["manager_configured"] = manager != nil
      diagnostics["service_state"] = self.statusName(
        manager?.connection.status ?? .invalid
      )
      if let tunnelProtocol = manager?.protocolConfiguration as? NETunnelProviderProtocol {
        diagnostics["provider_bundle_id_configured"] =
          tunnelProtocol.providerBundleIdentifier ?? ""
        diagnostics["server_address"] = tunnelProtocol.serverAddress ?? ""
        diagnostics["has_wg_quick_config"] =
          (tunnelProtocol.providerConfiguration?["WgQuickConfig"] as? String)?.isEmpty == false
      }
      if let error {
        diagnostics["diagnostics_error"] = error.localizedDescription
      }
      result(diagnostics)
    }
  }

  private var packetTunnelExtensionURL: URL? {
    Bundle.main.builtInPlugInsURL?.appendingPathComponent(
      Self.packetTunnelProductName
    )
  }

  private var isPacketTunnelEmbedded: Bool {
    guard let packetTunnelExtensionURL else { return false }
    return FileManager.default.fileExists(atPath: packetTunnelExtensionURL.path)
  }

  private func diagnosticsBase() -> [String: Any] {
    [
      "platform": "macos",
      "runtime_mode": "network_extension",
      "packet_tunnel_bundle_id": Self.packetTunnelBundleIdentifier,
      "packet_tunnel_embedded": isPacketTunnelEmbedded,
      "packet_tunnel_path": packetTunnelExtensionURL?.path ?? "",
    ]
  }

  private func serverAddress(from config: String) -> String {
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

  private func parseTrafficStats(from data: Data?) -> [String: Int64] {
    guard
      let data,
      let settings = String(data: data, encoding: .utf8)
    else {
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
    case .invalid:
      return "invalid"
    case .disconnected:
      return "disconnected"
    case .connecting:
      return "connecting"
    case .connected:
      return "connected"
    case .reasserting:
      return "reasserting"
    case .disconnecting:
      return "disconnecting"
    @unknown default:
      return "unknown"
    }
  }
}
