import Foundation
import Network

/// Structured result of running the validation engine: either a config that's safe to
/// hand to the orchestrator, or a non-empty list of everything that's wrong with it.
///
/// Deliberately collects *all* violations instead of throwing on the first one, so a
/// caller (CLI or otherwise) can report every problem in one pass instead of a
/// fix-one-rerun-repeat loop.
struct VmnetValidationResult {
  let errors: [VmnetError]

  var isValid: Bool { errors.isEmpty }

  func throwIfInvalid() throws {
    if let first = errors.first {
      throw first
    }
  }
}

/// Validates `VmnetConfig` values and their interaction with the rest of a VM's network
/// configuration, independent of whether vmnet is actually being used to run anything.
/// Pure and host-independent except for the macOS version check, so it's fully unit
/// testable without a real vmnet-capable host.
enum VmnetValidator {
  /// `osVersion` is injectable for testing; defaults to the real host version.
  static func validate(
    _ config: VmnetConfig,
    osVersion: PlatformVersion = PlatformVersion(ProcessInfo.processInfo.operatingSystemVersion)
  ) -> VmnetValidationResult {
    var errors: [VmnetError] = []

    if let required = NetworkMode.vmnet.minimumSupportedOSVersion, osVersion < required {
      errors.append(.unsupportedOSVersion(required: required, current: osVersion))
    }

    if config.topology == .bridged && (config.externalInterface?.isEmpty ?? true) {
      errors.append(.missingExternalInterface)
    }

    if !config.dhcpEnabled && !config.reservations.isEmpty {
      errors.append(.dhcpDisabledWithReservations)
    }

    errors.append(contentsOf: validateReservations(config.reservations, subnet: config.subnet))

    return VmnetValidationResult(errors: errors)
  }

  /// Validates that every reservation has a well-formed MAC/IP pair, that no MAC or IP
  /// address is reserved twice, and — when a subnet is known — that every reservation
  /// actually falls within its usable host range.
  static func validateReservations(_ reservations: [Reservation], subnet: CIDRBlock?) -> [VmnetError] {
    var errors: [VmnetError] = []

    var seenByMAC: [String: Reservation] = [:]
    var seenByIP: [String: [String]] = [:]

    for reservation in reservations {
      guard let normalizedMAC = normalizeMACAddress(reservation.macAddress) else {
        errors.append(.invalidMACAddress(raw: reservation.macAddress))
        continue
      }

      guard let ip = IPv4Address(reservation.ipAddress) else {
        errors.append(.invalidReservationIPAddress(raw: reservation.ipAddress))
        continue
      }

      if seenByMAC[normalizedMAC] != nil {
        errors.append(.duplicateReservation(macAddress: normalizedMAC))
      } else {
        seenByMAC[normalizedMAC] = reservation
      }

      seenByIP[reservation.ipAddress, default: []].append(normalizedMAC)

      if let subnet = subnet {
        if !subnet.contains(ip) {
          errors.append(.reservationOutsideSubnet(reservation: reservation, subnet: subnet))
        } else if let usableRange = subnet.usableHostRange {
          let bits = ip.rawValue.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
          if !usableRange.contains(bits) {
            errors.append(.reservationIsNetworkOrBroadcastAddress(reservation: reservation, subnet: subnet))
          }
        }
      }
    }

    for (ip, macs) in seenByIP where macs.count > 1 {
      errors.append(.reservationIPCollision(ipAddress: ip, macAddresses: macs))
    }

    return errors
  }

  /// Lowercases and validates a MAC address string without the force-unwrapping
  /// `MACAddress.init(fromString:)` does internally on malformed hex components.
  static func normalizeMACAddress(_ raw: String) -> String? {
    let components = raw.lowercased().components(separatedBy: ":")
    guard components.count == 6 else { return nil }

    for component in components {
      guard component.count == 2, UInt8(component, radix: 16) != nil else { return nil }
    }

    return components.joined(separator: ":")
  }

  /// Enforces that at most one of the CLI-facing network flags/modes is active at a time.
  /// `tart run` already performs an equivalent check for its legacy flags (nat/bridged/
  /// softnet/host); this variant additionally understands vmnet so the two can be merged.
  static func validateExclusivity(_ requestedModes: [NetworkMode]) -> VmnetValidationResult {
    let distinct = Swift.Set(requestedModes)
    if distinct.count > 1 {
      return VmnetValidationResult(errors: [.mutuallyExclusiveNetworkModes(requested: Array(distinct))])
    }
    return VmnetValidationResult(errors: [])
  }
}

