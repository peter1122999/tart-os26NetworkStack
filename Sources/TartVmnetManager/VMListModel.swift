import Foundation
import TartCore

/// One row in the VM sidebar. Wraps the `VMDirectory` the "tart" module already hands
/// back from `VMStorageLocal().list()` — no re-fetching or re-parsing of VM state, this
/// app just presents what's already on disk.
struct VMEntry: Identifiable, Hashable {
  let name: String
  let directory: VMDirectory
  var id: String { name }

  static func == (lhs: VMEntry, rhs: VMEntry) -> Bool { lhs.name == rhs.name }
  func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

@MainActor
final class VMListModel: ObservableObject {
  @Published var entries: [VMEntry] = []
  @Published var errorMessage: String?

  func refresh() {
    do {
      let storage = try VMStorageLocal()
      entries = try storage.list()
        .map { VMEntry(name: $0.0, directory: $0.1) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
      errorMessage = nil
    } catch {
      errorMessage = "\(error)"
    }
  }
}
