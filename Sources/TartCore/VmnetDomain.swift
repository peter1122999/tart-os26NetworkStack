import Foundation
import Network

/// A parsed IPv4 CIDR block, e.g. "192.168.64.0/24".
///
/// This intentionally doesn't depend on the `vmnet` framework so it can be validated
/// and unit tested on any host, including ones running an older macOS.
///
/// Public: shared verbatim with `TartVmnetManager` (the SwiftUI management app), which
/// edits `VmnetConfig` values — including their `subnet` field — directly rather than
/// through a serialized/IPC boundary.
public struct CIDRBlock: Equatable, Hashable, CustomStringConvertible {
  public let address: IPv4Address
  public let prefixLength: Int

  public init(address: IPv4Address, prefixLength: Int) {
    self.address = address
    self.prefixLength = prefixLength
  }

  public init?(_ raw: String) {
    let parts = raw.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
    guard parts.count == 2,
          let prefixLength = Int(parts[1]), (0...32).contains(prefixLength),
          let address = IPv4Address(String(parts[0])) else {
      return nil
    }

    self.address = address
    self.prefixLength = prefixLength
  }

  private static func bits(of address: IPv4Address) -> UInt32 {
    address.rawValue.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
  }

  private var netmaskBits: UInt32 {
    prefixLength == 0 ? 0 : (~UInt32(0)) << (32 - prefixLength)
  }

  public var networkAddressBits: UInt32 {
    Self.bits(of: address) & netmaskBits
  }

  public var broadcastAddressBits: UInt32 {
    networkAddressBits | ~netmaskBits
  }

  public var subnetMask: IPv4Address {
    IPv4Address(Data([
      UInt8((netmaskBits >> 24) & 0xff),
      UInt8((netmaskBits >> 16) & 0xff),
      UInt8((netmaskBits >> 8) & 0xff),
      UInt8(netmaskBits & 0xff),
    ]))!
  }

  /// The network address of this block, e.g. "192.168.64.0" for "192.168.64.10/24".
  public var networkAddress: IPv4Address {
    IPv4Address(Data([
      UInt8((networkAddressBits >> 24) & 0xff),
      UInt8((networkAddressBits >> 16) & 0xff),
      UInt8((networkAddressBits >> 8) & 0xff),
      UInt8(networkAddressBits & 0xff),
    ]))!
  }

  /// Host addresses usable for DHCP pools/reservations, excluding the network
  /// and broadcast addresses for prefixes shorter than /31.
  public var usableHostRange: ClosedRange<UInt32>? {
    switch prefixLength {
    case 32:
      return networkAddressBits...networkAddressBits
    case 31:
      return networkAddressBits...broadcastAddressBits
    default:
      guard networkAddressBits + 1 <= broadcastAddressBits - 1 else { return nil }
      return (networkAddressBits + 1)...(broadcastAddressBits - 1)
    }
  }

  public func contains(_ candidate: IPv4Address) -> Bool {
    (Self.bits(of: candidate) & netmaskBits) == networkAddressBits
  }

  public var description: String { "\(address)/\(prefixLength)" }
}

extension CIDRBlock: Codable {
  public init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let parsed = CIDRBlock(raw) else {
      throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid CIDR block: \"\(raw)\"")
    }
    self = parsed
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}

/// A minimal, `Equatable` stand-in for `Foundation.OperatingSystemVersion` (which isn't
/// `Equatable` itself), used anywhere a platform version needs to be compared or embedded
/// in an `Equatable` error case.
public struct PlatformVersion: Equatable, Comparable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(major: Int, minor: Int, patch: Int = 0) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public init(_ osVersion: OperatingSystemVersion) {
    self.major = osVersion.majorVersion
    self.minor = osVersion.minorVersion
    self.patch = osVersion.patchVersion
  }

  public static func < (lhs: PlatformVersion, rhs: PlatformVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  public var description: String { "\(major).\(minor).\(patch)" }
}

/// The top-level network mode a VM is configured with. Modes are mutually exclusive:
/// a VM uses exactly one of these at a time. Kept as a plain tag (rather than an enum
/// carrying every mode's parameters) so the validation and persistence layers can reason
/// about "which mode is active" without depending on the concrete `Network` implementations
/// in `Sources/tart/Network`.
public enum NetworkMode: String, Codable, CaseIterable, CustomStringConvertible {
  case nat
  case bridged
  case softnet
  case vmnet

  public var description: String { rawValue }

  /// vmnet is gated to macOS 26+ because `VZVmnetNetworkDeviceAttachment` and the
  /// `vmnet_network_*` custom-topology APIs it depends on were introduced there.
  public var minimumSupportedOSVersion: PlatformVersion? {
    switch self {
    case .vmnet:
      return PlatformVersion(major: 26, minor: 0)
    default:
      return nil
    }
  }
}

/// A single DHCP reservation: a VM's MAC address is guaranteed to be handed the given
/// IPv4 address by vmnet's built-in DHCP server.
public struct Reservation: Codable, Equatable {
  public var macAddress: String
  public var ipAddress: String
  public var hostname: String?

