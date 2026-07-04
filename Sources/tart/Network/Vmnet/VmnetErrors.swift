import Foundation

/// Broad classification of a vmnet control-plane failure, used by the orchestration
/// engine to decide whether a failure is worth retrying and by diagnostics to pick a
/// suggested fix. Ordered roughly from "caller's fault" to "environment's fault".
enum FailureCategory: String, Codable, CaseIterable {
  /// Bad flags/CIDR/reservations. Never retryable: the same input will fail again.
  case configuration
  /// Host doesn't meet a hard requirement (e.g. macOS < 26 for vmnet). Never retryable.
  case unsupportedPlatform
  /// vmnet network/interface creation failed at the framework level. Sometimes transient
  /// (framework resource exhaustion, another process racing to create a network).
  case networkAttachment
  /// Couldn't spawn or exec the `tart` binary itself.
  case processLaunch
  /// A step (usually IP resolution) didn't complete within its deadline.
  case timeout
  /// The VM booted and the network attached, but no address could be resolved for it.
  case ipResolutionFailed
  /// The `tart run` child process exited unexpectedly.
  case processCrashed
  case unknown

  /// Whether the orchestration engine should retry the startup flow after this failure.
  var isRetryable: Bool {
    switch self {
    case .networkAttachment, .timeout, .processCrashed:
      return true
    case .configuration, .unsupportedPlatform, .processLaunch, .ipResolutionFailed, .unknown:
      return false
    }
  }
}

/// The full error taxonomy for the vmnet control plane. Every case carries enough
/// context to be turned into both a one-line CLI error and a detailed diagnostic entry.
enum VmnetError: Error, Equatable {
  // Validation layer
  case invalidCIDR(raw: String)
  case reservationOutsideSubnet(reservation: Reservation, subnet: CIDRBlock)
  case reservationIsNetworkOrBroadcastAddress(reservation: Reservation, subnet: CIDRBlock)
  case duplicateReservation(macAddress: String)
  case reservationIPCollision(ipAddress: String, macAddresses: [String])
  case invalidMACAddress(raw: String)
  case invalidReservationIPAddress(raw: String)
  case missingExternalInterface
  case dhcpDisabledWithReservations
  case mutuallyExclusiveNetworkModes(requested: [NetworkMode])
  case unsupportedOSVersion(required: PlatformVersion, current: PlatformVersion)

  // Runtime / orchestration layer
  case networkConfigurationFailed(underlying: String)
  case networkCreationFailed(underlying: String)
  case interfaceStartFailed(underlying: String)
  case processLaunchFailed(underlying: String)
  case processExitedUnexpectedly(exitCode: Int32, stderrTail: String)
  case startupTimedOut(afterSeconds: Int)
  case noIPAddressResolved(vmName: String, attempts: [IPResolutionAttempt])
  case networkConfigMissing(vmName: String)
  case unsupportedSchemaVersion(found: Int, newestSupported: Int)

  var category: FailureCategory {
    switch self {
    case .invalidCIDR, .reservationOutsideSubnet, .reservationIsNetworkOrBroadcastAddress,
         .duplicateReservation, .reservationIPCollision, .invalidMACAddress,
         .invalidReservationIPAddress, .missingExternalInterface, .dhcpDisabledWithReservations,
         .mutuallyExclusiveNetworkModes, .networkConfigMissing, .unsupportedSchemaVersion:
      return .configuration
    case .unsupportedOSVersion:
      return .unsupportedPlatform
    case .networkConfigurationFailed, .networkCreationFailed, .interfaceStartFailed:
      return .networkAttachment
    case .processLaunchFailed:
      return .processLaunch
    case .processExitedUnexpectedly:
      return .processCrashed
    case .startupTimedOut:
      return .timeout
    case .noIPAddressResolved:
      return .ipResolutionFailed
    }
  }
}

