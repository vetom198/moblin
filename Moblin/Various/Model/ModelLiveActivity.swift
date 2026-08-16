import ActivityKit
import Foundation

private let liveActivityEndTimeoutSeconds = 2.0

#if !targetEnvironment(macCatalyst)

extension Model {
    // Anything still showing at launch belongs to a process that is gone, so it
    // is stale by definition. Two reasons this has to happen here rather than
    // relying on the teardown paths:
    //
    // - willTerminate is not delivered when the user swipes away an app that is
    //   already suspended, so the activity outlives the app and keeps claiming
    //   "Live" in the Dynamic Island for hours. An operator glancing at the
    //   phone would believe the broadcast is up when nothing is running.
    // - startLiveActivity only guards against a duplicate through liveActivity,
    //   which is per process. A relaunch has a nil one and happily requests a
    //   second activity next to the orphan, which is why two extension
    //   processes were seen at once.
    func endStaleLiveActivities() {
        Task {
            for activity in Activity<LiveActivityAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func startLiveActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            return
        }
        guard liveActivity == nil else {
            return
        }
        // An orphan from a previous process would otherwise sit alongside this
        // one, showing whatever was true when that process died.
        endStaleLiveActivities()
        liveActivity = try? Activity.request(
            attributes: LiveActivityAttributes(),
            content: .init(state: makeState(), staleDate: nil)
        )
    }

    func stopLiveActivity() {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            Task {
                for activity in Activity<LiveActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
                semaphore.signal()
            }
        }
        // Bounded. This runs on the main thread on every return to the
        // foreground and on the way out, and an unbounded wait on ActivityKit
        // would hang the app rather than lose an activity that iOS cleans up
        // anyway.
        _ = semaphore.wait(timeout: .now() + liveActivityEndTimeoutSeconds)
        liveActivity = nil
    }

    func updateLiveActivity() {
        let state = makeState()
        Task {
            await liveActivity?.update(.init(state: state, staleDate: nil))
        }
    }

    private func makeState() -> LiveActivityAttributes.ContentState {
        var functions: [LiveActionFunction] = []
        if isLive {
            functions.append(LiveActionFunction(image: "livephoto",
                                                text: String(localized: "Live")))
        }
        if isRecording {
            functions.append(LiveActionFunction(image: "record.circle",
                                                text: String(localized: "Recording")))
        }
        if database.chat.background {
            functions.append(LiveActionFunction(image: "bubble.left",
                                                text: String(localized: "Background chat")))
        }
        if database.moblink.relay.enabled {
            functions.append(LiveActionFunction(
                image: "app.connected.to.app.below.fill",
                text: String(localized: "Moblink relay")
            ))
        }
        if database.catPrinters.backgroundPrinting {
            functions.append(LiveActionFunction(image: "pawprint",
                                                text: String(localized: "Background printing")))
        }
        if functions.count <= 3 {
            return LiveActivityAttributes.ContentState(functions: functions, showEllipsis: false)
        } else {
            return LiveActivityAttributes.ContentState(functions: Array(functions.prefix(2)),
                                                       showEllipsis: true)
        }
    }
}

#else

extension Model {
    func endStaleLiveActivities() {}

    func startLiveActivity() {}

    func stopLiveActivity() {}

    func updateLiveActivity() {}
}

#endif
