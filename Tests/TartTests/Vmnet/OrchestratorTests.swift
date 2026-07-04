import XCTest
@testable import tart

import Network

final class OrchestratorTests: XCTestCase {
  private var tempDir: URL!

  override func setUpWithError() throws {
    tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: tempDir)
  }

  func testBuildRunArgumentsReflectsFullConfig() {
    let request = OrchestrationRequest(
      vmName: "ci-runner",
      macAddress: "52:54:00:11:22:33",
      vmnetConfig: VmnetConfig(
        subnet: CIDRBlock("192.168.64.0/24"),
        dhcpEnabled: true,
        natEnabled: false,
        dnsEnabled: false,
        externalInterface: "en0",
        reservations: [Reservation(macAddress: "52:54:00:11:22:33", ipAddress: "192.168.64.10")]
      )
    )

    let arguments = VMOrchestrator.buildRunArguments(for: request)

    XCTAssertEqual(arguments, [
      "run", "ci-runner", "--no-graphics",
      "--net-vmnet",
      "--net-vmnet-subnet=192.168.64.0/24",
      "--net-vmnet-no-nat",
      "--net-vmnet-no-dns",
      "--net-vmnet-bridge=en0",
      "--net-vmnet-reserve=52:54:00:11:22:33=192.168.64.10",
    ])
  }

  func testSuccessfulStartupResolvesIPAndReachesRunningState() async throws {
    let processRunner = MockProcessRunner()
    let ipResolver = VmnetIPResolver(
      runtimeLookup: MockRuntimeLookup(result: IPv4Address("192.168.64.10")),
      legacyResolver: MockLegacyResolver(result: nil)
    )
    let orchestrator = VMOrchestrator(processRunner: processRunner, ipResolver: ipResolver, stateStore: VmnetStateStore())

    var request = OrchestrationRequest(vmName: "ci-runner", macAddress: "52:54:00:11:22:33")
    request.ipPollIntervalSeconds = 0

    let result = await orchestrator.start(request, vmDirectory: VMDirectory(baseURL: tempDir))

    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.resolvedIP, "192.168.64.10")
    XCTAssertEqual(result.attempts, 1)
    XCTAssertEqual(processRunner.invocations.count, 1)
  }

  func testNetworkConfigIsPersistedBeforeLaunch() async throws {
    let processRunner = MockProcessRunner()
    let ipResolver = VmnetIPResolver(
      runtimeLookup: MockRuntimeLookup(result: IPv4Address("192.168.64.10")),
      legacyResolver: MockLegacyResolver(result: nil)
    )
    let orchestrator = VMOrchestrator(processRunner: processRunner, ipResolver: ipResolver, stateStore: VmnetStateStore())

    let vmnetConfig = VmnetConfig(subnet: CIDRBlock("192.168.64.0/24"))
    var request = OrchestrationRequest(vmName: "ci-runner", macAddress: "52:54:00:11:22:33", vmnetConfig: vmnetConfig)
    request.ipPollIntervalSeconds = 0

    let vmDirectory = VMDirectory(baseURL: tempDir)
    _ = await orchestrator.start(request, vmDirectory: vmDirectory)

    // Dependency handling: the network config must exist before "tart run" was invoked.
    let persisted = try VmnetPersistence.load(from: vmDirectory.vmnetConfigURL)
    XCTAssertEqual(persisted, vmnetConfig)
  }

  func testConfigurationFailureIsNotRetried() async throws {
    let processRunner = MockProcessRunner()
    let orchestrator = VMOrchestrator(processRunner: processRunner, stateStore: VmnetStateStore())

    // Bridged topology with no external interface is a configuration error — VmnetValidator
    // should reject it before anything is ever launched.
    var request = OrchestrationRequest(
      vmName: "ci-runner",
      macAddress: "52:54:00:11:22:33",
      vmnetConfig: VmnetConfig(topology: .bridged)
    )
    request.ipPollIntervalSeconds = 0

    let result = await orchestrator.start(request, vmDirectory: VMDirectory(baseURL: tempDir))

    XCTAssertFalse(result.succeeded)
    guard case .failed(let category, _) = result.finalState else {
      return XCTFail("expected .failed, got \(result.finalState)")
    }
    XCTAssertEqual(category, .configuration)
    XCTAssertEqual(processRunner.invocations.count, 0, "configuration errors must fail before launching a process")
    XCTAssertEqual(result.attempts, 1, "configuration errors are not retryable")
  }

  func testProcessLaunchFailureIsNotRetried() async throws {
    let processRunner = MockProcessRunner()
    processRunner.errorToThrow = VmnetError.processLaunchFailed(underlying: "no such file")

    var request = OrchestrationRequest(vmName: "ci-runner", macAddress: "52:54:00:11:22:33")
    request.ipPollIntervalSeconds = 0
    request.maxRetries = 3

    let orchestrator = VMOrchestrator(processRunner: processRunner, stateStore: VmnetStateStore())
    let result = await orchestrator.start(request, vmDirectory: VMDirectory(baseURL: tempDir))

    XCTAssertFalse(result.succeeded)
    XCTAssertEqual(result.attempts, 1)
    XCTAssertEqual(processRunner.invocations.count, 1)
  }

  func testProcessCrashDuringIPResolutionIsRetried() async throws {
    var handleCount = 0
    let processRunner = MockProcessRunner(handleFactory: {
      handleCount += 1
      // First attempt's process is already dead (simulating an early crash); the retry's
      // process stays up so the second attempt can succeed.
      return MockProcessHandle(isRunning: handleCount > 1, exitCode: handleCount > 1 ? nil : 1)
    })

    let ipResolver = VmnetIPResolver(
      runtimeLookup: MockRuntimeLookup(result: IPv4Address("192.168.64.10")),
      legacyResolver: MockLegacyResolver(result: nil)
    )

    var request = OrchestrationRequest(vmName: "ci-runner", macAddress: "52:54:00:11:22:33")
    request.ipPollIntervalSeconds = 0
    request.maxRetries = 1

    let orchestrator = VMOrchestrator(processRunner: processRunner, ipResolver: ipResolver, stateStore: VmnetStateStore())
    let result = await orchestrator.start(request, vmDirectory: VMDirectory(baseURL: tempDir))

    XCTAssertTrue(result.succeeded)
    XCTAssertEqual(result.attempts, 2)
    XCTAssertEqual(processRunner.invocations.count, 2)
  }

  func testTimeoutClassifiesAsIPResolutionFailure() async throws {
    let processRunner = MockProcessRunner()
    let ipResolver = VmnetIPResolver(
      runtimeLookup: MockRuntimeLookup(result: nil),
      legacyResolver: MockLegacyResolver(result: nil)
    )

    var request = OrchestrationRequest(vmName: "ci-runner", macAddress: "52:54:00:11:22:33")
    request.ipPollIntervalSeconds = 0
    // Long enough for the (instant, mocked) resolver to be polled at least once before
    // the deadline passes, short enough to keep the test fast.
    request.startupTimeoutSeconds = 1
    request.maxRetries = 0

    let orchestrator = VMOrchestrator(processRunner: processRunner, ipResolver: ipResolver, stateStore: VmnetStateStore())
    let result = await orchestrator.start(request, vmDirectory: VMDirectory(baseURL: tempDir))

    XCTAssertFalse(result.succeeded)
    guard case .failed(let category, _) = result.finalState else {
      return XCTFail("expected .failed, got \(result.finalState)")
    }
    XCTAssertEqual(category, .ipResolutionFailed)
    XCTAssertFalse(result.diagnostics.ipResolutionAttempts.isEmpty)
  }
}
