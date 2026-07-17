import Cocoa
import FlutterMacOS
import NetworkExtension

class MainFlutterWindow: NSWindow {
  private static let vpnChannelName = "com.granivpn.mobile/vpn"
  private static let packetTunnelBundleIdentifier =
    "com.granivpn.mobileApp.PacketTunnel"

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
      result(FlutterError(
        code: "MACOS_PACKET_TUNNEL_NOT_EMBEDDED",
        message: "The GRANI Packet Tunnel extension is not embedded in this build yet.",
        details: [
          "packet_tunnel_bundle_id": Self.packetTunnelBundleIdentifier,
          "next_step": "embed_amneziawg_apple_network_extension",
        ]
      ))
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
      result(["rx_bytes": 0, "tx_bytes": 0])
    case "getDesktopVpnDiagnostics", "getRuntimeDiagnostics":
      desktopDiagnostics(result: result)
    case "requestPermission":
      result(true)
    default:
      result(FlutterMethodNotImplemented)
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

  private func desktopDiagnostics(result: @escaping FlutterResult) {
    loadManagedTunnel { manager, error in
      let pluginsURL = Bundle.main.builtInPlugInsURL
      let extensionURL = pluginsURL?.appendingPathComponent(
        "GRANIPacketTunnel.appex"
      )
      var diagnostics: [String: Any] = [
        "platform": "macos",
        "runtime_mode": "network_extension",
        "packet_tunnel_bundle_id": Self.packetTunnelBundleIdentifier,
        "packet_tunnel_embedded": extensionURL.map {
          FileManager.default.fileExists(atPath: $0.path)
        } ?? false,
        "packet_tunnel_path": extensionURL?.path ?? "",
        "manager_configured": manager != nil,
        "service_state": self.statusName(
          manager?.connection.status ?? .invalid
        ),
      ]
      if let error {
        diagnostics["diagnostics_error"] = error.localizedDescription
      }
      result(diagnostics)
    }
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