extension VmnetError: CustomStringConvertible {
  var description: String {
    switch self {
    case .invalidCIDR(let raw):
      return "\"\(raw)\" is not a valid IPv4 CIDR block (expected form: 192.168.64.0/24)"
    case .reservationOutsideSubnet(let reservation, let subnet):
      return "reservation \(reservation.macAddress) -> \(reservation.ipAddress) falls outside of subnet \(subnet)"
    case .reservationIsNetworkOrBroadcastAddress(let reservation, let subnet):
      return "reservation \(reservation.macAddress) -> \(reservation.ipAddress) is the network or broadcast address of \(subnet), and can't be assigned to a host"
    case .duplicateReservation(let macAddress):
      return "MAC address \(macAddress) has more than one reservation"
    case .reservationIPCollision(let ipAddress, let macAddresses):
      return "IP address \(ipAddress) is reserved for multiple MAC addresses: \(macAddresses.joined(separator: ", "))"
    case .invalidMACAddress(let raw):
      return "\"\(raw)\" is not a valid MAC address (expected form: aa:bb:cc:dd:ee:ff)"
    case .invalidReservationIPAddress(let raw):
      return "\"\(raw)\" is not a valid IPv4 address"
    case .missingExternalInterface:
      return "vmnet bridged topology requires --net-vmnet-bridge=<interface> to be set"
    case .dhcpDisabledWithReservations:
      return "DHCP reservations were specified, but DHCP is disabled (--net-vmnet-no-dhcp)"
    case .mutuallyExclusiveNetworkModes(let requested):
      return "network modes are mutually exclusive, but multiple were requested: \(requested.map(\.description).joined(separator: ", "))"
    case .unsupportedOSVersion(let required, let current):
      return "vmnet networking requires macOS \(required.major).\(required.minor) or newer, "
        + "but this host is running macOS \(current)"
    case .networkConfigurationFailed(let underlying):
      return "failed to build the vmnet network configuration: \(underlying)"
    case .networkCreationFailed(let underlying):
      return "failed to create the vmnet logical network: \(underlying)"
    case .interfaceStartFailed(let underlying):
      return "failed to start the vmnet interface: \(underlying)"
    case .processLaunchFailed(let underlying):
      return "failed to launch \"tart run\": \(underlying)"
    case .processExitedUnexpectedly(let exitCode, let stderrTail):
      return "\"tart run\" exited unexpectedly with code \(exitCode)" + (stderrTail.isEmpty ? "" : ": \(stderrTail)")
    case .startupTimedOut(let afterSeconds):
      return "VM startup did not complete within \(afterSeconds)s"
    case .noIPAddressResolved(let vmName, let attempts):
      let tried = attempts.map(\.strategy.rawValue).joined(separator: " -> ")
      return "no IP address could be resolved for VM \"\(vmName)\" (tried: \(tried))"
    case .networkConfigMissing(let vmName):
      return "VM \"\(vmName)\" has no persisted vmnet network configuration"
    case .unsupportedSchemaVersion(let found, let newestSupported):
      return "persisted vmnet configuration uses schema version \(found), but this build of Tart only understands up to version \(newestSupported)"
    }
  }
}

extension VmnetError: HasExitCode {
  var exitCode: Int32 {
    switch category {
    case .configuration, .unsupportedPlatform:
      return 64 // EX_USAGE
    case .networkAttachment, .processLaunch, .processCrashed:
      return 69 // EX_UNAVAILABLE
    case .timeout:
      return 75 // EX_TEMPFAIL
    case .ipResolutionFailed, .unknown:
      return 1
    }
  }
}

/// One suggested remediation for a `VmnetError`, surfaced by the diagnostics system.
func suggestedFix(for error: VmnetError) -> String {
  switch error {
  case .invalidCIDR:
    return "Pass a CIDR in the form <network-address>/<prefix-length>, e.g. --net-vmnet-subnet=192.168.64.0/24"
  case .reservationOutsideSubnet, .reservationIsNetworkOrBroadcastAddress:
    return "Pick a reservation address strictly inside the configured subnet's usable host range"
  case .duplicateReservation:
    return "Remove the duplicate --net-vmnet-reserve entry for this MAC address"
  case .reservationIPCollision:
    return "Give each reservation a unique IP address"
  case .invalidMACAddress:
    return "Use the aa:bb:cc:dd:ee:ff format for MAC addresses"
  case .invalidReservationIPAddress:
    return "Use dotted-decimal IPv4 notation for reservation addresses"
  case .missingExternalInterface:
    return "Add --net-vmnet-bridge=<interface> (see \"tart run --net-vmnet-bridge=list\")"
  case .dhcpDisabledWithReservations:
    return "Either drop --net-vmnet-no-dhcp or remove the --net-vmnet-reserve entries"
  case .mutuallyExclusiveNetworkModes:
    return "Pick exactly one of --net-bridged, --net-softnet, --net-host or --net-vmnet"
  case .unsupportedOSVersion:
    return "Use --net-bridged, --net-softnet or the default NAT networking on this host instead of --net-vmnet"
  case .networkConfigurationFailed, .networkCreationFailed, .interfaceStartFailed:
    return "Ensure no other vmnet network claims the same subnet, and that the running binary carries the vmnet entitlement"
  case .processLaunchFailed:
    return "Confirm the \"tart\" binary is on PATH and executable"
  case .processExitedUnexpectedly:
    return "Inspect the captured stderr tail above, or re-run with \"tart run\" directly for full output"
  case .startupTimedOut:
    return "Increase the startup timeout, or check whether the guest OS is stuck at boot (VNC into it)"
  case .noIPAddressResolved:
    return "Confirm the guest's network stack came up, and that a DHCP reservation (if any) matches its actual MAC address"
  case .networkConfigMissing:
    return "Re-run \"tart run\" with --net-vmnet at least once so its network configuration gets persisted"
  case .unsupportedSchemaVersion:
    return "Upgrade Tart, or delete the VM's netVmnet.json and re-run \"tart run\" with --net-vmnet to regenerate it"
  }
}
