import XCTest
@testable import tart

final class VmnetPersistenceTests: XCTestCase {
  private var tempURL: URL!

  override func setUpWithError() throws {
    tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempURL)
  }

  func testLoadOfMissingFileReturnsNil() throws {
    XCTAssertNil(try VmnetPersistence.load(from: tempURL))
  }

  func testSaveThenLoadRoundTrips() throws {
    let config = VmnetConfig(
      subnet: CIDRBlock("192.168.64.0/24"),
      dhcpEnabled: true,
      natEnabled: false,
      dnsEnabled: true,
      reservations: [Reservation(macAddress: "52:54:00:11:22:33", ipAddress: "192.168.64.10", hostname: "ci-runner")]
    )

    try VmnetPersistence.save(config, to: tempURL)
    let loaded = try VmnetPersistence.load(from: tempURL)

    XCTAssertEqual(loaded, config)
  }

  func testSaveStampsCurrentSchemaVersion() throws {
    var config = VmnetConfig()
    config.schemaVersion = 999 // deliberately wrong; save() should correct it

    try VmnetPersistence.save(config, to: tempURL)
    let loaded = try VmnetPersistence.load(from: tempURL)

    XCTAssertEqual(loaded?.schemaVersion, VmnetConfig.currentSchemaVersion)
  }

  func testMigratesPreVersioningSchema() throws {
    // Simulates a config written before `schemaVersion` existed on disk: every other
    // field still matches today's shape, so this should decode as schema 0 and migrate
    // cleanly rather than being rejected outright.
    let legacyJSON = """
    {
      "topology": "shared",
      "dhcpEnabled": true,
      "natEnabled": true,
      "dnsEnabled": true,
      "reservations": [],
      "isolate": false
    }
    """.data(using: .utf8)!

    let migrated = try VmnetPersistence.migrate(legacyJSON)
    XCTAssertEqual(migrated.topology, .shared)
    XCTAssertTrue(migrated.dhcpEnabled)
  }

  func testRejectsUnknownFutureSchemaVersion() {
    let futureJSON = """
    {
      "schemaVersion": 999,
      "topology": "shared",
      "dhcpEnabled": true,
      "natEnabled": true,
      "dnsEnabled": true,
      "reservations": [],
      "isolate": false
    }
    """.data(using: .utf8)!

    XCTAssertThrowsError(try VmnetPersistence.migrate(futureJSON)) { error in
      guard case VmnetError.unsupportedSchemaVersion(let found, _) = error else {
        return XCTFail("expected .unsupportedSchemaVersion, got \(error)")
      }
      XCTAssertEqual(found, 999)
    }
  }

  func testDeleteIsIdempotent() throws {
    try VmnetPersistence.save(VmnetConfig(), to: tempURL)
    try VmnetPersistence.delete(at: tempURL)
    try VmnetPersistence.delete(at: tempURL) // should not throw

    XCTAssertNil(try VmnetPersistence.load(from: tempURL))
  }
}
