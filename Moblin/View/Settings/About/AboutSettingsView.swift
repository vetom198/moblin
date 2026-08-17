import SwiftUI

struct AboutSettingsView: View {
    var body: some View {
        Form {
            Section {
                TextItemLocalizedView(name: "Version", value: appVersion())
                // The upstream release this descends from, and upstream's own
                // changelog, used to be here. A race crew has no use for either
                // and no way to act on them. The licence that requires crediting
                // upstream is honoured under Attributions, which is where a
                // reader looks for it.
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
