import Foundation

/// One vmnet-backed VM's worth of state, as tracked by `VmnetStateStore`: what was
/// requested (`config`), and what's actually been observed (`runtimeState`).
struct VmnetStateEntry {
  var config: VmnetConfig
  var macAddress: String?
  var runtimeState: VmnetRuntimeState
}

/// A single VM's network endpoint, as seen from the outside — this is the shape a
/// Network Extension (or any other policy enforcement point) actually cares about: which
/// VM, which MAC, which IP, on which subnet.
struct EndpointMapping: Equatable {
  let vmName: String
  let macAddress: String?
  let ipAddress: String?
  let subnet: CIDRBlock?
}

/// The read side of the state layer, exposed as a narrow protocol so a Network Extension
/// (or a policy engine, or a test) can depend on just these three queries instead of the
/// full read/write `VmnetStateStore` API. This is "Policy Integration Hooks" (goal 6):
/// get active subnet(s), get VM IPs, get endpoint mappings.
protocol VmnetPolicyProvider {
  func activeSubnets() async -> [CIDRBlock]
  func vmIPAddresses() async -> [String: String]
  func endpointMappings() async -> [EndpointMapping]
}

/// The control plane's State layer: an in-process, thread-safe registry of every
/// vmnet-backed VM's declared configuration and observed runtime state. `NetworkVmnet`
/// writes to it as VMs start/stop; `VmnetIPResolver` and `VmnetDiagnostics` read from it;
/// and it doubles as the `VmnetPolicyProvider` implementation consulted by policy
/// integration hooks.
///
/// Deliberately an in-process actor rather than e.g. a file or XPC service: today's
/// integration point is a single `tart` process per VM, so cross-process sharing isn't
/// needed yet. `VmnetPersistence` is the durable side (survives process restarts);
/// this is the live side (reflects what's actually running right now).
actor VmnetStateStore {
  static let shared = VmnetStateStore()

  private var entries: [String: VmnetStateEntry] = [:]

  func publish(vmName: String, config: VmnetConfig, macAddress: String?) {
    var entry = entries[vmName] ?? VmnetStateEntry(config: config, macAddress: macAddress, runtimeState: VmnetRuntimeState(vmName: vmName))
    entry.config = config
    entry.macAddress = macAddress ?? entry.macAddress
    entries[vmName] = entry
  }

  func update(_ state: VmnetRuntimeState) {
    var entry = entries[state.vmName] ?? VmnetStateEntry(config: VmnetConfig(), macAddress: nil, runtimeState: state)
    entry.runtimeState = state
    entries[state.vmName] = entry
  }

  /// Records an IP address resolved for `vmName` (typically by `VmnetIPResolver`), so
  /// subsequent policy queries and diagnostics reflect the latest known address without
  /// having to re-run resolution.
  func recordResolvedIP(vmName: String, ipAddress: String) {
    guard var entry = entries[vmName], let mac = entry.macAddress else { return }
    entry.runtimeState.lastKnownIPByMAC[mac] = ipAddress
    entries[vmName] = entry
  }

  func remove(vmName: String) {
    entries.removeValue(forKey: vmName)
  }

  func entry(for vmName: String) -> VmnetStateEntry? {
    entries[vmName]
  }

  func runtimeState(for vmName: String) -> VmnetRuntimeState? {
    entries[vmName]?.runtimeState
  }

  func config(for vmName: String) -> VmnetConfig? {
    entries[vmName]?.config
  }

  func allEntries() -> [String: VmnetStateEntry] {
    entries
  }
}

extension VmnetStateStore: VmnetPolicyProvider {
  func activeSubnets() async -> [CIDRBlock] {
    Array(Swift.Set(entries.values.compactMap { $0.runtimeState.actualSubnet ?? $0.config.subnet }))
  }

  func vmIPAddresses() async -> [String: String] {
    var result: [String: String] = [:]
    for (vmName, entry) in entries {
      if let mac = entry.macAddress, let ip = entry.runtimeState.lastKnownIPByMAC[mac] {
        result[vmName] = ip
      }
    }
    return result
  }

  func endpointMappings() async -> [EndpointMapping] {
    entries.map { vmName, entry in
      EndpointMapping(
        vmName: vmName,
        macAddress: entry.macAddress,
        ipAddress: entry.macAddress.flatMap { entry.runtimeState.lastKnownIPByMAC[$0] },
        subnet: entry.runtimeState.actualSubnet ?? entry.config.subnet
      )
    }
  }
}
