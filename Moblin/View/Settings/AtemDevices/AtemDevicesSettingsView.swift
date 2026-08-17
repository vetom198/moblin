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
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                    if device.lastSyncStatus != .never {
                        Text(device.lastSyncStatus.description)
                            .font(.caption)
                            .foregroundColor(syncStatusColor(device.lastSyncStatus))
                    }
                }
                Spacer()
                GrayTextView(text: device.host.isEmpty
                    ? String(localized: "Not paired")
                    : device.host)
            }
        }
    }
}

func syncStatusColor(_ status: AtemSyncStatus) -> Color {
    switch status {
    case .succeeded: .green
    case .failed, .notFound: .red
    case .scanning, .pushing: .accentColor
    case .never: .secondary
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
                Toggle("Auto-sync globally", isOn: $atemDevices.autoSyncEnabled)
                Button {
                    model.runManualAtemSync()
                } label: {
                    HStack {
                        Label("Re-discover and sync now", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                    }
                }
                .disabled(atemDevices.devices.isEmpty)
            } footer: {
                Text(
                    """
                    Auto-sync re-discovers each enabled ATEM by Bonjour name and re-pushes the RTMP \
                    destination after the RTMP server reloads or the app foregrounds. Manual sync \
                    ignores both the global and per-device toggles.
                    """
                )
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
                        new.bonjourName = confirmed.name
                        new.host = confirmed.host
                        new.enabled = true
                        atemDevices.devices.append(new)
                    }
                }
            }
        }
    }
}
