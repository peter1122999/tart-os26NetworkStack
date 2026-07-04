import Foundation
import Network

/// A parsed IPv4 CIDR block, e.g. "192.168.64.0/24".
///
/// This intentionally doesn't depend on the `vmnet` framework so it can be validated
/// and unit tested on any host, including ones running an older macOS.
struct CIDRBlock: Equatable, Hashable, CustomStringConvertible {
  let address: IPv4Address
  let prefixLength: Int

  init(address: IPv4Address, prefixLength: Int) {
    self.address = address
    self.prefixLength = prefixLength
  }

  init?(_ raw: String) {
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

  var networkAddressBits: UInt32 {
    Self.bits(of: address) & netmaskBits
  }

  var broadcastAddressBits: UInt32 {
    networkAddressBits | ~netmaskBits
  }

  var subnetMask: IPv4Address {
    IPv4Address(Data([
      UInt8((netmaskBits >> 24) & 0xff),
      UInt8((netmaskBits >> 16) & 0xff),
      UInt8((netmaskBits >> 8) & 0xff),
      UInt8(netmaskBits & 0xff),
    ]))!
  }

  /// The network address of this block, e.g. "192.168.64.0" for "192.168.64.10/24".
  var networkAddress: IPv4Address {
    IPv4Address(Data([
      UInt8((networkAddressBits >> 24) & 0xff),
      UInt8((networkAddressBits >> 16) & 0xff),
      UInt8((networkAddressBits >> 8) & 0xff),
      UInt8(networkAddressBits & 0xff),
    ]))!
  }

  /// Host addresses usable for DHCP pools/reservations, excluding the network
  /// and broadcast addresses for prefixes shorter than /31.
  var usableHostRange: ClosedRange<UInt32>? {
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

  func contains(_ candidate: IPv4Address) -> Bool {
    (Self.bits(of: candidate) & netmaskBits) == networkAddressBits
  }

  var description: String { "\(address)/\(prefixLength)" }
}

extension CIDRBlock: Codable {
  init(from decoder: Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    guard let parsed = CIDRBlock(raw) else {
      throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid CIDR block: \"\(raw)\"")
    }
    self = parsed
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(description)
  }
}

/// A minimal, `Equatable` stand-in for `Foundation.OperatingSystemVersion` (which isn't
/// `Equatable` itself), used anywhere a platform version needs to be compared or embedded
/// in an `Equatable` error case.
struct PlatformVersion: Equatable, Comparable, CustomStringConvertible {
  let major: Int
  let minor: Int
  let patch: Int

  init(major: Int, minor: Int, patch: Int = 0) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  init(_ osVersion: OperatingSystemVersion) {
    self.major = osVersion.majorVersion
    self.minor = osVersion.minorVersion
    self.patch = osVersion.patchVersion
  }

  static func < (lhs: PlatformVersion, rhs: PlatformVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }

  var description: String { "\(major).\(minor).\(patch)" }
}

/// The top-level network mode a VM is configured with. Modes are mutually exclusive:
/// a VM uses exactly one of these at a time. Kept as a plain tag (rather than an enum
/// carrying every mode's parameters) so the validation and persistence layers can reason
/// about "which mode is active" without depending on the concrete `Network` implementations
/// in `Sources/tart/Network`.
enum NetworkMode: String, Codable, CaseIterable, CustomStringConvertible {
  case nat
  case bridged
  case softnet
  case vmnet

  var description: String { rawValue }

  /// vmnet is gated to macOS 26+ because `VZVmnetNetworkDeviceAttachment` and the
  /// `vmnet_network_*` custom-topology APIs it depends on were introduced there.
  var minimumSupportedOSVersion: PlatformVersion? {
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
struct Reservation: Codable, Equatable {
  var macAddress: String
  var ipAddress: String
  var hostname: String?

  init(macAddress: String, ipAddress: String, hostname: String? = nil) {
    self.macAddress = macAddress
    self.ipAddress = ipAddress
    self.hostname = hostname
  }
}

/// Declarative configuration for a vmnet-backed logical network. This is the input to
/// the validation and orchestration layers, and what gets persisted alongside a VM so
/// that `tart ip` can resolve addresses without the caller having to repeat `--net-vmnet-*`
/// flags every time.
struct VmnetConfig: Codable, Equatable {
  /// Mirrors vmnet's `operating_modes_t`.
  enum Topology: String, Codable {
    /// VMNET_SHARED_MODE: NAT'd egress, reachable from the host, DHCP available.
    case shared
    /// VMNET_HOST_MODE: host + other host-mode interfaces only, no egress.
    case host
    /// VMNET_BRIDGED_MODE: bridged directly onto a physical interface.
    case bridged
  }

  static let currentSchemaVersion = 1

  var schemaVersion: Int = VmnetConfig.currentSchemaVersion
  var topology: Topology = .shared
  var subnet: CIDRBlock?
  var dhcpEnabled: Bool = true
  var natEnabled: Bool = true
  var dnsEnabled: Bool = true
  /// Required, and only meaningful, when `topology == .bridged`.
  var externalInterface: String?
  var reservations: [Reservation] = []
  var mtu: UInt32?
  /// When true, this VM's vmnet interface can't reach other vmnet interfaces,
  /// even ones on the same logical network (`vmnet_enable_isolation_key`).
  var isolate: Bool = false

  init(
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

  init(from decoder: Decoder) throws {
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

  func encode(to encoder: Encoder) throws {
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
struct VmnetRuntimeState: Equatable {
  var vmName: String
  var actualSubnet: CIDRBlock?
  var gatewayAddress: String?
  var interfaceStartedAt: Date?
  var lastKnownIPByMAC: [String: String] = [:]
  var lastError: String?

  init(vmName: String) {
    self.vmName = vmName
  }
}
