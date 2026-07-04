import Foundation

/// Bounded ring buffer of the last N lines written to a stream. Used to capture a
/// subprocess's stdout/stderr for diagnostics without retaining unbounded output for
/// long-running VMs. Safe to feed from a `Pipe`'s `readabilityHandler`, which fires on a
/// background queue.
final class LineTailCollector: @unchecked Sendable {
  private let capacity: Int
  private var lines: [String] = []
  private var partial = ""
  private let lock = NSLock()

  init(capacity: Int = 200) {
    self.capacity = capacity
  }

  func consume(_ data: Data) {
    guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }

    lock.lock()
    defer { lock.unlock() }

    partial += chunk
    let pieces = partial.components(separatedBy: "\n")
    partial = pieces.last ?? ""

    for line in pieces.dropLast() {
      lines.append(line)
      if lines.count > capacity {
        lines.removeFirst(lines.count - capacity)
      }
    }
  }

  func snapshot() -> [String] {
    lock.lock()
    defer { lock.unlock() }

    var result = lines
    if !partial.isEmpty { result.append(partial) }
    return result
  }
}

/// Everything the diagnostics system collects for a single VM: what was configured, what
/// was observed at runtime, every IP resolution attempt, and a tail of the VM process's
/// own output. Deliberately a plain value type so it can be built up incrementally by the
/// orchestrator and handed to `VmnetDiagnostics` for reporting, or serialized for
/// `tart run --net-vmnet` bug reports.
struct DiagnosticsBundle {
  var vmName: String
  var networkMode: NetworkMode?
  var vmnetConfig: VmnetConfig?
  var runtimeState: VmnetRuntimeState?
  var ipResolutionAttempts: [IPResolutionAttempt] = []
  var stdoutTail: [String] = []
  var stderrTail: [String] = []
  var lifecycleFailure: VmnetError?
}

/// Turns a `DiagnosticsBundle` into a human-readable report and a suggested-fix list.
/// This is the "Diagnostics System" (goal 5): collection is handled by the pieces that
/// populate `DiagnosticsBundle` (orchestrator captures process output, `NetworkVmnet` and
/// `VmnetStateStore` capture runtime state, `VmnetIPResolver` captures resolution
/// attempts); this type is purely about presentation, and is trivially unit-testable
/// since it's a pure function of its input.
enum VmnetDiagnostics {
  static func summarize(_ bundle: DiagnosticsBundle) -> String {
    var lines: [String] = []

    lines.append("=== Tart vmnet diagnostics: \(bundle.vmName) ===")
    lines.append("Network mode: \(bundle.networkMode?.description ?? "unknown")")

    if let config = bundle.vmnetConfig {
      lines.append("Topology: \(config.topology.rawValue)")
      lines.append("Configured subnet: \(config.subnet?.description ?? "auto")")
      lines.append("Observed subnet:   \(bundle.runtimeState?.actualSubnet?.description ?? "not yet known")")
      lines.append("DHCP: \(config.dhcpEnabled ? "enabled" : "disabled")  NAT: \(config.natEnabled ? "enabled" : "disabled")  DNS: \(config.dnsEnabled ? "enabled" : "disabled")")

      if !config.reservations.isEmpty {
        lines.append("Reservations:")
        for reservation in config.reservations {
          lines.append("  \(reservation.macAddress) -> \(reservation.ipAddress)")
        }
      }
    } else {
      lines.append("No vmnet configuration is on file for this VM.")
    }

    if !bundle.ipResolutionAttempts.isEmpty {
      lines.append("")
      lines.append("IP resolution attempts:")
      for attempt in bundle.ipResolutionAttempts {
        let mark = attempt.succeeded ? "OK" : "FAIL"
        lines.append("  [\(mark)] \(attempt.strategy.rawValue): \(attempt.detail)")
      }

      if let inconsistency = VmnetIPResolver.detectInconsistency(bundle.ipResolutionAttempts) {
        lines.append("Warning: \(inconsistency)")
      }
    }

    if let failure = bundle.lifecycleFailure {
      lines.append("")
      lines.append("Failure: \(failure.description)")
      lines.append("Suggested fix: \(suggestedFix(for: failure))")
    }

    if !bundle.stderrTail.isEmpty {
      lines.append("")
      lines.append("--- tart run stderr (last \(bundle.stderrTail.count) lines) ---")
      lines.append(contentsOf: bundle.stderrTail)
    }

    if !bundle.stdoutTail.isEmpty {
      lines.append("")
      lines.append("--- tart run stdout (last \(bundle.stdoutTail.count) lines) ---")
      lines.append(contentsOf: bundle.stdoutTail)
    }

    return lines.joined(separator: "\n")
  }

  /// Every distinct suggested fix implied by the bundle: the lifecycle failure's own fix
  /// (if any), plus heuristic fixes inferred from the shape of the IP resolution trail —
  /// e.g. all three tiers failing with an unset subnet usually means the guest never got
  /// an address at all, as opposed to the control plane failing to find one that exists.
  static func suggestedFixes(_ bundle: DiagnosticsBundle) -> [String] {
    var fixes: [String] = []

    if let failure = bundle.lifecycleFailure {
      fixes.append(suggestedFix(for: failure))
    }

    if bundle.ipResolutionAttempts.allSatisfy({ !$0.succeeded }) && !bundle.ipResolutionAttempts.isEmpty {
      if bundle.runtimeState?.actualSubnet == nil {
        fixes.append("The vmnet interface never reported an active subnet — check whether the VM actually booted and whether \"tart run\" is still attached")
      } else if bundle.vmnetConfig?.reservations.isEmpty == false {
        fixes.append("A reservation is configured but wasn't observed on the wire — verify the guest's MAC address matches the reservation exactly (case-insensitive, colon-separated)")
      }
    }

    var seen = Swift.Set<String>()
    return fixes.filter { seen.insert($0).inserted }
  }
}
