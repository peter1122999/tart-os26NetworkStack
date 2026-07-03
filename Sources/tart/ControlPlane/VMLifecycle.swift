import Foundation

/// The lifecycle states a VM passes through under control-plane orchestration, mirroring
/// the deterministic startup flow: validate -> configure network -> build CLI -> launch ->
/// boot -> resolve IP -> running, with `failed` reachable from every step.
enum VMLifecycleState: Equatable {
  case notStarted
  case validating
  case configuringNetwork
  case buildingCommand
  case launching
  case booting
  case running
  case resolvingIP
  case ipResolved(address: String)
  case stopping
  case stopped(exitCode: Int32)
  case failed(category: FailureCategory, message: String)

  var phase: VMLifecyclePhase {
    switch self {
    case .notStarted: return .notStarted
    case .validating: return .validating
    case .configuringNetwork: return .configuringNetwork
    case .buildingCommand: return .buildingCommand
    case .launching: return .launching
    case .booting: return .booting
    case .running: return .running
    case .resolvingIP: return .resolvingIP
    case .ipResolved: return .ipResolved
    case .stopping: return .stopping
    case .stopped: return .stopped
    case .failed: return .failed
    }
  }
}

/// `VMLifecycleState` without its associated payload — used purely to key the transition
/// table below, since a `Set<VMLifecycleState>` isn't viable while cases like `.failed`
/// carry non-hashable-by-design payloads (a free-text message).
enum VMLifecyclePhase: String, CaseIterable, Hashable {
  case notStarted, validating, configuringNetwork, buildingCommand, launching, booting
  case running, resolvingIP, ipResolved, stopping, stopped, failed
}

struct IllegalLifecycleTransition: Error, CustomStringConvertible {
  let from: VMLifecycleState
  let to: VMLifecycleState

  var description: String {
    "illegal VM lifecycle transition from \(from.phase.rawValue) to \(to.phase.rawValue)"
  }
}

/// Enforces the VM lifecycle's state machine and keeps a timestamped history for
/// diagnostics. Not thread-safe by itself — callers that need concurrent access should
/// hold one per orchestration attempt (as `VMOrchestrator` does) rather than sharing an
/// instance across VMs.
final class VMLifecycleStateMachine {
  private(set) var state: VMLifecycleState = .notStarted
  private(set) var history: [(state: VMLifecycleState, at: Date)] = [(.notStarted, Date())]

  private static let allowedNextPhases: [VMLifecyclePhase: Swift.Set<VMLifecyclePhase>] = [
    .notStarted: [.validating],
    .validating: [.configuringNetwork, .failed],
    .configuringNetwork: [.buildingCommand, .failed],
    .buildingCommand: [.launching, .failed],
    .launching: [.booting, .failed],
    .booting: [.running, .failed, .stopping],
    .running: [.resolvingIP, .stopping, .failed],
    .resolvingIP: [.ipResolved, .running, .failed],
    .ipResolved: [.running, .stopping],
    .stopping: [.stopped],
    .stopped: [.validating],
    .failed: [.validating, .stopping],
  ]

  @discardableResult
  func transition(to newState: VMLifecycleState) throws -> VMLifecycleState {
    let allowed = Self.allowedNextPhases[state.phase] ?? []
    guard allowed.contains(newState.phase) else {
      throw IllegalLifecycleTransition(from: state, to: newState)
    }

    state = newState
    history.append((newState, Date()))
    return state
  }
}
