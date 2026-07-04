import Foundation
import System

public enum FileLockError: Error, Equatable {
  case Failed(_ message: String)
  case AlreadyLocked
}

public class FileLock {
  public let url: URL
  public let fd: Int32

  public init(lockURL: URL) throws {
    url = lockURL
    fd = open(lockURL.path, 0)
  }

  deinit {
    close(fd)
  }

  public func trylock() throws -> Bool {
    try flockWrapper(LOCK_EX | LOCK_NB)
  }

  public func lock() throws {
    _ = try flockWrapper(LOCK_EX)
  }

  public func unlock() throws {
    _ = try flockWrapper(LOCK_UN)
  }

  public func flockWrapper(_ operation: Int32) throws -> Bool {
    let ret = flock(fd, operation)
    if ret != 0 {
      let details = Errno(rawValue: CInt(errno))

      if (operation & LOCK_NB) != 0 && details == .wouldBlock {
        return false
      }

      throw FileLockError.Failed("failed to lock \(url): \(details)")
    }

    return true
  }
}
