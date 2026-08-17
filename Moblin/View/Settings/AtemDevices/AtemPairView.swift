import SwiftUI

struct AtemPairView: View {
    @ObservedObject var atemDevices: SettingsAtemDevices
    let onComplete: (AtemDiscoveredDevice?) -> Void

    @StateObject private var scanner = AtemPairScanner()
    @State private var pendingConfirm: AtemDiscoveredDevice?

    var body: some View {
        Form {
            Section {
                if scanner.devices.isEmpty {
                    HCenter {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Scanning local network for ATEM switchers...")
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.vertical)
                    }
                } else {
                    ForEach(scanner.devices) { device in
                        Button {
                            pendingConfirm = device
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(device.name)
                                        .foregroundColor(.primary)
                                    Text(device.host)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Discovered devices")
            } footer: {
                Text(
                    """
                    If your ATEM doesn't appear, ensure it's powered on, connected by Ethernet to \
                    the same router, and that it has been assigned an IP.
                    """
                )
            }
        }
        .navigationTitle("Pair ATEM")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onComplete(nil) }
            }
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .alert(item: $pendingConfirm) { device in
            Alert(
                title: Text("Confirm ATEM"),
                message: Text("Pair with \"\(device.name)\" at \(device.host)?"),
                primaryButton: .default(Text("Pair")) {
                    onComplete(device)
                },
                secondaryButton: .cancel()
            )
        }
    }
}

private final class AtemPairScanner: ObservableObject {
    @Published var devices: [AtemDiscoveredDevice] = []
    private let discovery = AtemDiscovery()

    init() {
        discovery.delegate = self
    }

    func start() {
        discovery.start()
    }

    func stop() {
        discovery.stop()
    }
}

extension AtemPairScanner: AtemDiscoveryDelegate {
    func atemDiscoveryUpdate(devices: [AtemDiscoveredDevice]) {
        self.devices = devices
    }
}
