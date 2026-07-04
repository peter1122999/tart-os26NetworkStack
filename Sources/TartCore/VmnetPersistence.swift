import Foundation

extension VMDirectory {
  /// Where a VM's vmnet network configuration is persisted, alongside its `config.json`.
  /// Kept as a separate file (rather than a field on `VMConfig`) so vmnet support can
  /// evolve — including its own schema migrations — independently of the core VM config
  /// format, and so VMs that never use vmnet never pay for the extra fields.
  public var vmnetConfigURL: URL {
    baseURL.appendingPathComponent("netVmnet.json")
  }
}

/// Reads and writes `VmnetConfig` as versioned JSON. This is the "Persistence" layer
/// (goal 8): every write stamps the current schema version, and every read runs through
/// `migrate(_:)` so older on-disk configs keep loading after a Tart upgrade instead of
/// hard-failing.
public enum VmnetPersistence {
  public static func load(from url: URL) throws -> VmnetConfig? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }

    let data = try Data(contentsOf: url)
    return try migrate(data)
  }

  public static func save(_ config: VmnetConfig, to url: URL) throws {
    var config = config
    config.schemaVersion = VmnetConfig.currentSchemaVersion

    let data = try Config.jsonEncoder().encode(config)
    try data.write(to: url, options: .atomic)
  }

  public static func delete(at url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.removeItem(at: url)
  }

  /// Decodes raw JSON into the current `VmnetConfig` shape, applying any schema
  /// transformations needed along the way. Each past schema version gets its own case
  /// here rather than a generic "best effort" decode, so a migration failure is always a
  /// deliberate, reviewable code change instead of an accident of `Codable`'s defaulting
  /// behavior.
  public static func migrate(_ data: Data) throws -> VmnetConfig {
    struct SchemaProbe: Decodable {
      var schemaVersion: Int?
    }

    // Schema version 0 is "the field didn't exist yet" — every config written before
    // `schemaVersion` was introduced implicitly belongs to it.
    let foundVersion = (try? Config.jsonDecoder().decode(SchemaProbe.self, from: data))?.schemaVersion ?? 0

    switch foundVersion {
    case 0:
      return try migrateFromV0(data)
    case VmnetConfig.currentSchemaVersion:
      return try Config.jsonDecoder().decode(VmnetConfig.self, from: data)
    default:
      throw VmnetError.unsupportedSchemaVersion(found: foundVersion, newestSupported: VmnetConfig.currentSchemaVersion)
    }
  }

  /// v0 -> v1: identical field set, `schemaVersion` just didn't exist on disk yet.
  /// `VmnetConfig`'s memberwise `init` defaults `schemaVersion` to
  /// `currentSchemaVersion`, and every other field already has a matching default, so a
  /// plain decode is correct today. Kept as its own function (instead of folding into the
  /// `case 0` branch above) so it's an obvious, isolated edit point the next time the
  /// schema actually changes shape.
  private static func migrateFromV0(_ data: Data) throws -> VmnetConfig {
    try Config.jsonDecoder().decode(VmnetConfig.self, from: data)
  }
}
