import Network
import SwiftUI

struct AtemDeviceSettingsView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var database: Database
    @ObservedObject var device: SettingsAtemDevice

    @StateObject private var pushState = AtemPushState()

    var body: some View {
        Form {
            Section {
                NameEditView(name: $device.name)
                NavigationLink {
                    AtemHostEditView(device: device)
                } label: {
                    HStack {
                        Text("Host")
                        Spacer()
                        Text(device.host.isEmpty ? "—" : device.host)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section {
                Picker("Source", selection: $device.rtmpSource) {
                    Text("Saved RTMP server stream").tag(SettingsAtemRtmpSource.savedRtmpStream)
                    Text("Custom URL").tag(SettingsAtemRtmpSource.custom)
                }
                .pickerStyle(.menu)

                switch device.rtmpSource {
                case .savedRtmpStream:
                    savedStreamPicker
                case .custom:
                    customFields
                }
            } header: {
                Text("RTMP destination")
            }

            Section {
                Toggle("Auto-sync on RTMP server change", isOn: $device.autoSync)
                if device.bonjourName.isEmpty {
                    Text("Auto-sync needs the Bonjour name captured at pair time. Re-pair this device to enable it.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else {
                    Text("Bonjour: \(device.bonjourName)")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Last sync")
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text(device.lastSyncStatus.description)
                            .foregroundColor(syncStatusColor(device.lastSyncStatus))
                        if let at = device.lastSyncAt {
                            Text(at.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                Button {
                    model.runManualAtemSync(reason: "device-tap")
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                }
            } footer: {
                Text("When the RTMP server starts on a new IP — for example after switching Wi-Fi networks — CTLiveGo re-discovers this ATEM by its Bonjour name and re-pushes the destination.")
            }

            Section {
                Text(buildPreviewUrl().nonEmpty ?? String(localized: "No RTMP destination configured"))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            } header: {
                Text("URL pushed to ATEM")
            } footer: {
                Text("CTLiveGo derives the host from the active LAN interface at push time. Make sure the ATEM can reach this device on the LAN.")
            }

            Section {
                Button {
                    push()
                } label: {
                    HCenter {
                        if pushState.status == .pushing || pushState.status == .connecting {
                            ProgressView()
                        } else {
                            Label("Go Live on ATEM", systemImage: "dot.radiowaves.left.and.right")
                                .foregroundColor(canPush() ? .red : .secondary)
                        }
                    }
                }
                .disabled(!canPush() || pushState.status.isBusy)
                Button {
                    pushState.stop(device: device)
                } label: {
                    HCenter {
                        if pushState.status == .stopping {
                            ProgressView()
                        } else {
                            Label("Stop ATEM Stream", systemImage: "stop.fill")
                                .foregroundColor(device.host.isEmpty ? .secondary : .primary)
                        }
                    }
                }
                .disabled(device.host.isEmpty || pushState.status.isBusy)
                Text(pushState.status.description)
                    .font(.footnote)
                    .foregroundColor(pushStatusColor())
                    .frame(maxWidth: .infinity, alignment: .center)
            } footer: {
                Text("Go Live tells the ATEM to start streaming to the destination above immediately. Stop tells it to stop. The ATEM's saved \"Platform\" preset in ATEM Software Control is unaffected.")
            }

            Section {
                if let name = device.lastReadServiceName, let url = device.lastReadUrl {
                    HStack(alignment: .top) {
                        Text("Service")
                        Spacer()
                        Text(name).foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack(alignment: .top) {
                        Text("URL")
                        Spacer()
                        Text(url.isEmpty ? "—" : url)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.trailing)
                            .textSelection(.enabled)
                    }
                    if let at = device.lastReadAt {
                        HStack {
                            Text("Read at")
                            Spacer()
                            Text(at.formatted(date: .omitted, time: .standard))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                } else {
                    Text("No data — push or sync this device once to read its current settings.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } header: {
                Text("Current settings on ATEM")
            } footer: {
                Text("Read from the switcher (SRSU) during the last connection. After a successful push these should match the URL above.")
            }
        }
        .navigationTitle(device.name)
    }

    private var savedStreamPicker: some View {
        Picker("Stream", selection: streamBinding()) {
            Text("Select").tag(UUID?.none)
            ForEach(database.rtmpServer.streams) { stream in
                Text(stream.name).tag(Optional(stream.id))
            }
        }
    }

    private var customFields: some View {
        Group {
            TextEditNavigationView(
                title: String(localized: "URL"),
                value: device.customRtmpUrl,
                onSubmit: { device.customRtmpUrl = $0 },
                placeholder: "rtmp://example.com:1935/live"
            )
            TextEditNavigationView(
                title: String(localized: "Stream key"),
                value: device.customStreamKey,
                onSubmit: { device.customStreamKey = $0 }
            )
        }
    }

    private func streamBinding() -> Binding<UUID?> {
        Binding(
            get: { device.rtmpStreamId },
            set: { device.rtmpStreamId = $0 }
        )
    }

    private func canPush() -> Bool {
        guard !device.host.isEmpty else { return false }
        switch device.rtmpSource {
        case .savedRtmpStream:
            return resolvedStream() != nil
        case .custom:
            return !device.customRtmpUrl.isEmpty
        }
    }

    private func resolvedStream() -> SettingsRtmpServerStream? {
        guard let id = device.rtmpStreamId else { return nil }
        return database.rtmpServer.streams.first(where: { $0.id == id })
    }

    private func buildPreviewUrl() -> String {
        atemResolveDestination(device: device, rtmpServer: database.rtmpServer)?.fullUrl ?? ""
    }

    private func push() {
        guard let dest = atemResolveDestination(device: device, rtmpServer: database.rtmpServer),
              !device.host.isEmpty else { return }
        pushState.push(device: device,
                       serviceName: device.serviceName,
                       url: dest.url,
                       key: dest.key)
    }

    private func pushStatusColor() -> Color {
        switch pushState.status {
        case .succeeded: .green
        case .stopped: .secondary
        case .failed: .red
        default: .secondary
        }
    }
}

// MARK: - host editor

private struct AtemHostEditView: View {
    @ObservedObject var device: SettingsAtemDevice
    @State private var draft: String = ""

    var body: some View {
        Form {
            Section {
                TextField("e.g. 192.168.1.10", text: $draft)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } footer: {
                Text("ATEM IP on the local network. Use the search-and-pair flow to discover it automatically.")
            }
        }
        .navigationTitle("Host")
        .onAppear { draft = device.host }
        .onDisappear { device.host = draft.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - push state

@MainActor
final class AtemPushState: ObservableObject {
    @Published var status: AtemControllerStatus = .idle
    private var controller: AtemController?
    weak var device: SettingsAtemDevice?

    func push(device: SettingsAtemDevice, serviceName: String, url: String, key: String) {
        self.device = device
        let controller = AtemController(host: device.host)
        controller.delegate = self
        self.controller = controller
        controller.pushStream(serviceName: serviceName, url: url, key: key)
    }

    func stop(device: SettingsAtemDevice) {
        self.device = device
        let controller = AtemController(host: device.host)
        controller.delegate = self
        self.controller = controller
        controller.stopStream()
    }
}

extension AtemPushState: AtemControllerDelegate {
    nonisolated func atemControllerStatusChanged(status: AtemControllerStatus) {
        Task { @MainActor in
            self.status = status
        }
    }

    nonisolated func atemControllerDidReadStreamingService(serviceName: String, url: String) {
        Task { @MainActor in
            self.device?.lastReadServiceName = serviceName
            self.device?.lastReadUrl = url
            self.device?.lastReadAt = Date()
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
