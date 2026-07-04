import XCTest
@testable import tart

import Network

final class VmnetIPResolverTests: XCTestCase {
  private let mac = MACAddress(fromString: "52:54:00:11:22:33")!

  func testReservationWinsOverEverythingElse() async throws {
    let config = VmnetConfig(reservations: [Reservation(macAddress: "52:54:00:11:22:33", ipAddress: "192.168.64.10")])
    let resolver = VmnetIPResolver(
      runtimeLookup: MockRuntimeLookup(result: IPv4Address("192.168.64.99")),
      legacyResolver: MockLegacyResolver(result: IPv4Address("192.168.64.200"))
    )

    let outcome = try await resolver.resolve(macAddress: mac, config: config, runtimeState: nil)

    XCTAssertEqual(outcome.address, IPv4Address("192.168.64.10"))
    XCTAssertEqual(outcome.attempts.first?.strategy, .dhcpReservation)
    XCTAssertTrue(outcome.attempts.first!.succeeded)
    // Short-circuited: the other tiers should never have been consulted.
    XCTAssertEqual(outcome.attempts.count, 1)
  }

  func testFallsThroughToRuntimeLookupWithoutReservation() async throws {
    let resolver = VmnetIPResolver(
      runtimeLookup: MockRuntimeLookup(result: IPv4Address("192.168.64.55")),
      legacyResolver: MockLegacyResolver(result: nil)
    )

    let outcome = try await resolver.resolve(macAddress: mac, config: VmnetConfig(), runtimeState: nil)

    XCTAssertEqual(outcome.address, IPv4Address("192.168.64.55"))
    XCTAssertEqual(outcome.attempts.last?.strategy, .vmnetRuntimeLookup)
    XCTAssertTrue(outcome.attempts.last!.succeeded)
  }

  func testFallsThroughToLegacyResolverAsLastResort() async throws {
    let resolver = VmnetIPResolver(
      runtimeLookup: MockRuntimeLookup(result: nil),
      legacyResolver: MockLegacyResolver(result: IPv4Address("10.0.0.5"))
    )

    let outcome = try await resolver.resolve(macAddress: mac, config: VmnetConfig(), runtimeState: nil)

    XCTAssertEqual(outcome.address, IPv4Address("10.0.0.5"))
    XCTAssertEqual(outcome.attempts.map(\.strategy), [.dhcpReservation, .vmnetRuntimeLookup, .legacyFallback])
    XCTAssertTrue(outcome.attempts.last!.succeeded)
  }

  func testAllTiersFailingReturnsNilWithFullTrail() async throws {
    let resolver = VmnetIPResolver(
      runtimeLookup: MockRuntimeLookup(result: nil),
      legacyResolver: MockLegacyResolver(result: nil)
    )

    let outcome = try await resolver.resolve(macAddress: mac, config: VmnetConfig(), runtimeState: nil)

    XCTAssertNil(outcome.address)
    XCTAssertFalse(outcome.succeeded)
    XCTAssertEqual(outcome.attempts.count, 3)
    XCTAssertTrue(outcome.attempts.allSatisfy { !$0.succeeded })
  }

  func testRuntimeLookupIsScopedToActualSubnetWhenAvailable() async throws {
    var capturedSubnet: CIDRBlock?

    struct CapturingLookup: VmnetRuntimeLookup {
      let onLookup: (CIDRBlock?) -> Void
      func lookupIPAddress(forMAC mac: String, scopedTo subnet: CIDRBlock?) throws -> IPv4Address? {
        onLookup(subnet)
        return nil
      }
    }

    let resolver = VmnetIPResolver(
      runtimeLookup: CapturingLookup { capturedSubnet = $0 },
      legacyResolver: MockLegacyResolver(result: nil)
    )

    var runtimeState = VmnetRuntimeState(vmName: "test-vm")
    runtimeState.actualSubnet = CIDRBlock("172.16.0.0/24")

    let config = VmnetConfig(subnet: CIDRBlock("192.168.64.0/24"))
    _ = try await resolver.resolve(macAddress: mac, config: config, runtimeState: runtimeState)

    // The *observed* runtime subnet should win over the merely *configured* one, since
    // vmnet may have auto-assigned something different than what was requested.
    XCTAssertEqual(capturedSubnet, CIDRBlock("172.16.0.0/24"))
  }
}
