import Foundation
import TartCore

class VMStorageHelper {
  static func open(_ name: String) throws -> VMDirectory {
    try missingVMWrap(name) {
      if let remoteName = try? RemoteName(name) {
        return try VMStorageOCI().open(remoteName)
      } else {
        return try VMStorageLocal().open(name)
      }
    }
  }

  static func delete(_ name: String) throws {
    try missingVMWrap(name) {
      if let remoteName = try? RemoteName(name) {
        try VMStorageOCI().delete(remoteName)
      } else {
        try VMStorageLocal().delete(name)
      }
    }
  }

  private static func missingVMWrap<R: Any>(_ name: String, closure: () throws -> R) throws -> R {
    do {
      return try closure()
    } catch RuntimeError.PIDLockMissing {
      throw RuntimeError.VMDoesNotExist(name: name)
    } catch {
      if error.isFileNotFound() {
        throw RuntimeError.VMDoesNotExist(name: name)
      }

      throw error
    }
  }
}
