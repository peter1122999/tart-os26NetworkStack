import XCTest
@testable import tart

import Network

final class CIDRBlockTests: XCTestCase {
  func testParsesValidCIDR() throws {
    let block = try XCTUnwrap(CIDRBlock("192.168.64.0/24"))
    XCTAssertEqual(block.prefixLength, 24)
    XCTAssertEqual(block.description, "192.168.64.0/24")
  }

  func testRejectsMalformedCIDR() {
    XCTAssertNil(CIDRBlock("not-a-cidr"))
    XCTAssertNil(CIDRBlock("192.168.64.0"))
    XCTAssertNil(CIDRBlock("192.168.64.0/33"))
    XCTAssertNil(CIDRBlock("999.999.999.999/24"))
  }

  func testContains() throws {
    let block = try XCTUnwrap(CIDRBlock("192.168.64.0/24"))

    XCTAssertTrue(block.contains(try XCTUnwrap(IPv4Address("192.168.64.1"))))
    XCTAssertTrue(block.contains(try XCTUnwrap(IPv4Address("192.168.64.254"))))
    XCTAssertFalse(block.contains(try XCTUnwrap(IPv4Address("192.168.65.1"))))
  }

  func testUsableHostRangeExcludesNetworkAndBroadcast() throws {
    let block = try XCTUnwrap(CIDRBlock("192.168.64.0/24"))
    let range = try XCTUnwrap(block.usableHostRange)

    let network = try XCTUnwrap(IPv4Address("192.168.64.0"))
    let broadcast = try XCTUnwrap(IPv4Address("192.168.64.255"))
    let host = try XCTUnwrap(IPv4Address("192.168.64.10"))

    func bits(_ address: IPv4Address) -> UInt32 {
      address.rawValue.withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian
    }

    XCTAssertFalse(range.contains(bits(network)))
    XCTAssertFalse(range.contains(bits(broadcast)))
    XCTAssertTrue(range.contains(bits(host)))
  }

  func testRoundTripsThroughJSON() throws {
    let block = try XCTUnwrap(CIDRBlock("10.0.0.0/8"))

    let data = try Config.jsonEncoder().encode(block)
    let decoded = try Config.jsonDecoder().decode(CIDRBlock.self, from: data)

    XCTAssertEqual(block, decoded)
  }
}
