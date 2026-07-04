import TartCore
import Foundation
import Network
import Virtualization
import vmnet

/// Thin adapter over the C `vmnet` framework (`vmnet_network_configuration_*` /
/// `vmnet_network_*`). This is the *only* file in the control plane that talks to the raw
/// C API directly — everything else (validation, orchestration, diagnostics, IP
/// resolution) works with the `VmnetConfig`/`VmnetRuntimeState` domain types instead.
/// Isolating the C interop here means that if Apple adjusts a function signature in a
/// future SDK, exactly one file needs to change.
@available(macOS 26.0, *)
enum VmnetNativeBridge {
  /// Builds a `vmnet_network_configuration_ref` from a validated `VmnetConfig`.
  ///
  /// Callers are expected to have already run `config` through `VmnetValidator` —
  /// this function surfaces framework-level failures (`vmnet_return_t != VMNET_SUCCESS`),
  /// not configuration mistakes, which are caught earlier and cheaper.
  static func buildConfiguration(from config: VmnetConfig) throws -> vmnet_network_configuration_ref {
    var status: vmnet_return_t = .VMNET_SUCCESS
    guard let nativeConfig = vmnet_network_configuration_create(config.topology.nativeMode, &status) else {
      throw VmnetError.networkConfigurationFailed(underlying: "vmnet_network_configuration_create returned \(status)")
    }

    if let subnet = config.subnet {
      var address = subnet.address.nativeInAddr
      var mask = subnet.subnetMask.nativeInAddr
      let subnetStatus = vmnet_network_configuration_set_ipv4_subnet(nativeConfig, &address, &mask)
      guard subnetStatus == .VMNET_SUCCESS else {
        throw VmnetError.networkConfigurationFailed(underlying: "failed to set subnet \(subnet): \(subnetStatus)")
      }
    }

    if !config.natEnabled {
      vmnet_network_configuration_disable_nat44(nativeConfig)
      vmnet_network_configuration_disable_nat66(nativeConfig)
    }

    if !config.dhcpEnabled {
      vmnet_network_configuration_disable_dhcp(nativeConfig)
    }

    if !config.dnsEnabled {
      vmnet_network_configuration_disable_dns_proxy(nativeConfig)
    }

    if let mtu = config.mtu {
      let mtuStatus = vmnet_network_configuration_set_mtu(nativeConfig, mtu)
      guard mtuStatus == .VMNET_SUCCESS else {
        throw VmnetError.networkConfigurationFailed(underlying: "failed to set MTU \(mtu): \(mtuStatus)")
      }
    }

    // NOTE: per the vmnet.h documentation, vmnet_network_configuration_set_external_interface
    // is documented as applying to VMNET_SHARED_MODE networks (pins the NAT egress interface).
    // We also apply it for `.bridged` topology, since bridged networks likewise need to know
    // which physical interface to bridge onto; if a future SDK rejects this combination it
    // will surface as a `networkConfigurationFailed` here rather than failing silently.
    if let externalInterface = config.externalInterface {
      let externalStatus = externalInterface.withCString { cString in
        vmnet_network_configuration_set_external_interface(nativeConfig, cString)
      }
      guard externalStatus == .VMNET_SUCCESS else {
        throw VmnetError.networkConfigurationFailed(underlying: "failed to bind external interface \"\(externalInterface)\": \(externalStatus)")
      }
    }

    for reservation in config.reservations {
      guard let normalizedMAC = VmnetValidator.normalizeMACAddress(reservation.macAddress),
            let macAddress = MACAddress(fromString: normalizedMAC),
            let ip = IPv4Address(reservation.ipAddress) else {
        // Already caught by VmnetValidator in the normal flow; defensive fallback here.
        throw VmnetError.invalidMACAddress(raw: reservation.macAddress)
      }

      var client = macAddress.nativeEtherAddr
      var reservedAddress = ip.nativeInAddr
      let reservationStatus = vmnet_network_configuration_add_dhcp_reservation(nativeConfig, &client, &reservedAddress)
      guard reservationStatus == .VMNET_SUCCESS else {
        throw VmnetError.networkConfigurationFailed(underlying: "failed to add reservation \(reservation.macAddress) -> \(reservation.ipAddress): \(reservationStatus)")
      }
    }

    return nativeConfig
  }

