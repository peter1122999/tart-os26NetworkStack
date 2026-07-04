import Foundation
import Network

/// The tiers tried, in order, by `VmnetIPResolver`. Mirrors the "Priority" list from the
/// vmnet control plane design: a static DHCP reservation is authoritative and free (no
/// I/O needed), a vmnet runtime lookup is scoped and fast, and the legacy `tart ip`
/// resolvers (dhcpd leases / ARP / guest agent) are the least specific but work for
/// every network mode, including non-vmnet ones.
public enum IPResolutionTier: String, Codable, CaseIterable, Equatable {
  case dhcpReservation = "dhcp-reservation"
  case vmnetRuntimeLookup = "vmnet-runtime-lookup"
  case legacyFallback = "legacy-fallback"
}

/// A single resolution attempt, kept around for diagnostics regardless of whether it
/// succeeded, so `tart ip` failures can show exactly what was tried and why it didn't work.
public struct IPResolutionAttempt: Equatable {
  public let strategy: IPResolutionTier
  public let succeeded: Bool
  public let detail: String
}

/// Result of a full resolution pass: the winning address (if any) plus the full trail of
/// attempts, so callers can both use the address and explain how it was found.
public struct IPResolutionOutcome {
  public let address: IPv4Address?
  public let attempts: [IPResolutionAttempt]

  public var succeeded: Bool { address != nil }
}

/// Scoped runtime lookup against a live vmnet network: "given this MAC address and the
/// subnet vmnet actually assigned, what IP does it currently have?" Abstracted behind a
/// protocol so tests can substitute a deterministic mock instead of shelling out to `arp`.
public protocol VmnetRuntimeLookup {
  func lookupIPAddress(forMAC mac: String, scopedTo subnet: CIDRBlock?) throws -> IPv4Address?
}

/// Default runtime lookup: vmnet doesn't expose a "get DHCP lease for this MAC" query, so
/// this falls back to the host's ARP table (populated once the guest sends its first
/// packet), restricted to the subnet vmnet reported via `vmnet_network_get_ipv4_subnet`
/// to avoid matching an unrelated interface's ARP entry for the same MAC.
public struct ARPScopedVmnetRuntimeLookup: VmnetRuntimeLookup {
  public init() {}

  public func lookupIPAddress(forMAC mac: String, scopedTo subnet: CIDRBlock?) throws -> IPv4Address? {
    guard let macAddress = MACAddress(fromString: mac) else { return nil }
    guard let candidate = try ARPCache().ResolveMACAddress(macAddress: macAddress) else { return nil }

    if let subnet = subnet, !subnet.contains(candidate) {
      return nil
    }

    return candidate
  }
}

/// Legacy fallback: the resolvers `tart ip` already ships (dhcpd leases file, ARP, guest
/// agent). Abstracted so this module doesn't have to depend on the CLI-only `IP` command
/// (which lives in the "tart" executable target, not here) — the executable supplies its
/// own `LegacyIPResolving` implementation when it constructs a `VmnetIPResolver`.
public protocol LegacyIPResolving {
  func resolve(_ macAddress: MACAddress, strategy: IPResolutionStrategy, secondsToWait: UInt16, controlSocketURL: URL?) async throws -> IPv4Address?
}

/// The default used when nothing more specific is injected (e.g. by callers that only
/// care about the reservation and vmnet-runtime-lookup tiers, such as the vmnet manager
/// GUI). Always returns nil, so tier 3 simply never succeeds rather than reaching into
/// filesystem/socket state this module has no business touching.
public struct NullLegacyIPResolver: LegacyIPResolving {
  public init() {}

  public func resolve(_ macAddress: MACAddress, strategy: IPResolutionStrategy, secondsToWait: UInt16, controlSocketURL: URL?) async throws -> IPv4Address? {
    nil
  }
}

/// Implements the vmnet IP resolution priority: reservation, then vmnet runtime lookup,
/// then the pre-existing `tart ip` resolvers. Every tier's outcome is recorded, so a
/// caller that gets `nil` back still has a full diagnostic trail to show the user.
public struct VmnetIPResolver {
  let runtimeLookup: VmnetRuntimeLookup
  let legacyResolver: LegacyIPResolving

