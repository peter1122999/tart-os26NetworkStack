import SwiftUI

struct LifecycleDiagnosticsView: View {
  @ObservedObject var model: VMDetailModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(model.isRunning ? "Running" : "Stopped", systemImage: model.isRunning ? "circle.fill" : "circle")
          .foregroundStyle(model.isRunning ? .green : .secondary)

        Spacer()

        Text("Phase: \(model.lifecyclePhase.rawValue)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      if let ip = model.resolvedIP {
        Text("Resolved IP: \(ip)").font(.headline)
      }

      HStack {
        Button {
          model.start()
        } label: {
          Label("Start (vmnet)", systemImage: "play.fill")
        }
        .disabled(model.busy || model.isRunning)

        Button {
          model.stop()
        } label: {
          Label("Stop", systemImage: "stop.fill")
        }
        .disabled(model.busy || !model.isRunning)

        if model.busy {
          ProgressView().controlSize(.small)
        }
      }

      if let statusMessage = model.statusMessage {
        Text(statusMessage).foregroundStyle(.secondary)
      }

      Divider()

      Text("Diagnostics").font(.headline)

      ScrollView {
        Text(model.diagnosticsText.isEmpty ? "No diagnostics yet — start the VM to populate this." : model.diagnosticsText)
          .font(.system(.body, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxHeight: .infinity)
    }
    .padding()
  }
}
