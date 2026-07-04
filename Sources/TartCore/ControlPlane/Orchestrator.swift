import Foundation

/// Everything needed to bring up one VM under control-plane orchestration. This is the
/// "Command layer" input: declarative, serializable, and independent of how it gets
/// turned into an actual `tart run` invocation.
public struct OrchestrationRequest {
  var vmName: String
  var macAddress: String
  var networkMode: NetworkMode
  var vmnetConfig: VmnetConfig?
  var extraRunArguments: [String] = []
  var tartExecutablePath: String = "tart"
  var startupTimeoutSeconds: Int = 60
  var ipPollIntervalSeconds: UInt64 = 1
  var maxRetries: Int = 2

  public init(
    vmName: String,
    macAddress: String,
    networkMode: NetworkMode = .nat,
    vmnetConfig: VmnetConfig? = nil,
    extraRunArguments: [String] = [],
    tartExecutablePath: String = "tart",
    startupTimeoutSeconds: Int = 60,
    ipPollIntervalSeconds: UInt64 = 1,
    maxRetries: Int = 2
  ) {
    self.vmName = vmName
    self.macAddress = macAddress
    self.networkMode = networkMode
    self.vmnetConfig = vmnetConfig
    self.extraRunArguments = extraRunArguments
    self.tartExecutablePath = tartExecutablePath
    self.startupTimeoutSeconds = startupTimeoutSeconds
    self.ipPollIntervalSeconds = ipPollIntervalSeconds
    self.maxRetries = maxRetries
  }
}

public struct OrchestrationResult {
  public var finalState: VMLifecycleState
  public var resolvedIP: String?
  public var diagnostics: DiagnosticsBundle
  public var attempts: Int

  public var succeeded: Bool {
    if case .ipResolved = finalState { return true }
    if case .running = finalState { return true }
    return false
  }
}

