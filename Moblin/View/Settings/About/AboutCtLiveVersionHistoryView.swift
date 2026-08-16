import SwiftUI

// CTLiveGo's own history. Upstream Moblin's changelog is kept separately: it is
// long, it is written for a different audience, and mixing the two would make it
// impossible to see what actually changed for a race crew.
//
// Newest first. One entry per released version, and only changes an operator or
// a director would notice. Internal refactors belong in the git log.
private let ctLiveVersions = [
    CtLiveVersion(version: "1.0.0", date: "2026-08-17", changes: [
        "• First CTLiveGo release, versioned separately from Moblin.",
        "• CTLive remote control: the director can start and stop the stream, "
            + "switch scenes, change the mic and see the phone's status from the dashboard.",
        "• Push targets are managed from the CTLive dashboard. The photographer "
            + "never has to type an ingest address on the phone.",
        "  • A target arriving mid stream is stored and applied afterwards, never "
            + "cut into a running broadcast.",
        "  • Stream keys are kept in the keychain and never shown in the app.",
        "• The control connection survives switching push target, checking the "
            + "pairing and reloading chat, instead of dropping the director each time.",
        "• The control connection is restored after iOS restarts the app in the "
            + "background, which previously lost the device until someone opened the app.",
        "• The Dynamic Island stops claiming the stream is live once the app is "
            + "no longer running.",
        "• Settings trimmed to what a race broadcast uses.",
    ]),
]

private struct CtLiveVersion {
    let version: String
    let date: String
    let changes: [String]
}

struct AboutCtLiveVersionHistoryView: View {
    var body: some View {
        Form {
            ForEach(ctLiveVersions, id: \.version) { version in
                Section {
                    ForEach(version.changes, id: \.self) { change in
                        Text(change)
                    }
                } header: {
                    Text("\(version.version) — \(version.date)")
                }
            }
        }
        .navigationTitle("CTLiveGo version history")
    }
}