  public init(runtimeLookup: VmnetRuntimeLookup = ARPScopedVmnetRuntimeLookup(), legacyResolver: LegacyIPResolving = NullLegacyIPResolver()) {
    self.runtimeLookup = runtimeLookup
    self.legacyResolver = legacyResolver
  }

  public func resolve(
    macAddress: MACAddress,
    config: VmnetConfig?,
    runtimeState: VmnetRuntimeState?,
    legacyStrategy: IPResolutionStrategy = .dhcp,
    controlSocketURL: URL? = nil
  ) async throws -> IPResolutionOutcome {
    var attempts: [IPResolutionAttempt] = []

    // Tier 1: an explicit DHCP reservation is authoritative and needs no I/O at all.
    if let config = config, let reservation = config.reservations.first(where: {
      VmnetValidator.normalizeMACAddress($0.macAddress) == VmnetValidator.normalizeMACAddress(macAddress.description)
    }) {
      if let ip = IPv4Address(reservation.ipAddress) {
        attempts.append(IPResolutionAttempt(strategy: .dhcpReservation, succeeded: true, detail: "static reservation \(reservation.ipAddress)"))
        return IPResolutionOutcome(address: ip, attempts: attempts)
      } else {
        attempts.append(IPResolutionAttempt(strategy: .dhcpReservation, succeeded: false, detail: "reservation \(reservation.ipAddress) failed to parse"))
      }
    } else {
      attempts.append(IPResolutionAttempt(strategy: .dhcpReservation, succeeded: false, detail: "no matching reservation configured"))
    }

    // Tier 2: ask the vmnet runtime, scoped to whatever subnet it actually assigned.
    let scopeSubnet = runtimeState?.actualSubnet ?? config?.subnet
    do {
      if let ip = try runtimeLookup.lookupIPAddress(forMAC: macAddress.description, scopedTo: scopeSubnet) {
        attempts.append(IPResolutionAttempt(strategy: .vmnetRuntimeLookup, succeeded: true, detail: "resolved via vmnet-scoped ARP lookup"))
        return IPResolutionOutcome(address: ip, attempts: attempts)
      } else {
        attempts.append(IPResolutionAttempt(strategy: .vmnetRuntimeLookup, succeeded: false, detail: "no ARP entry found within \(scopeSubnet?.description ?? "an unknown subnet")"))
      }
    } catch {
      attempts.append(IPResolutionAttempt(strategy: .vmnetRuntimeLookup, succeeded: false, detail: "lookup failed: \(error)"))
    }

    // Tier 3: fall back to the resolvers `tart ip` already supports.
    do {
      if let ip = try await legacyResolver.resolve(macAddress, strategy: legacyStrategy, secondsToWait: 0, controlSocketURL: controlSocketURL) {
        attempts.append(IPResolutionAttempt(strategy: .legacyFallback, succeeded: true, detail: "resolved via legacy \"\(legacyStrategy.rawValue)\" strategy"))
        return IPResolutionOutcome(address: ip, attempts: attempts)
      } else {
        attempts.append(IPResolutionAttempt(strategy: .legacyFallback, succeeded: false, detail: "legacy \"\(legacyStrategy.rawValue)\" strategy found nothing"))
      }
    } catch {
      attempts.append(IPResolutionAttempt(strategy: .legacyFallback, succeeded: false, detail: "legacy resolver failed: \(error)"))
    }

    return IPResolutionOutcome(address: nil, attempts: attempts)
  }

  /// Compares tiers' outcomes for the same MAC to flag disagreement between, say, a
  /// stale reservation and what the guest is actually using — a common vmnet misconfig
  /// symptom (DHCP client ignored the reservation, or the guest has a static IP set).
  public static func detectInconsistency(_ attempts: [IPResolutionAttempt]) -> String? {
    let successes = attempts.filter(\.succeeded)
    guard successes.count > 1 else { return nil }

    // All successful tiers should have agreed on the same address as the one we returned
    // (Tier 1 short-circuits, so in practice this only fires if a caller re-runs individual
    // tiers out of order; kept for diagnostics completeness).
    let distinctDetails = Swift.Set(successes.map(\.detail))
    if distinctDetails.count > 1 {
      return "multiple resolution tiers succeeded with different results: \(successes.map { "\($0.strategy.rawValue)=\($0.detail)" }.joined(separator: ", "))"
    }

    return nil
  }
}
