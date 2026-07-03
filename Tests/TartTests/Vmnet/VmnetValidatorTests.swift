import XCTest
@testable import tart

final class VmnetValidatorTests: XCTestCase {
  private let supportedOS = PlatformVersion(major: 26, minor: 0)
  private let unsupportedOS = PlatformVersion(major: 15, minor: 4)

  func testValidConfigPasses() {
    let config = VmnetConfig(
      subnet: CIDRBlock("192.168.64.0/24"),
      reservations: [Reservation(macAddress: "52:54:00:11:22:33", ipAddress: "192.168.64.10")]
    )

    let result = VmnetValidator.validate(config, osVersion: supportedOS)
    XCTAssertTrue(result.isValid, "\(result.errors)")
  }

  func testFailsFastOnUnsupportedOS() {
    let result = VmnetValidator.validate(VmnetConfig(), osVersion: unsupportedOS)

    XCTAssertFalse(result.isValid)
    XCTAssertEqual(result.errors.first?.category, .unsupportedPlatform)
  }

  func testBridgedTopologyRequiresExternalInterface() {
    let config = VmnetConfig(topology: .bridged)
    let result = VmnetValidator.validate(config, osVersion: supportedOS)

    XCTAssertEqual(result.errors, [.missingExternalInterface])
  }

  func testReservationOutsideSubnetIsRejected() {
    let config = VmnetConfig(
      subnet: CIDRBlock("192.168.64.0/24"),
      reservations: [Reservation(macAddress: "52:54:00:11:22:33", ipAddress: "10.0.0.5")]
    )

    let result = VmnetValidator.validate(config, osVersion: supportedOS)

    guard case .reservationOutsideSubnet = result.errors.first else {
      return XCTFail("expected .reservationOutsideSubnet, got \(result.errors)")
    }
  }

  func testReservationOnNetworkAddressIsRejected() {
    let config = VmnetConfig(
      subnet: CIDRBlock("192.168.64.0/24"),
      reservations: [Reservation(macAddress: "52:54:00:11:22:33", ipAddress: "192.168.64.0")]
    )

    let result = VmnetValidator.validate(config, osVersion: supportedOS)

    guard case .reservationIsNetworkOrBroadcastAddress = result.errors.first else {
      return XCTFail("expected .reservationIsNetworkOrBroadcastAddress, got \(result.errors)")
    }
  }

  func testDuplicateMACReservationIsRejected() {
    let config = VmnetConfig(
      subnet: CIDRBlock("192.168.64.0/24"),
      reservations: [
        Reservation(macAddress: "52:54:00:11:22:33", ipAddress: "192.168.64.10"),
        Reservation(macAddress: "52:54:00:11:22:33", ipAddress: "192.168.64.11"),
      ]
    )

    let result = VmnetValidator.validate(config, osVersion: supportedOS)
    XCTAssertTrue(result.errors.contains(.duplicateReservation(macAddress: "52:54:00:11:22:33")))
  }

  func testCollidingIPReservationsAreRejected() {
    let config = VmnetConfig(
      subnet: CIDRBlock("192.168.64.0/24"),
      reservations: [
        Reservation(macAddress: "52:54:00:11:22:33", ipAddress: "192.168.64.10"),
        Reservation(macAddress: "52:54:00:11:22:44", ipAddress: "192.168.64.10"),
      ]
    )

    let result = VmnetValidator.validate(config, osVersion: supportedOS)
    XCTAssertTrue(result.errors.contains {
      if case .reservationIPCollision = $0 { return true }
      return false
    })
  }

  func testDHCPDisabledWithReservationsIsRejected() {
    let config = VmnetConfig(
      dhcpEnabled: false,
      reservations: [Reservation(macAddress: "52:54:00:11:22:33", ipAddress: "192.168.64.10")]
    )

    let result = VmnetValidator.validate(config, osVersion: supportedOS)
    XCTAssertTrue(result.errors.contains(.dhcpDisabledWithReservations))
  }

  func testInvalidMACAddressIsRejected() {
    let config = VmnetConfig(reservations: [Reservation(macAddress: "not-a-mac", ipAddress: "192.168.64.10")])
    let result = VmnetValidator.validate(config, osVersion: supportedOS)

    XCTAssertEqual(result.errors, [.invalidMACAddress(raw: "not-a-mac")])
  }

  func testNormalizeMACAddressLowercasesAndValidates() {
    XCTAssertEqual(VmnetValidator.normalizeMACAddress("52:54:00:AA:BB:CC"), "52:54:00:aa:bb:cc")
    XCTAssertNil(VmnetValidator.normalizeMACAddress("52:54:00:aa:bb"))
    XCTAssertNil(VmnetValidator.normalizeMACAddress("zz:54:00:aa:bb:cc"))
  }

  func testMutualExclusivityAcceptsASingleMode() {
    XCTAssertTrue(VmnetValidator.validateExclusivity([.vmnet]).isValid)
  }

  func testMutualExclusivityRejectsMultipleModes() {
    let result = VmnetValidator.validateExclusivity([.vmnet, .bridged])
    XCTAssertFalse(result.isValid)
    XCTAssertEqual(result.errors.first?.category, .configuration)
  }
}
