import SwiftUI
import TartCore

struct ContentView: View {
  @StateObject private var listModel = VMListModel()
  @State private var selection: VMEntry.ID?

  var body: some View {
    NavigationSplitView {
      List(listModel.entries, selection: $selection) { entry in
        Text(entry.name).tag(entry.id)
      }
      .navigationTitle("Tart VMs")
      .toolbar {
        ToolbarItem {
          Button {
            listModel.refresh()
          } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
        }
      }
      .overlay {
        if let errorMessage = listModel.errorMessage {
          ContentUnavailableFallback(message: errorMessage)
        } else if listModel.entries.isEmpty {
          ContentUnavailableFallback(message: "No VMs found under this TART_HOME.")
        }
      }
    } detail: {
      if let selection, let entry = listModel.entries.first(where: { $0.id == selection }) {
        VMDetailView(entry: entry)
          .id(entry.id)
      } else {
        ContentUnavailableFallback(message: "Select a VM on the left.")
      }
    }
    .onAppear { listModel.refresh() }
    .frame(minWidth: 820, minHeight: 560)
  }
}

/// `ContentUnavailableView` requires macOS 14; this package's deployment target is 13,
/// so a tiny fallback keeps the app usable on 13 without gating the whole view tree.
private struct ContentUnavailableFallback: View {
  let message: String

  var body: some View {
    if #available(macOS 14, *) {
      ContentUnavailableView(message, systemImage: "externaldrive.badge.questionmark")
    } else {
      Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
    }
  }
}
