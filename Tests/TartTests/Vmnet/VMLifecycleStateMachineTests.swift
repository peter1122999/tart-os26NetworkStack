import XCTest
@testable import tart

final class VMLifecycleStateMachineTests: XCTestCase {
  func testFollowsTheDeterministicStartupFlow() throws {
    let machine = VMLifecycleStateMachine()

    try machine.transition(to: .validating)
    try machine.transition(to: .configuringNetwork)
    try machine.transition(to: .buildingCommand)
    try machine.transition(to: .launching)
    try machine.transition(to: .booting)
    try machine.transition(to: .running)
    try machine.transition(to: .resolvingIP)
    try machine.transition(to: .ipResolved(address: "192.168.64.10"))

    XCTAssertEqual(machine.state, .ipResolved(address: "192.168.64.10"))
    XCTAssertEqual(machine.history.count, 9) // notStarted + 8 transitions
  }

  func testRejectsSkippingSteps() throws {
    let machine = VMLifecycleStateMachine()

    XCTAssertThrowsError(try machine.transition(to: .running)) { error in
      XCTAssertTrue(error is IllegalLifecycleTransition)
    }
  }

  func testFailureIsReachableFromEveryStep() throws {
    for phase in [VMLifecyclePhase.validating, .configuringNetwork, .buildingCommand, .launching, .booting, .running, .resolvingIP] {
      let machine = VMLifecycleStateMachine()
      try driveTo(phase, machine: machine)
      XCTAssertNoThrow(try machine.transition(to: .failed(category: .unknown, message: "boom")))
    }
  }

  func testRetryLoopsBackToValidating() throws {
    let machine = VMLifecycleStateMachine()
    try machine.transition(to: .validating)
    try machine.transition(to: .failed(category: .networkAttachment, message: "transient"))
    try machine.transition(to: .validating) // retry

    XCTAssertEqual(machine.state.phase, .validating)
  }

  private func driveTo(_ phase: VMLifecyclePhase, machine: VMLifecycleStateMachine) throws {
    let ordered: [VMLifecyclePhase] = [.validating, .configuringNetwork, .buildingCommand, .launching, .booting, .running, .resolvingIP]
    guard let targetIndex = ordered.firstIndex(of: phase) else { return }

    let states: [VMLifecycleState] = [.validating, .configuringNetwork, .buildingCommand, .launching, .booting, .running, .resolvingIP]
    for state in states[0...targetIndex] {
      try machine.transition(to: state)
    }
  }
}
