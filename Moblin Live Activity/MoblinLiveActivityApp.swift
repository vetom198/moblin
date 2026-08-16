import SwiftUI
import WidgetKit

// Dimmed rather than hidden: the icon still has to be recognisable in the
// Dynamic Island, it just must not look authoritative.
private let staleOpacity = 0.4

private struct MoblinLiveActivityIcon: View {
    var body: some View {
        Image("AppIcon")
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

private struct IconAndTextView: View {
    let image: String
    let text: String

    var body: some View {
        HStack {
            Image(systemName: image)
                .frame(width: 20)
            Text(text)
        }
        .foregroundColor(.white)
    }
}

private struct MoblinLiveActivityStatusLabel: View {
    let state: LiveActivityAttributes.ContentState

    var body: some View {
        ForEach(state.functions, id: \.image) { function in
            IconAndTextView(image: function.image, text: function.text)
        }
        if state.showEllipsis {
            HStack {
                Image(systemName: "record.circle")
                    .frame(width: 20)
                    .foregroundColor(.clear)
                Text(String("..."))
                    .foregroundColor(.white)
            }
        }
    }
}

@main
struct MoblinLiveActivityApp: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivityAttributes.self) { context in
            VStack(alignment: .leading) {
                HStack {
                    MoblinLiveActivityIcon()
                        .frame(width: 40, height: 40)
                        .opacity(context.isStale ? staleOpacity : 1)
                    // Swiping the app away leaves this activity behind with no
                    // way to update or end it, so once the content has gone
                    // stale it must stop claiming the app is running. Saying
                    // "Live" next to a dead app is worse than saying nothing.
                    Text(context.isStale ? "Moblin may have stopped" : "Moblin is running in background")
                        .lineLimit(1)
                        .font(.headline)
                        .foregroundColor(.white)
                }
                Divider()
                if context.isStale {
                    IconAndTextView(image: "questionmark.circle", text: String(localized: "Status unknown"))
                        .padding(.leading, 10)
                } else {
                    MoblinLiveActivityStatusLabel(state: context.state)
                        .padding(.leading, 10)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.8))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MoblinLiveActivityIcon()
                        .frame(width: 36, height: 36)
                        .opacity(context.isStale ? staleOpacity : 1)
                }
            } compactLeading: {
                MoblinLiveActivityIcon()
                    .opacity(context.isStale ? staleOpacity : 1)
            } compactTrailing: {
                EmptyView()
            } minimal: {
                MoblinLiveActivityIcon()
                    .opacity(context.isStale ? staleOpacity : 1)
            }
        }
    }
}