  /// Realizes a `vmnet_network_configuration_ref` into an actual `vmnet_network_ref`.
  /// This is the point at which the vmnet entitlement is actually checked by the OS, and
  /// where subnet collisions with other already-running networks are detected.
  static func createNetwork(from nativeConfig: vmnet_network_configuration_ref) throws -> vmnet_network_ref {
    var status: vmnet_return_t = .VMNET_SUCCESS
    guard let network = vmnet_network_create(nativeConfig, &status) else {
      throw VmnetError.networkCreationFailed(underlying: "vmnet_network_create returned \(status)")
    }
    return network
  }

  /// Queries the subnet vmnet actually assigned to the network — this can differ from what
  /// was requested if `VmnetConfig.subnet` was left unset (vmnet then auto-selects a /24
  /// under 192.168/16) or the request was adjusted by the framework.
  static func actualSubnet(of network: vmnet_network_ref) -> CIDRBlock? {
    var address = in_addr()
    var mask = in_addr()
    // vmnet_network_get_ipv4_subnet() returns void; an all-zero address is treated as
    // "not (yet) known", e.g. queried before the network's interface has started.
    vmnet_network_get_ipv4_subnet(network, &address, &mask)

    guard let addr4 = IPv4Address(nativeInAddr: address), let prefixLength = mask.prefixLength else { return nil }
    guard addr4 != IPv4Address.any else { return nil }
    return CIDRBlock(address: addr4, prefixLength: prefixLength)
  }

  static func makeAttachment(network: vmnet_network_ref) -> VZVmnetNetworkDeviceAttachment {
    VZVmnetNetworkDeviceAttachment(network: network)
  }
}

@available(macOS 26.0, *)
private extension VmnetConfig.Topology {
  var nativeMode: vmnet_mode_t {
    switch self {
    case .shared: return .VMNET_SHARED_MODE
    case .host: return .VMNET_HOST_MODE
    case .bridged: return .VMNET_BRIDGED_MODE
    }
  }
}

private extension IPv4Address {
  var nativeInAddr: in_addr {
    var addr = in_addr()
    _ = "\(self)".withCString { inet_pton(AF_INET, $0, &addr) }
    return addr
  }

  init?(nativeInAddr addr: in_addr) {
    var addr = addr
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
    self.init(String(cString: buffer))
  }
}

private extension MACAddress {
  var nativeEtherAddr: ether_addr_t {
    var ea = ether_addr_t()
    withUnsafeMutableBytes(of: &ea) { raw in
      for index in 0..<min(6, mac.count) {
        raw[index] = mac[index]
      }
    }
    return ea
  }
}

private extension in_addr {
  /// Converts a dotted-decimal netmask (e.g. 255.255.255.0) into a CIDR prefix length (24).
  /// Returns nil for non-contiguous masks, which are not representable as a CIDR block.
  /// Operates on the raw address bytes (as populated by `inet_pton`, MSB-first) rather than
  /// treating `s_addr` as a host-endian integer, since its in-memory byte layout is what
  /// actually matters here and is endianness-independent this way.
  var prefixLength: Int? {
    var copy = self
    let bytes = withUnsafeBytes(of: &copy) { Array($0) }

    var length = 0
    var seenZero = false

    for byte in bytes {
      for bitIndex in stride(from: 7, through: 0, by: -1) {
        let bitSet = (byte & (1 << bitIndex)) != 0
        if bitSet {
          if seenZero { return nil }
          length += 1
        } else {
          seenZero = true
        }
      }
    }

    return length
  }
}
