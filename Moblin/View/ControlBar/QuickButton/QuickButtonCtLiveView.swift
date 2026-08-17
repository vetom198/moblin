import SwiftUI

// Race time reads better as 0:00:00 than as "1h 2m 3s".
private func formatRaceTime(_ seconds: Double) -> String {
    let seconds = Int(max(seconds, 0))
    return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
}

private func formatGrade(_ grade: Double) -> String {
    String(format: "%.1f %%", grade)
}

private struct StartLineButtonView: View {
    let model: Model
    @ObservedObject var ctLive: CtLiveTracker
    @State private var presentingRestartConfirm = false

    private func start() {
        model.ctLiveStartRace()
    }

    var body: some View {
        Section {
            Button {
                // Restarting mid race throws away the distance and time the
                // broadcast is showing, so make that an explicit choice.
                if ctLive.rideStatus != .stopped, ctLive.distance > 0 || ctLive.elapsedTime > 0 {
                    presentingRestartConfirm = true
                } else {
                    start()
                }
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "flag.checkered")
                    Text("Start line")
                    Spacer()
                }
                .font(.title3)
                .bold()
                .padding(.vertical, 8)
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .listRowBackground(Color.green)
            .confirmationDialog("", isPresented: $presentingRestartConfirm) {
                Button("Restart from zero", role: .destructive) {
                    start()
                }
            }
        } footer: {
            Text("Zeroes distance and elapsed time, then starts sending data.")
        }
    }
}

private struct RideControlsView: View {
    let model: Model
    @ObservedObject var ctLive: CtLiveTracker

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: {
                ctLive.uploading
            }, set: { value in
                if value {
                    model.ctLiveStartUploading()
                } else {
                    model.ctLiveStopUploading()
                }
            })) {
                Text("Send data")
            }
            if ctLive.uploading {
                TextButtonView(ctLive.rideStatus == .paused ? "Resume" : "Pause") {
                    model.ctLiveTogglePaused()
                }
            }
            TextButtonView("Reset distance and time") {
                model.ctLiveResetData()
            }
        }
    }
}

private struct RideDataView: View {
    @ObservedObject var ctLive: CtLiveTracker

    private func accuracy() -> String {
        guard let horizontalAccuracy = ctLive.horizontalAccuracy else {
            return String(localized: "No fix")
        }
        return format(distance: horizontalAccuracy)
    }

    var body: some View {
        Section {
            TextItemView(name: String(localized: "Distance"), value: format(distance: ctLive.distance))
            TextItemView(name: String(localized: "Elapsed time"),
                         value: formatRaceTime(ctLive.elapsedTime))
            TextItemView(name: String(localized: "Speed"), value: format(speed: ctLive.speed))
            TextItemView(name: String(localized: "Elevation gain"),
                         value: format(altitude: ctLive.elevationGain))
            TextItemView(name: String(localized: "Slope"), value: formatGrade(ctLive.elevationGrade))
            TextItemView(name: String(localized: "GPS accuracy"), value: accuracy())
        } header: {
            Text("Ride data")
        }
    }
}

private struct UploadStatusView: View {
    @ObservedObject var ctLive: CtLiveTracker

    private func status() -> String {
        if !ctLive.uploading {
            return String(localized: "Stopped")
        }
        switch ctLive.rideStatus {
        case .recording:
            return String(localized: "Riding")
        case .paused:
            return String(localized: "Paused")
        case .stopped:
            return String(localized: "Stopped")
        }
    }

    private func lastUpload() -> String {
        guard let lastUploadAt = ctLive.lastUploadAt else {
            return String(localized: "Never")
        }
        return digitalClockFormatter.string(from: lastUploadAt)
    }

    var body: some View {
        Section {
            TextItemView(name: String(localized: "Status"), value: status())
            TextItemView(name: String(localized: "Paired with"),
                         value: ctLive.paired ? ctLive.ownerUsername : String(localized: "Not paired"))
            TextItemView(name: String(localized: "Last upload"), value: lastUpload())
            TextItemView(name: String(localized: "Sent"), value: String(ctLive.uploadedCount))
            TextItemView(name: String(localized: "Failed"), value: String(ctLive.failedCount))
            if let lastError = ctLive.lastError {
                Text(lastError)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Upload")
        }
    }
}

private struct RemoteControlStatusView: View {
    let model: Model
    @ObservedObject var ctLiveSettings: SettingsCtLive

    var body: some View {
        if ctLiveSettings.remoteControlEnabled {
            Section {
                TextItemView(name: String(localized: "Director"),
                             value: model.isRemoteControlStreamerConnected()
                                 ? String(localized: "Connected")
                                 : String(localized: "Not connected"))
                // The operator holds the camera and must always be able to take
                // control back, without digging through settings.
                TextButtonView("Cut remote control") {
                    model.ctLiveSetRemoteControlEnabled(false)
                }
                .foregroundStyle(.red)
            } header: {
                Text("Remote control")
            }
        }
    }
}

// Location updates are what keep this app running with the screen off, and iOS
// relaunches it while they are on. So closing the app after a race does not
// stick until streaming, recording, the ride upload and the director's link are
// all off, which is four things in three screens. This is that, in one tap.
private struct EndSessionView: View {
    let model: Model
    @State private var presentingConfirm = false

    var body: some View {
        Section {
            TextButtonView("End session and allow closing") {
                presentingConfirm = true
            }
            .foregroundStyle(.red)
            .confirmationDialog("", isPresented: $presentingConfirm) {
                Button("End session", role: .destructive) {
                    model.ctLiveEndSession()
                }
            } message: {
                Text("Stops the stream, recording and upload, and disconnects the director.")
            }
        } footer: {
            Text("""
            The app keeps running in the background so the director can reach it. \
            End the session when the broadcast is over, then close the app as usual.
            """)
        }
    }
}

struct QuickButtonCtLiveView: View {
    let model: Model
    @ObservedObject var ctLive: CtLiveTracker
    @ObservedObject var ctLiveSettings: SettingsCtLive

    var body: some View {
        Form {
            if !ctLiveSettings.enabled {
                Section {
                    Toggle(isOn: Binding(get: {
                        ctLiveSettings.enabled
                    }, set: { value in
                        model.ctLiveSetEnabled(value)
                    })) {
                        Text("Enabled")
                    }
                } footer: {
                    Text("Turn on to send this device's position to CTLive.")
                }
            }
            StartLineButtonView(model: model, ctLive: ctLive)
            RideControlsView(model: model, ctLive: ctLive)
            RideDataView(ctLive: ctLive)
            UploadStatusView(ctLive: ctLive)
            RemoteControlStatusView(model: model, ctLiveSettings: ctLiveSettings)
            EndSessionView(model: model)
            ShortcutSectionView {
                NavigationLink {
                    CtLiveSettingsView(model: model, ctLive: ctLiveSettings, tracker: ctLive)
                } label: {
                    Label("CTLive", systemImage: "flag.checkered")
                }
            }
        }
        .navigationTitle("CTLive")
    }
}
