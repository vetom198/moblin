import SwiftUI

private struct PairingView: View {
    @ObservedObject var ctLive: SettingsCtLive
    @ObservedObject var tracker: CtLiveTracker
    @State private var code = ""

    private func canRedeem() -> Bool {
        code.count == 6 && !tracker.pairingBusy && tracker.pairingLockedUntil == nil
    }

    var body: some View {
        Section {
            TextItemView(name: String(localized: "Device ID"), value: tracker.deviceId)
            TextItemView(name: String(localized: "Owner"),
                         value: tracker.paired ? tracker.ownerUsername : String(localized: "Not paired"))
            if !ctLive.deviceInternalId.isEmpty {
                TextItemView(name: String(localized: "Backend ID"), value: ctLive.deviceInternalId)
            }
            HStack {
                Text("Pairing code")
                Spacer()
                TextField("123456", text: $code)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .onChange(of: code) { _ in
                        code = String(code.filter(\.isNumber).prefix(6))
                    }
            }
            TextButtonView("Pair") {
                tracker.redeemPairingCode(code: code)
                code = ""
            }
            .disabled(!canRedeem())
            TextButtonView("Check pairing") {
                tracker.checkPairing()
            }
            .disabled(tracker.pairingBusy)
            if tracker.paired {
                TextButtonView("Pair with another account") {
                    tracker.startRebinding()
                }
            }
            if tracker.pairingLockSecondsLeft > 0 {
                Text("Too many wrong codes. Try again in \(tracker.pairingLockSecondsLeft) s.")
                    .foregroundStyle(.red)
            } else if let pairingError = tracker.pairingError {
                Text(pairingError)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Device pairing")
        } footer: {
            VStack(alignment: .leading) {
                Text("""
                Log in at \(ctLive.baseUrl), generate a six digit pairing code and \
                enter it here. The code is valid for five minutes.
                """)
                Text("")
                Text("The device ID is kept in the keychain so it survives a reinstall.")
            }
        }
    }
}

private struct RemoteControlSectionView: View {
    let model: Model
    @ObservedObject var ctLive: SettingsCtLive
    @ObservedObject var tracker: CtLiveTracker

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: {
                ctLive.remoteControlEnabled
            }, set: { value in
                model.ctLiveSetRemoteControlEnabled(value)
            })) {
                Text("Allow remote control")
            }
            .disabled(!tracker.paired)
        } header: {
            Text("Remote control")
        } footer: {
            VStack(alignment: .leading) {
                Text("""
                Lets the race director start and stop the stream and recording,                 switch scenes and change the mic from the CTLive dashboard.                 Every remote change shows up on this phone.
                """)
                Text("")
                if !tracker.paired {
                    Text("Pair the device first.")
                } else if ctLive.controlToken.isEmpty {
                    Text("No control credential yet. Use Check pairing to fetch one.")
                }
            }
        }
    }
}

struct CtLiveSettingsView: View {
    let model: Model
    @ObservedObject var ctLive: SettingsCtLive
    @ObservedObject var tracker: CtLiveTracker

    private func submitBaseUrl(value: String) {
        ctLive.baseUrl = value.isEmpty ? ctLiveDefaultBaseUrl : value
    }

    private func submitApiKey(value: String) {
        ctLive.apiKey = value
    }

    private func submitProfileName(value: String) {
        ctLive.profileName = value
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: {
                    ctLive.enabled
                }, set: { value in
                    model.ctLiveSetEnabled(value)
                })) {
                    Text("Enabled")
                }
            } footer: {
                Text("""
                Sends this device's position, speed, distance and elapsed time to the CTLive \
                broadcast dashboard every couple of seconds while a ride is running.
                """)
            }
            PairingView(ctLive: ctLive, tracker: tracker)
            Section {
                TextEditNavigationView(title: String(localized: "Base URL"),
                                       value: ctLive.baseUrl,
                                       onChange: isValidHttpUrl,
                                       onSubmit: submitBaseUrl,
                                       placeholder: ctLiveDefaultBaseUrl)
                TextEditNavigationView(title: String(localized: "API key"),
                                       value: ctLive.apiKey,
                                       onSubmit: submitApiKey,
                                       sensitive: true)
                TextEditNavigationView(title: String(localized: "Device name"),
                                       value: ctLive.profileName,
                                       onSubmit: submitProfileName,
                                       capitalize: true,
                                       placeholder: UIDevice.current.name)
                HStack {
                    Text("Upload interval")
                    Slider(
                        value: $ctLive.uploadInterval,
                        in: ctLiveMinimumUploadInterval ... ctLiveMaximumUploadInterval,
                        step: 1,
                        label: {
                            EmptyView()
                        },
                        onEditingChanged: { begin in
                            guard !begin else {
                                return
                            }
                            tracker.updateUploadInterval()
                        }
                    )
                    Text("\(Int(ctLive.uploadInterval)) s")
                        .frame(width: 35)
                }
            } header: {
                Text("Server")
            } footer: {
                VStack(alignment: .leading) {
                    Text("Ask the CTLive administrator for the API key.")
                    Text("The device name is shown in the CTLive device list.")
                    Text("""
                    CTLive expects a sample every one to five seconds. A longer interval saves \
                    battery and data, but the broadcast overlay updates less often.
                    """)
                }
            }
            RemoteControlSectionView(model: model, ctLive: ctLive, tracker: tracker)
            Section {
                Toggle("Reset overlay data too", isOn: $ctLive.resetOverlayDataOnStart)
                Toggle("Start when going live", isOn: $ctLive.startWhenGoingLive)
            } header: {
                Text("Start line")
            } footer: {
                VStack(alignment: .leading) {
                    Text("""
                    The start line button always zeroes the distance and elapsed time sent to \
                    CTLive. Reset overlay data too also zeroes the distance, average speed and \
                    slope shown on the stream.
                    """)
                }
            }
        }
        .navigationTitle("CTLive")
    }
}
