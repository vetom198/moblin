import SwiftUI

struct AboutSettingsView: View {
    @State var presentingVersionHistory: Bool = false

    var body: some View {
        Form {
            Section {
                TextItemLocalizedView(name: "Version", value: appVersion())
                // Which Moblin this fork descends from. The first question when
                // a bug might be upstream's, and impossible to answer from the
                // app otherwise.
                TextItemLocalizedView(name: "Based on Moblin", value: upstreamMoblinVersion())
                NavigationLink {
                    AboutAttributionsSettingsView()
                } label: {
                    Text("Attributions")
                }
            }
            Section {
                NavigationLink {
                    AboutCtLiveVersionHistoryView()
                } label: {
                    Text("CTLiveGo version history")
                }
            }
            Section {
                TextButtonView("Moblin version history") {
                    presentingVersionHistory = true
                }
                .sheet(isPresented: $presentingVersionHistory) {
                    ZStack {
                        AboutVersionHistorySettingsView()
                        CloseButtonTopRightView {
                            presentingVersionHistory = false
                        }
                    }
                }
            }
            // CTLiveGo's own policy, on CTLive's own domain. App Review needs a
            // privacy policy that belongs to whoever ships the app, and
            // upstream's describes a different app run by different people.
            ExternalUrlButtonView(url: "https://live.ctyeh.com/legal/privacy/") {
                Text("Privacy policy")
            }
            // Covers the CTLive service, not the app: what pairing a device
            // grants the dashboard, and what the platform does not promise.
            // The EULA below is about the software licence and says nothing
            // about any of that.
            ExternalUrlButtonView(url: "https://live.ctyeh.com/legal/terms/") {
                Text("Terms of service")
            }
            ExternalUrlButtonView(url: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
                Text("End-user license agreement (EULA)")
            }
        }
        .navigationTitle("About")
    }
}
