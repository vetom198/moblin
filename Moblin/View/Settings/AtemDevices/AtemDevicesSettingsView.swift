import SwiftUI

private struct AtemDeviceWrapperView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var database: Database
    @ObservedObject var device: SettingsAtemDevice

    var body: some View {
        NavigationLink {
            AtemDeviceSettingsView(database: database, device: device)
        } label: {
            HStack {
                DraggableItemPrefixView()
                Text(device.name)
                Spacer()
                GrayTextView(text: device.host.isEmpty
                             ? String(localized: "Not paired")
                             : device.host)
            }
        }
    }
}

struct AtemDevicesSettingsView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var database: Database
    @ObservedObject var atemDevices: SettingsAtemDevices

    @State private var showingPair = false

    private func deleteDevice(at offsets: IndexSet) {
        atemDevices.devices.remove(atOffsets: offsets)
    }

    var body: some View {
        Form {
            Section {
                Text("""
                Pair an ATEM Mini Pro / Extreme to push RTMP destination settings to it from CTLiveGo. \
                Both this device and the ATEM must be on the same LAN.
                """)
            }
            Section {
                List {
                    ForEach(atemDevices.devices) { device in
                        AtemDeviceWrapperView(database: database, device: device)
                            .contextMenuDeleteButton {
                                if let offsets = makeOffsets(atemDevices.devices, device.id) {
                                    deleteDevice(at: offsets)
                                }
                            }
                    }
                    .onMove { froms, to in
                        atemDevices.devices.move(fromOffsets: froms, toOffset: to)
                    }
                    .onDelete(perform: deleteDevice)
                }
                Button {
                    showingPair = true
                } label: {
                    HCenter {
                        Label("Search and pair", systemImage: "magnifyingglass")
                    }
                }
            } footer: {
                SwipeLeftToDeleteHelpView(kind: String(localized: "a device"))
            }
        }
        .navigationTitle("ATEM switchers")
        .sheet(isPresented: $showingPair) {
            NavigationStack {
                AtemPairView(atemDevices: atemDevices) { confirmed in
                    showingPair = false
                    if let confirmed {
                        let new = SettingsAtemDevice()
                        new.name = makeUniqueName(name: confirmed.name,
                                                  existingNames: atemDevices.devices)
                        new.host = confirmed.host
                        new.enabled = true
                        atemDevices.devices.append(new)
                    }
                }
            }
        }
    }
}