/// The Orchestration Engine (goal 2): runs the deterministic startup flow — validate,
/// persist network config, build the `tart run` command line, execute it, then monitor
/// both the process and IP resolution until the VM is confirmed up (or startup fails).
///
/// Retries are scoped to the whole attempt (not individual steps), since a partially
/// applied attempt (e.g. network config written, but the process failed to launch) isn't
/// safe to resume from the middle — every retry starts clean from `.validating`.
public actor VMOrchestrator {
  private let processRunner: ProcessRunning
  private let ipResolver: VmnetIPResolver
  private let stateStore: VmnetStateStore

  private(set) var machine = VMLifecycleStateMachine()

  public init(
    processRunner: ProcessRunning = RealProcessRunner(),
    ipResolver: VmnetIPResolver = VmnetIPResolver(),
    stateStore: VmnetStateStore = .shared
  ) {
    self.processRunner = processRunner
    self.ipResolver = ipResolver
    self.stateStore = stateStore
  }

  /// Builds the `tart run` argument list for a request. Pure and side-effect free, so it
  /// can be unit tested (and eyeballed in diagnostics) without launching anything.
  static func buildRunArguments(for request: OrchestrationRequest) -> [String] {
    var arguments = ["run", request.vmName, "--no-graphics"]

    if let vmnetConfig = request.vmnetConfig {
      arguments.append("--net-vmnet")

      if let subnet = vmnetConfig.subnet {
        arguments.append("--net-vmnet-subnet=\(subnet)")
      }
      if !vmnetConfig.dhcpEnabled {
        arguments.append("--net-vmnet-no-dhcp")
      }
      if !vmnetConfig.natEnabled {
        arguments.append("--net-vmnet-no-nat")
      }
      if !vmnetConfig.dnsEnabled {
        arguments.append("--net-vmnet-no-dns")
      }
      if let externalInterface = vmnetConfig.externalInterface {
        arguments.append("--net-vmnet-bridge=\(externalInterface)")
      }
      for reservation in vmnetConfig.reservations {
        arguments.append("--net-vmnet-reserve=\(reservation.macAddress)=\(reservation.ipAddress)")
      }
    }

    arguments.append(contentsOf: request.extraRunArguments)
    return arguments
  }

  /// Runs the full startup flow, retrying whole attempts per `FailureCategory.isRetryable`
  /// up to `request.maxRetries` times. Always returns (never throws): every failure mode
  /// is captured in the result's `diagnostics` and `finalState` instead, so callers get a
  /// uniform way to inspect what happened regardless of where it went wrong.
  public func start(_ request: OrchestrationRequest, vmDirectory: VMDirectory) async -> OrchestrationResult {
    var diagnostics = DiagnosticsBundle(vmName: request.vmName, networkMode: request.networkMode, vmnetConfig: request.vmnetConfig)
    let totalAttempts = request.maxRetries + 1

    for attempt in 1...totalAttempts {
      do {
        let resolvedIP = try await attemptStartup(request, vmDirectory: vmDirectory, diagnostics: &diagnostics)
        return OrchestrationResult(finalState: machine.state, resolvedIP: resolvedIP, diagnostics: diagnostics, attempts: attempt)
      } catch let error as VmnetError {
        diagnostics.lifecycleFailure = error
        _ = try? machine.transition(to: .failed(category: error.category, message: error.description))

        let isLastAttempt = attempt == totalAttempts
        guard error.category.isRetryable, !isLastAttempt else {
          return OrchestrationResult(finalState: machine.state, resolvedIP: nil, diagnostics: diagnostics, attempts: attempt)
        }

        // No transition back to .validating here: the next loop iteration's
        // attemptStartup() already starts with one, and .failed -> .validating is the
        // only legal source for it. Doing it twice would attempt an illegal
        // .validating -> .validating transition and abort the retry.
      } catch {
        let wrapped = VmnetError.processLaunchFailed(underlying: "\(error)")
        diagnostics.lifecycleFailure = wrapped
        _ = try? machine.transition(to: .failed(category: wrapped.category, message: wrapped.description))
        return OrchestrationResult(finalState: machine.state, resolvedIP: nil, diagnostics: diagnostics, attempts: attempt)
      }
    }

    // Unreachable: the loop above always returns by its last iteration.
    return OrchestrationResult(finalState: machine.state, resolvedIP: nil, diagnostics: diagnostics, attempts: totalAttempts)
  }

  private func attemptStartup(_ request: OrchestrationRequest, vmDirectory: VMDirectory, diagnostics: inout DiagnosticsBundle) async throws -> String? {
    try machine.transition(to: .validating)
    if let vmnetConfig = request.vmnetConfig {
      try VmnetValidator.validate(vmnetConfig).throwIfInvalid()
    }

    // Dependency handling: the network config must exist on disk *before* "tart run"
    // starts, since the vmnet-aware "tart ip" and any concurrent orchestrator instance
    // read it back via VmnetPersistence rather than being told about it out of band.
    try machine.transition(to: .configuringNetwork)
    if let vmnetConfig = request.vmnetConfig {
      try VmnetPersistence.save(vmnetConfig, to: vmDirectory.vmnetConfigURL)
    }

    try machine.transition(to: .buildingCommand)
    let arguments = Self.buildRunArguments(for: request)

    try machine.transition(to: .launching)
    let stdoutCollector = LineTailCollector()
    let stderrCollector = LineTailCollector()

    let handle: ProcessHandle
    do {
      handle = try processRunner.launch(
        executableURL: URL(fileURLWithPath: request.tartExecutablePath),
        arguments: arguments,
        onStdout: { stdoutCollector.consume($0) },
        onStderr: { stderrCollector.consume($0) }
      )
    } catch let error as VmnetError {
      throw error
    } catch {
      throw VmnetError.processLaunchFailed(underlying: "\(error)")
    }

    try machine.transition(to: .booting)
    try machine.transition(to: .running)

    if let vmnetConfig = request.vmnetConfig {
      await stateStore.publish(vmName: request.vmName, config: vmnetConfig, macAddress: request.macAddress)
    }

    try machine.transition(to: .resolvingIP)

    defer {
      diagnostics.stdoutTail = stdoutCollector.snapshot()
      diagnostics.stderrTail = stderrCollector.snapshot()
    }

    let deadline = Date().addingTimeInterval(TimeInterval(request.startupTimeoutSeconds))
    var lastOutcome: IPResolutionOutcome?

    while Date() < deadline {
      if !handle.isRunning {
        throw VmnetError.processExitedUnexpectedly(
          exitCode: handle.exitCode ?? -1,
          stderrTail: stderrCollector.snapshot().suffix(5).joined(separator: "\n")
        )
      }

      let macAddress = MACAddress(fromString: request.macAddress) ?? MACAddress(fromString: "00:00:00:00:00:00")!
      let outcome = try await ipResolver.resolve(
        macAddress: macAddress,
        config: request.vmnetConfig,
        runtimeState: await stateStore.runtimeState(for: request.vmName)
      )
      lastOutcome = outcome
      diagnostics.ipResolutionAttempts = outcome.attempts

      if let address = outcome.address {
        try machine.transition(to: .ipResolved(address: "\(address)"))
        await stateStore.recordResolvedIP(vmName: request.vmName, ipAddress: "\(address)")
        try machine.transition(to: .running)
        return "\(address)"
      }

      try? await Task.sleep(nanoseconds: request.ipPollIntervalSeconds * 1_000_000_000)
    }

    if let lastOutcome = lastOutcome {
      throw VmnetError.noIPAddressResolved(vmName: request.vmName, attempts: lastOutcome.attempts)
    }
    throw VmnetError.startupTimedOut(afterSeconds: request.startupTimeoutSeconds)
  }
}
