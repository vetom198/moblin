import SwiftUI

struct HelpAndSupportSettingsView: View {
    var body: some View {
        Form {
            // Upstream sent people to the Moblin Discord and Github. Neither
            // can help with a device a race organiser manages: the settings
            // that matter here are pushed from the dashboard, and the people
            // there have never seen this build.
            Section {
                ExternalUrlButtonView(url: "https://live.ctyeh.com/") {
                    Text("CTLive dashboard")
                }
            } footer: {
                VStack(alignment: .leading) {
                    Text("""
                    Ask the race organiser for help with this device. They can \
                    see it on the CTLive dashboard and change its settings from \
                    there.
                    """)
                    Text("")
                    Text("They will ask for the device ID, which is in Settings → CTLive.")
                }
            }
        }
        .navigationTitle("Help and support")
    }
}
