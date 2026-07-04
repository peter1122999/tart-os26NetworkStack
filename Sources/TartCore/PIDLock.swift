import Foundation
import System

public class PIDLock {
  public let url: URL
  public let fd: Int32

  public init(lockURL: URL) throws {
    url = lockURL
    fd = open(lockURL.path, O_RDWR)
    if fd == -1 {
      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.PIDLockMissing("failed to open lock file \(url): \(details)")
    }
  }

  deinit {
    close(fd)
  }

  public func trylock() throws -> Bool {
    let (locked, _) = try lockWrapper(F_SETLK, F_WRLCK, "failed to lock \(url)")
    return locked
  }

  public func lock() throws {
    _ = try lockWrapper(F_SETLKW, F_WRLCK, "failed to lock \(url)")
  }

  public func unlock() throws {
    _ = try lockWrapper(F_SETLK, F_UNLCK, "failed to unlock \(url)")
  }

  public func pid() throws -> pid_t {
    let (_, result) = try lockWrapper(F_GETLK, F_RDLCK, "failed to get lock \(url) status")

    return result.l_pid
  }

  public func lockWrapper(_ operation: Int32, _ type: Int32, _ message: String) throws -> (Bool, flock) {
    var result = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(type), l_whence: Int16(SEEK_SET))

    let ret = fcntl(fd, operation, &result)
    if ret != 0 {
      if operation == F_SETLK && errno == EAGAIN {
        return (false, result)
      }

      let details = Errno(rawValue: CInt(errno))

      throw RuntimeError.PIDLockFailed("\(message): \(details)")
    }

    return (true, result)
  }
}
