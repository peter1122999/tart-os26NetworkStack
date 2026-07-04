import Foundation

public class VMStorageLocal: PrunableStorage {
  public let baseURL: URL

  public init() throws {
    baseURL = try Config().tartHomeDir.appendingPathComponent("vms", isDirectory: true)
  }

  private func vmURL(_ name: String) -> URL {
    baseURL.appendingPathComponent(name, isDirectory: true)
  }

  public func exists(_ name: String) -> Bool {
    VMDirectory(baseURL: vmURL(name)).initialized
  }

  public func open(_ name: String) throws -> VMDirectory {
    let vmDir = VMDirectory(baseURL: vmURL(name))

    try vmDir.validate(userFriendlyName: name)

    try vmDir.baseURL.updateAccessDate()

    return vmDir
  }

  public func create(_ name: String, overwrite: Bool = false) throws -> VMDirectory {
    let vmDir = VMDirectory(baseURL: vmURL(name))

    try vmDir.initialize(overwrite: overwrite)

    return vmDir
  }

  public func move(_ name: String, from: VMDirectory) throws {
    _ = try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
    _ = try FileManager.default.replaceItemAt(vmURL(name), withItemAt: from.baseURL)
  }

  public func rename(_ name: String, _ newName: String) throws {
    _ = try FileManager.default.replaceItemAt(vmURL(newName), withItemAt: vmURL(name))
  }

  public func delete(_ name: String) throws {
    try VMDirectory(baseURL: vmURL(name)).delete()
  }

  public func list() throws -> [(String, VMDirectory)] {
    do {
      return try FileManager.default.contentsOfDirectory(
        at: baseURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: .skipsSubdirectoryDescendants).compactMap { url in
        let vmDir = VMDirectory(baseURL: url)

        if !vmDir.initialized {
          return nil
        }

        return (vmDir.name, vmDir)
      }
    } catch {
      if error.isFileNotFound() {
        return []
      }

      throw error
    }
  }

  public func prunables() throws -> [Prunable] {
    try list().map { (_, vmDir) in vmDir }.filter { try !$0.running() }
  }

  public func hasVMsWithMACAddress(macAddress: String) throws -> Bool {
    try list().contains { try $1.macAddress() == macAddress }
  }
}