  public init(macAddress: String, ipAddress: String, hostname: String? = nil) {
    self.macAddress = macAddress
    self.ipAddress = ipAddress
    self.hostname = hostname
  }
}

/// Declarative configuration for a vmnet-backed logical network. This is the input to
/// the validation and orchestration layers, and what gets persisted alongside a VM so
/// that `tart ip` can resolve addresses without the caller having to repeat `--net-vmnet-*`
/// flags every time.
public struct VmnetConfig: Codable, Equatable {
  /// Mirrors vmnet's `operating_modes_t`.
  public enum Topology: String, Codable, CaseIterable {
    /// VMNET_SHARED_MODE: NAT'd egress, reachable from the host, DHCP available.
    case shared
    /// VMNET_HOST_MODE: host + other host-mode interfaces only, no egress.
    case host
    /// VMNET_BRIDGED_MODE: bridged directly onto a physical interface.
    case bridged
  }

  public static let currentSchemaVersion = 1

  public var schemaVersion: Int = VmnetConfig.currentSchemaVersion
  public var topology: Topology = .shared
  public var subnet: CIDRBlock?
  public var dhcpEnabled: Bool = true
  public var natEnabled: Bool = true
  public var dnsEnabled: Bool = true
  /// Required, and only meaningful, when `topology == .bridged`.
  public var externalInterface: String?
  public var reservations: [Reservation] = []
  public var mtu: UInt32?
  /// When true, this VM's vmnet interface can't reach other vmnet interfaces,
  /// even ones on the same logical network (`vmnet_enable_isolation_key`).
  public var isolate: Bool = false

  public init(
    topology: Topology = .shared,
    subnet: CIDRBlock? = nil,
    dhcpEnabled: Bool = true,
    natEnabled: Bool = true,
    dnsEnabled: Bool = true,
    externalInterface: String? = nil,
    reservations: [Reservation] = [],
    mtu: UInt32? = nil,
    isolate: Bool = false
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.topology = topology
    self.subnet = subnet
    self.dhcpEnabled = dhcpEnabled
    self.natEnabled = natEnabled
    self.dnsEnabled = dnsEnabled
    self.externalInterface = externalInterface
    self.reservations = reservations
    self.mtu = mtu
    self.isolate = isolate
  }
}

extension VmnetConfig {
  // Swift's synthesized Decodable does *not* fall back to a property's declared default
  // value when a key is missing — it only applies to the memberwise initializer above.
  // Since older on-disk configs (schema version 0) are missing keys that didn't exist
  // yet, migration requires a hand-written `init(from:)` that explicitly treats every
  // field as optional-with-a-default, rather than relying on synthesis.
  private enum CodingKeys: String, CodingKey {
    case schemaVersion, topology, subnet, dhcpEnabled, natEnabled, dnsEnabled, externalInterface, reservations, mtu, isolate
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
    topology = try container.decodeIfPresent(Topology.self, forKey: .topology) ?? .shared
    subnet = try container.decodeIfPresent(CIDRBlock.self, forKey: .subnet)
    dhcpEnabled = try container.decodeIfPresent(Bool.self, forKey: .dhcpEnabled) ?? true
    natEnabled = try container.decodeIfPresent(Bool.self, forKey: .natEnabled) ?? true
    dnsEnabled = try container.decodeIfPresent(Bool.self, forKey: .dnsEnabled) ?? true
    externalInterface = try container.decodeIfPresent(String.self, forKey: .externalInterface)
    reservations = try container.decodeIfPresent([Reservation].self, forKey: .reservations) ?? []
    mtu = try container.decodeIfPresent(UInt32.self, forKey: .mtu)
    isolate = try container.decodeIfPresent(Bool.self, forKey: .isolate) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)

    try container.encode(schemaVersion, forKey: .schemaVersion)
    try container.encode(topology, forKey: .topology)
    try container.encodeIfPresent(subnet, forKey: .subnet)
    try container.encode(dhcpEnabled, forKey: .dhcpEnabled)
    try container.encode(natEnabled, forKey: .natEnabled)
    try container.encode(dnsEnabled, forKey: .dnsEnabled)
    try container.encodeIfPresent(externalInterface, forKey: .externalInterface)
    try container.encode(reservations, forKey: .reservations)
    try container.encodeIfPresent(mtu, forKey: .mtu)
    try container.encode(isolate, forKey: .isolate)
  }
}

/// Live, observed state of a running vmnet interface, as opposed to `VmnetConfig` which
/// is the declared/desired state. Populated by `NetworkVmnet` once the interface starts,
/// and consulted by the IP resolver and diagnostics system.
public struct VmnetRuntimeState: Equatable {
  public var vmName: String
  public var actualSubnet: CIDRBlock?
  public var gatewayAddress: String?
  public var interfaceStartedAt: Date?
  public var lastKnownIPByMAC: [String: String] = [:]
  public var lastError: String?

  public init(vmName: String) {
    self.vmName = vmName
  }
}
