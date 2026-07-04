import SwiftUI

struct VMDetailView: View {
  let entry: VMEntry
  @StateObject private var model: VMDetailModel

  init(entry: VMEntry) {
    self.entry = entry
    _model = StateObject(wrappedValue: VMDetailModel(directory: entry.directory))
  }

  var body: some View {
    TabView {
      VmnetConfigEditorView(model: model)
        .tabItem { Label("Network", systemImage: "network") }

      LifecycleDiagnosticsView(model: model)
        .tabItem { Label("Lifecycle", systemImage: "bolt.horizontal.circle") }
    }
    .padding()
    .navigationTitle(entry.name)
    .onAppear { model.reloadStatus() }
  }
}
