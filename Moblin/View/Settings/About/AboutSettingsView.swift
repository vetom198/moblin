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
            ExternalUrlButtonView(url: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") {
                Text("End-user license agreement (EULA)")
            }
        }
        .navigationTitle("About")
    }
}
