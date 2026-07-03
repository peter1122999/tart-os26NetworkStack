import Foundation
@testable import tart

import Network

/// Deterministic stand-in for `ARPScopedVmnetRuntimeLookup` — no `arp` subprocess, no
/// timing dependence, just a canned answer (or a canned failure).
struct MockRuntimeLookup: VmnetRuntimeLookup {
  var result: IPv4Address?
  var errorToThrow: Error?

  func lookupIPAddress(forMAC mac: String, scopedTo subnet: CIDRBlock?) throws -> IPv4Address? {
    if let errorToThrow = errorToThrow { throw errorToThrow }
    return result
  }
}

/// Deterministic stand-in for the legacy `tart ip` resolvers.
struct MockLegacyResolver: LegacyIPResolving {
  var result: IPv4Address?

  func resolve(_ macAddress: MACAddress, strategy: IPResolutionStrategy, secondsToWait: UInt16, controlSocketURL: URL?) async throws -> IPv4Address? {
    result
  }
}

/// Deterministic `ProcessHandle` test double: no real subprocess, no timing, no
/// nondeterminism — a test simply flips `isRunning`/`exitCode` itself.
final class MockProcessHandle: ProcessHandle {
  var isRunning: Bool
  var exitCode: Int32?

  init(isRunning: Bool = true, exitCode: Int32? = nil) {
    self.isRunning = isRunning
    self.exitCode = exitCode
  }

  func terminate() {
    isRunning = false
    exitCode = exitCode ?? 0
  }
}

/// Deterministic `ProcessRunning` test double for driving `VMOrchestrator` in tests
/// without ever shelling out to a real `tart` binary. Records every launch so tests can
/// assert on the exact CLI that would have been run.
final class MockProcessRunner: ProcessRunning {
  struct Invocation {
    let executableURL: URL
    let arguments: [String]
  }

  private(set) var invocations: [Invocation] = []
  var handleFactory: () -> ProcessHandle
  var errorToThrow: Error?

  init(handleFactory: @escaping () -> ProcessHandle = { MockProcessHandle() }) {
    self.handleFactory = handleFactory
  }

  func launch(
    executableURL: URL,
    arguments: [String],
    onStdout: @escaping (Data) -> Void,
    onStderr: @escaping (Data) -> Void
  ) throws -> ProcessHandle {
    invocations.append(Invocation(executableURL: executableURL, arguments: arguments))

    if let errorToThrow = errorToThrow {
      throw errorToThrow
    }

    return handleFactory()
  }
}
