import Foundation
import WireGuardKit

extension TunnelConfiguration {
  enum ParserState {
    case inInterfaceSection
    case inPeerSection
    case notInASection
  }

  enum ParseError: Error {
    case invalidLine(String.SubSequence)
    case noInterface
    case multipleInterfaces
    case interfaceHasNoPrivateKey
    case interfaceHasInvalidPrivateKey(String)
    case interfaceHasInvalidListenPort(String)
    case interfaceHasInvalidAddress(String)
    case interfaceHasInvalidDNS(String)
    case interfaceHasInvalidMTU(String)
    case interfaceHasInvalidCustomParam(String)
    case interfaceHasUnrecognizedKey(String)
    case peerHasNoPublicKey
    case peerHasInvalidPublicKey(String)
    case peerHasInvalidPreSharedKey(String)
    case peerHasInvalidAllowedIP(String)
    case peerHasInvalidEndpoint(String)
    case peerHasInvalidPersistentKeepAlive(String)
    case peerHasUnrecognizedKey(String)
    case multiplePeersWithSamePublicKey
    case multipleEntriesForKey(String)
  }

  convenience init(fromWgQuickConfig wgQuickConfig: String, called name: String? = nil) throws {
    var interfaceConfiguration: InterfaceConfiguration?
    var peerConfigurations = [PeerConfiguration]()
    let lines = wgQuickConfig.split { $0.isNewline }
    var parserState = ParserState.notInASection
    var attributes = [String: String]()

    for (lineIndex, line) in lines.enumerated() {
      var trimmedLine: String
      if let commentRange = line.range(of: "#") {
        trimmedLine = String(line[..<commentRange.lowerBound])
      } else {
        trimmedLine = String(line)
      }
      trimmedLine = trimmedLine.trimmingCharacters(in: .whitespacesAndNewlines)
      let lowercasedLine = trimmedLine.lowercased()

      if !trimmedLine.isEmpty {
        if let equalsIndex = trimmedLine.firstIndex(of: "=") {
          let keyWithCase = trimmedLine[..<equalsIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
          let key = keyWithCase.lowercased()
          let value = trimmedLine[trimmedLine.index(equalsIndex, offsetBy: 1)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
          let multiEntryKeys: Set<String> = ["address", "allowedips", "dns"]
          if let presentValue = attributes[key] {
            if multiEntryKeys.contains(key) {
              attributes[key] = presentValue + "," + value
            } else {
              throw ParseError.multipleEntriesForKey(keyWithCase)
            }
          } else {
            attributes[key] = value
          }

          let interfaceKeys: Set<String> = [
            "privatekey", "listenport", "address", "dns", "mtu",
            "jc", "jmin", "jmax", "s1", "s2", "s3", "s4",
            "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5",
          ]
          let peerKeys: Set<String> = [
            "publickey", "presharedkey", "allowedips", "endpoint",
            "persistentkeepalive",
          ]
          if parserState == .inInterfaceSection, !interfaceKeys.contains(key) {
            throw ParseError.interfaceHasUnrecognizedKey(keyWithCase)
          }
          if parserState == .inPeerSection, !peerKeys.contains(key) {
            throw ParseError.peerHasUnrecognizedKey(keyWithCase)
          }
        } else if lowercasedLine != "[interface]" && lowercasedLine != "[peer]" {
          throw ParseError.invalidLine(line)
        }
      }

      let isLastLine = lineIndex == lines.count - 1
      if isLastLine || lowercasedLine == "[interface]" || lowercasedLine == "[peer]" {
        if parserState == .inInterfaceSection {
          let interface = try TunnelConfiguration.collate(interfaceAttributes: attributes)
          guard interfaceConfiguration == nil else { throw ParseError.multipleInterfaces }
          interfaceConfiguration = interface
        } else if parserState == .inPeerSection {
          let peer = try TunnelConfiguration.collate(peerAttributes: attributes)
          peerConfigurations.append(peer)
        }
      }

      if lowercasedLine == "[interface]" {
        parserState = .inInterfaceSection
        attributes.removeAll()
      } else if lowercasedLine == "[peer]" {
        parserState = .inPeerSection
        attributes.removeAll()
      }
    }

    let peerPublicKeys = peerConfigurations.map { $0.publicKey }
    if peerPublicKeys.count != Set<PublicKey>(peerPublicKeys).count {
      throw ParseError.multiplePeersWithSamePublicKey
    }
    guard let interfaceConfiguration else { throw ParseError.noInterface }
    self.init(name: name, interface: interfaceConfiguration, peers: peerConfigurations)
  }

  private static func collate(interfaceAttributes attributes: [String: String]) throws -> InterfaceConfiguration {
    guard let privateKeyString = attributes["privatekey"] else {
      throw ParseError.interfaceHasNoPrivateKey
    }
    guard let privateKey = PrivateKey(base64Key: privateKeyString) else {
      throw ParseError.interfaceHasInvalidPrivateKey(privateKeyString)
    }
    var interface = InterfaceConfiguration(privateKey: privateKey)

    if let listenPortString = attributes["listenport"] {
      guard let listenPort = UInt16(listenPortString) else {
        throw ParseError.interfaceHasInvalidListenPort(listenPortString)
      }
      interface.listenPort = listenPort
    }
    if let addressesString = attributes["address"] {
      interface.addresses = try addressesString
        .splitToArray(trimmingCharacters: .whitespacesAndNewlines)
        .map {
          guard let address = IPAddressRange(from: $0) else {
            throw ParseError.interfaceHasInvalidAddress($0)
          }
          return address
        }
    }
    if let dnsString = attributes["dns"] {
      var dnsServers = [DNSServer]()
      var dnsSearch = [String]()
      for value in dnsString.splitToArray(trimmingCharacters: .whitespacesAndNewlines) {
        if let dnsServer = DNSServer(from: value) {
          dnsServers.append(dnsServer)
        } else {
          dnsSearch.append(value)
        }
      }
      interface.dns = dnsServers
      interface.dnsSearch = dnsSearch
    }
    if let mtuString = attributes["mtu"] {
      guard let mtu = UInt16(mtuString) else {
        throw ParseError.interfaceHasInvalidMTU(mtuString)
      }
      interface.mtu = mtu
    }

    try applyAmneziaFields(attributes: attributes, to: &interface)
    return interface
  }

  private static func applyAmneziaFields(
    attributes: [String: String],
    to interface: inout InterfaceConfiguration
  ) throws {
    func uint16(_ key: String) throws -> UInt16? {
      guard let value = attributes[key] else { return nil }
      guard let parsed = UInt16(value) else {
        throw ParseError.interfaceHasInvalidCustomParam(value)
      }
      return parsed
    }

    interface.junkPacketCount = try uint16("jc")
    interface.junkPacketMinSize = try uint16("jmin")
    interface.junkPacketMaxSize = try uint16("jmax")
    interface.initPacketJunkSize = try uint16("s1")
    interface.responsePacketJunkSize = try uint16("s2")
    interface.cookieReplyPacketJunkSize = try uint16("s3")
    interface.transportPacketJunkSize = try uint16("s4")
    interface.initPacketMagicHeader = attributes["h1"]
    interface.responsePacketMagicHeader = attributes["h2"]
    interface.underloadPacketMagicHeader = attributes["h3"]
    interface.transportPacketMagicHeader = attributes["h4"]
    interface.specialJunk1 = attributes["i1"]
    interface.specialJunk2 = attributes["i2"]
    interface.specialJunk3 = attributes["i3"]
    interface.specialJunk4 = attributes["i4"]
    interface.specialJunk5 = attributes["i5"]
  }

  private static func collate(peerAttributes attributes: [String: String]) throws -> PeerConfiguration {
    guard let publicKeyString = attributes["publickey"] else {
      throw ParseError.peerHasNoPublicKey
    }
    guard let publicKey = PublicKey(base64Key: publicKeyString) else {
      throw ParseError.peerHasInvalidPublicKey(publicKeyString)
    }
    var peer = PeerConfiguration(publicKey: publicKey)
    if let preSharedKeyString = attributes["presharedkey"] {
      guard let preSharedKey = PreSharedKey(base64Key: preSharedKeyString) else {
        throw ParseError.peerHasInvalidPreSharedKey(preSharedKeyString)
      }
      peer.preSharedKey = preSharedKey
    }
    if let allowedIPsString = attributes["allowedips"] {
      peer.allowedIPs = try allowedIPsString
        .splitToArray(trimmingCharacters: .whitespacesAndNewlines)
        .map {
          guard let allowedIP = IPAddressRange(from: $0) else {
            throw ParseError.peerHasInvalidAllowedIP($0)
          }
          return allowedIP
        }
    }
    if let endpointString = attributes["endpoint"] {
      guard let endpoint = Endpoint(from: endpointString) else {
        throw ParseError.peerHasInvalidEndpoint(endpointString)
      }
      peer.endpoint = endpoint
    }
    if let keepAliveString = attributes["persistentkeepalive"] {
      guard let keepAlive = UInt16(keepAliveString) else {
        throw ParseError.peerHasInvalidPersistentKeepAlive(keepAliveString)
      }
      peer.persistentKeepAlive = keepAlive
    }
    return peer
  }
}
