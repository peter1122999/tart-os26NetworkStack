import SwiftUI
import TartCore

struct VmnetConfigEditorView: View {
  @ObservedObject var model: VMDetailModel

  var body: some View {
    Form {
      Section("Topology") {
        Picker("Topology", selection: $model.draftConfig.topology) {
          ForEach(VmnetConfig.Topology.allCases, id: \.self) { topology in
            Text(topology.rawValue.capitalized).tag(topology)
          }
        }

        if model.draftConfig.topology == .bridged {
          TextField("Bridge interface (e.g. en0)", text: Binding(
            get: { model.draftConfig.externalInterface ?? "" },
            set: { model.draftConfig.externalInterface = $0.isEmpty ? nil : $0 }
          ))
        }
      }

      Section("Subnet") {
        TextField("CIDR, e.g. 192.168.64.0/24 (blank = auto)", text: Binding(
          get: { model.draftConfig.subnet?.description ?? "" },
          set: { model.draftConfig.subnet = $0.isEmpty ? nil : CIDRBlock($0) }
        ))
      }

      Section("Toggles") {
        Toggle("DHCP enabled", isOn: $model.draftConfig.dhcpEnabled)
        Toggle("NAT enabled", isOn: $model.draftConfig.natEnabled)
        Toggle("DNS proxy enabled", isOn: $model.draftConfig.dnsEnabled)
      }

      Section("DHCP reservations") {
        ForEach(Array(model.draftConfig.reservations.enumerated()), id: \.offset) { index, _ in
          HStack {
            TextField("MAC address", text: $model.draftConfig.reservations[index].macAddress)
            TextField("IP address", text: $model.draftConfig.reservations[index].ipAddress)
            Button(role: .destructive) {
              model.removeReservations(at: IndexSet(integer: index))
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
          }
        }

        Button {
          model.addReservation()
        } label: {
          Label("Add reservation", systemImage: "plus.circle")
        }
      }

      if !model.validationErrors.isEmpty {
        Section("Problems") {
          ForEach(Array(model.validationErrors.enumerated()), id: \.offset) { _, error in
            Text(error.description).foregroundStyle(.red)
          }
        }
      }

      if let statusMessage = model.statusMessage {
        Section {
          Text(statusMessage).foregroundStyle(.secondary)
        }
      }

      Section {
        HStack {
          Button("Validate") { model.validate() }
          Spacer()
          Button("Save") { model.save() }.buttonStyle(.borderedProminent)
        }
      }
    }
    .formStyle(.grouped)
  }
}
