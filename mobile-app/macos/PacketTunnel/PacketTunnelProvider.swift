import Foundation
import NetworkExtension
import os.log
import WireGuardKit

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private lazy var adapter: WireGuardAdapter = {
    WireGuardAdapter(with: self) { level, message in
      let type: OSLogType = level == .error ? .error : .debug
      os_log("%{public}@", log: .default, type: type, message)
    }
  }()

  override func startTunnel(
    options: [String: NSObject]?,
    completionHandler: @escaping (Error?) -> Void
  ) {
    guard
      let tunnelProtocol = protocolConfiguration as? NETunnelProviderProtocol,
      let providerConfiguration = tunnelProtocol.providerConfiguration,
      let wgQuickConfig = providerConfiguration["WgQuickConfig"] as? String,
      !wgQuickConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      completionHandler(PacketTunnelError.missingConfiguration)
      return
    }

    do {
      let tunnelConfiguration = try TunnelConfiguration(
        fromWgQuickConfig: wgQuickConfig,
        called: tunnelProtocol.serverAddress ?? "GRANI VPN"
      )
      adapter.start(tunnelConfiguration: tunnelConfiguration) { error in
        if let error {
          os_log(
            "GRANI PacketTunnel start failed: %{public}@",
            log: .default,
            type: .error,
            String(describing: error)
          )
        }
        completionHandler(error)
      }
    } catch {
      os_log(
        "GRANI PacketTunnel config parse failed: %{public}@",
        log: .default,
        type: .error,
        String(describing: error)
      )
      completionHandler(error)
    }
  }

  override func stopTunnel(
    with reason: NEProviderStopReason,
    completionHandler: @escaping () -> Void
  ) {
    adapter.stop { error in
      if let error {
        os_log(
          "GRANI PacketTunnel stop failed: %{public}@",
          log: .default,
          type: .error,
          error.localizedDescription
        )
      }
      completionHandler()

      #if os(macOS)
      exit(0)
      #endif
    }
  }

  override func handleAppMessage(
    _ messageData: Data,
    completionHandler: ((Data?) -> Void)? = nil
  ) {
    guard let completionHandler else { return }
    guard messageData.count == 1, messageData[0] == 0 else {
      completionHandler(nil)
      return
    }
    adapter.getRuntimeConfiguration { settings in
      completionHandler(settings?.data(using: .utf8))
    }
  }
}

enum PacketTunnelError: String, Error {
  case missingConfiguration
}
