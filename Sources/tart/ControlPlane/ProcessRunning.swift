import Foundation

/// A handle to a launched process, independent of whether it's a real `Foundation.Process`
/// or a test double. `VMOrchestrator` polls `isRunning`/`exitCode` instead of blocking on
/// the process, since `tart run` is long-lived — it keeps running for as long as the VM
/// does, well past the point the orchestrator considers startup complete.
protocol ProcessHandle: AnyObject {
  var isRunning: Bool { get }
  var exitCode: Int32? { get }
  func terminate()
}

/// Spawns the `tart` binary. Abstracted behind a protocol so the orchestration engine can
/// be driven by deterministic mocks in tests instead of shelling out for real — this is
/// the "testable interfaces, deterministic mocks" requirement (goal 9) applied to the one
/// piece of the control plane that's inherently side-effecting.
protocol ProcessRunning {
  func launch(
    executableURL: URL,
    arguments: [String],
    onStdout: @escaping (Data) -> Void,
    onStderr: @escaping (Data) -> Void
  ) throws -> ProcessHandle
}

final class RealProcessHandle: ProcessHandle {
  private let process: Process

  init(process: Process) {
    self.process = process
  }

  var isRunning: Bool { process.isRunning }

  var exitCode: Int32? {
    process.isRunning ? nil : process.terminationStatus
  }

  func terminate() {
    process.terminate()
  }
}

struct RealProcessRunner: ProcessRunning {
  func launch(
    executableURL: URL,
    arguments: [String],
    onStdout: @escaping (Data) -> Void,
    onStderr: @escaping (Data) -> Void
  ) throws -> ProcessHandle {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
      onStdout(handle.availableData)
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
      onStderr(handle.availableData)
    }

    do {
      try process.run()
    } catch {
      throw VmnetError.processLaunchFailed(underlying: "\(error.localizedDescription)")
    }

    return RealProcessHandle(process: process)
  }
}
