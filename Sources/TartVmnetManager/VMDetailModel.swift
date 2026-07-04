import Foundation
import TartCore

/// Per-VM state for the detail pane: the in-progress edit of its `VmnetConfig`, its
/// current lifecycle phase, and the last diagnostics report. This talks to the same
/// `VmnetPersistence` / `VmnetValidator` / `VMOrchestrator` types "tart run" and "tart ip"
/// use internally — there's no separate GUI-only copy of any of this logic.
@MainActor
final class VMDetailModel: ObservableObject {
  let directory: VMDirectory

  @Published var draftConfig: VmnetConfig
  @Published var validationErrors: [VmnetError] = []
  @Published var macAddress: String = ""
  @Published var isRunning: Bool = false
  @Published var lifecyclePhase: VMLifecyclePhase = .notStarted
  @Published var resolvedIP: String?
  @Published var diagnosticsText: String = ""
  @Published var statusMessage: String?
  @Published var busy: Bool = false

  init(directory: VMDirectory) {
    self.directory = directory
    self.draftConfig = (try? VmnetPersistence.load(from: directory.vmnetConfigURL)) ?? VmnetConfig()
    reloadStatus()
  }

  func reloadStatus() {
    isRunning = (try? directory.running()) ?? false

    if let config = try? VMConfig(fromURL: directory.configURL) {
      macAddress = config.macAddress.string
    }
  }

  @discardableResult
  func validate() -> Bool {
    validationErrors = VmnetValidator.validate(draftConfig).errors
    return validationErrors.isEmpty
  }

  func addReservation() {
    draftConfig.reservations.append(Reservation(macAddress: "", ipAddress: ""))
  }

  func removeReservations(at offsets: IndexSet) {
    draftConfig.reservations.remove(atOffsets: offsets)
  }

  func save() {
    guard validate() else {
      statusMessage = "Fix the problems below before saving."
      return
    }

    do {
      try VmnetPersistence.save(draftConfig, to: directory.vmnetConfigURL)
      statusMessage = "Saved."
    } catch {
      statusMessage = "Failed to save: \(error)"
    }
  }

  /// Drives the same `VMOrchestrator` the CLI's orchestration engine uses: validates,
  /// persists the network config, spawns `tart run --net-vmnet ...`, then polls for an
  /// IP address using the DHCP-reservation -> vmnet-runtime-lookup -> legacy-fallback
  /// priority. The spawned VM keeps running after this call returns; only startup
  /// (through IP resolution or timeout) is awaited here.
  func start() {
    guard validate() else {
      statusMessage = "Fix the problems below before starting."
      return
    }

    busy = true
    statusMessage = nil
    diagnosticsText = ""

    let request = OrchestrationRequest(
      vmName: directory.name,
      macAddress: macAddress,
      networkMode: .vmnet,
      vmnetConfig: draftConfig
    )
    let directory = self.directory

    Task {
      let orchestrator = VMOrchestrator()
      let result = await orchestrator.start(request, vmDirectory: directory)

      self.busy = false
      self.resolvedIP = result.resolvedIP
      self.lifecyclePhase = result.finalState.phase
      self.diagnosticsText = VmnetDiagnostics.summarize(result.diagnostics)
      self.statusMessage = result.succeeded ? "VM is up." : "Startup did not complete — see diagnostics below."
      self.reloadStatus()
    }
  }

  /// Deliberately doesn't reach into the process this app itself may have launched via
  /// `start()` — "tart stop" already knows how to find a running VM by name (PID lock
  /// file) and request a graceful shutdown, which is the same thing "Ctrl+C on tart run"
  /// does. Reusing it here means stop works even for VMs this app didn't start.
  func stop() {
    busy = true
    statusMessage = nil
    let vmName = directory.name

    Task {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
      process.arguments = ["tart", "stop", vmName]

      let stderrPipe = Pipe()
      process.standardError = stderrPipe

      do {
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
          let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
          let message = String(data: data, encoding: .utf8) ?? ""
          self.statusMessage = "\"tart stop\" exited with code \(process.terminationStatus)\(message.isEmpty ? "" : ": \(message)")"
        } else {
          self.statusMessage = "Stopped."
        }
      } catch {
        self.statusMessage = "Failed to run \"tart stop\": \(error)"
      }

      self.busy = false
      self.reloadStatus()
    }
  }
}
