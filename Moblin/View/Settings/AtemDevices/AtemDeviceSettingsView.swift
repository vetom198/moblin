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
                        if pushState.status.isBusy {
                            ProgressView()
                        } else {
                            Label("Push to ATEM", systemImage: "arrow.up.right.square")
                                .foregroundColor(canPush() ? .accentColor : .secondary)
                        }
                    }
                }
                .disabled(!canPush() || pushState.status.isBusy)
                Text(pushState.status.description)
                    .font(.footnote)
                    .foregroundColor(pushStatusColor())
                    .frame(maxWidth: .infinity, alignment: .center)
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
        pushState.push(host: device.host,
                       serviceName: device.serviceName,
                       url: dest.url,
                       key: dest.key)
    }

    private func pushStatusColor() -> Color {
        switch pushState.status {
        case .succeeded: .green
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

    func push(host: String, serviceName: String, url: String, key: String) {
        let controller = AtemController(host: host)
        controller.delegate = self
        self.controller = controller
        controller.pushStream(serviceName: serviceName, url: url, key: key)
    }
}

extension AtemPushState: AtemControllerDelegate {
    nonisolated func atemControllerStatusChanged(status: AtemControllerStatus) {
        Task { @MainActor in
            self.status = status
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
