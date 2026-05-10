import SwiftUI

// Row variant — used inside IngestsSettingsView's grouped Form.
// Tapping pushes RtmpServerStandaloneSettingsView (the actual page).
struct RtmpServerSettingsView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var rtmpServer: SettingsRtmpServer

    private func status() -> String {
        if rtmpServer.enabled {
            String(rtmpServer.streams.count)
        } else {
            "0"
        }
    }

    var body: some View {
        NavigationLink {
            RtmpServerStandaloneSettingsView(rtmpServer: rtmpServer)
        } label: {
            HStack {
                Text("RTMP server")
                Spacer()
                GrayTextView(text: status())
            }
        }
    }
}
