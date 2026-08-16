import Foundation

// Push targets pushed down from the CTLive dashboard.
//
// The product rule this exists for: the photographer in the field concentrates
// on filming and never touches the phone. The ingest and which one is live are
// both decided on the web.
//
// The one thing that must never happen is cutting a running broadcast. The
// dashboard resends the whole profile list whenever anything changes, including
// mid race, so applying it is deliberately split: the list is always stored,
// but the stream is only actually switched when nothing is going out.
extension Model {
    // Called before the current stream is picked at launch, because a managed
    // stream has no usable url until the keychain has been read.
    func ctLiveLoadStreamProfiles() {
        guard let profiles = CtLiveStreamProfiles.load() else {
            // Nothing stored is the normal case for a device that has never
            // been given profiles, and is indistinguishable here from a
            // keychain that is not readable yet. Only treat it as loaded when
            // there is no managed stream waiting for a url, so the retry does
            // not fire forever on devices that simply have no profiles.
            ctLiveStreamProfilesLoaded = !database.streams.contains { $0.isCtLiveManaged() }
            if !ctLiveStreamProfilesLoaded {
                logger.info("ct-live: Stream profiles not readable yet, will retry")
            }
            return
        }
        ctLiveStreamProfilesLoaded = true
        applyCtLiveStreamProfiles(profiles: profiles, switchStream: false)
        adoptActiveCtLiveProfileIfNoStreamEnabled(profiles: profiles)
    }

    // Keychain items survive a reinstall but the settings file does not, so a
    // reinstalled app can end up with the dashboard's profiles restored and
    // nothing enabled. Falling back to an empty default stream in that state
    // would be the worst outcome: the operator reinstalled to fix something and
    // silently lost the ingest. Runs before setCurrentStream(), so setting the
    // flag is enough.
    private func adoptActiveCtLiveProfileIfNoStreamEnabled(profiles: [RemoteControlStreamProfile]) {
        guard !database.streams.contains(where: \.enabled) else {
            return
        }
        guard let active = profiles.first(where: { $0.isActive }),
              let target = database.streams.first(where: { $0.ctLiveProfileId == active.id })
        else {
            return
        }
        logger.info("ct-live: No stream enabled, adopting profile \(active.id)")
        target.enabled = true
    }

    // The keychain is unreadable between a reboot and the first unlock, and the
    // app can be launched in that window by a location update. Without this a
    // managed stream would keep an empty url until the operator noticed.
    func ctLiveRetryLoadStreamProfilesIfNeeded() {
        guard !ctLiveStreamProfilesLoaded else {
            return
        }
        ctLiveLoadStreamProfiles()
        guard ctLiveStreamProfilesLoaded else {
            return
        }
        logger.info("ct-live: Stream profiles recovered from the keychain")
        // The current stream may be the one that was missing its url.
        reloadStreamIfEnabled(stream: stream)
    }

    func ctLiveSetStreamProfiles(profiles: [RemoteControlStreamProfile]) {
        CtLiveStreamProfiles.store(profiles: profiles)
        // The dashboard just told us what the profiles are, so there is nothing
        // left for the keychain retry to recover.
        ctLiveStreamProfilesLoaded = true
        let switched = applyCtLiveStreamProfiles(profiles: profiles, switchStream: !isLive)
        storeSettings()
        if isLive {
            // Not a failure. The dashboard is expected to send the list at any
            // time and the operator would rather keep the broadcast than have
            // the newest ingest.
            logger.info("ct-live: Stored \(profiles.count) stream profiles, not switching while live")
            makeToast(title: String(localized: "CTLive updated the stream settings"),
                      subTitle: String(localized: "Applied after this stream ends"))
        } else if switched {
            makeToast(title: String(localized: "CTLive switched the stream target"),
                      subTitle: activeCtLiveProfileName(),
                      vibrate: true)
        }
    }

    // The dashboard only sends this when it believes nothing is going out, so
    // this one is allowed to reload the stream.
    func ctLiveSetActiveStreamProfile(id: String) {
        guard var profiles = CtLiveStreamProfiles.load() else {
            logger.info("ct-live: Cannot activate profile, no profiles stored")
            return
        }
        guard profiles.contains(where: { $0.id == id }) else {
            logger.info("ct-live: Cannot activate unknown profile")
            return
        }
        for index in profiles.indices {
            profiles[index].isActive = profiles[index].id == id
        }
        CtLiveStreamProfiles.store(profiles: profiles)
        // "The dashboard only sends this when nothing is going out" is a claim
        // about a value it saw at least one status ago. The backend resends the
        // activation the moment it sees isLive go false, and the operator can
        // start the next stream inside that window, so this command can arrive
        // just after going live. Switching then would cut the broadcast, which
        // is the one outcome the whole design exists to avoid. Storing it is
        // enough: the backend resends on the next stop, because the applied id
        // reported back still will not match what it wants.
        guard !isLive else {
            logger.info("ct-live: Not activating a stream profile while live, stored only")
            storeSettings()
            makeToast(title: String(localized: "CTLive updated the stream settings"),
                      subTitle: String(localized: "Applied after this stream ends"))
            return
        }
        let switched = applyCtLiveStreamProfiles(profiles: profiles, switchStream: true)
        storeSettings()
        guard switched else {
            // Already on it. Saying "switched" would be a lie, and a vibrating
            // toast for nothing trains the operator to ignore them.
            logger.info("ct-live: Profile \(id) is already the current stream")
            return
        }
        makeToast(title: String(localized: "CTLive switched the stream target"),
                  subTitle: activeCtLiveProfileName(),
                  vibrate: true)
    }

    // What the phone actually ended up on, which is not always what the
    // dashboard asked for: a list that arrives mid stream is stored but not
    // switched to. Empty string rather than nil, so the dashboard can tell
    // "streaming to none of the managed profiles" from "the phone has not
    // answered yet", which is the absent response.
    func ctLiveAppliedStreamProfileId() -> String {
        stream.ctLiveProfileId ?? ""
    }

    private func activeCtLiveProfileName() -> String {
        stream.name
    }

    @discardableResult
    private func applyCtLiveStreamProfiles(profiles: [RemoteControlStreamProfile],
                                           switchStream: Bool) -> Bool
    {
        let usable = profiles.filter { profile in
            guard profile.isSupportedProtocol() else {
                logger.info("ct-live: Ignoring stream profile with unsupported protocol \(profile.proto)")
                return false
            }
            guard profile.toMoblinUrl() != nil else {
                logger.info("ct-live: Ignoring stream profile with no url")
                return false
            }
            return true
        }
        let changed = upsertCtLiveStreams(profiles: usable)
        removeCtLiveStreamsNotIn(profiles: usable)
        guard switchStream else {
            return false
        }
        guard let active = usable.first(where: { $0.isActive }),
              let target = database.streams.first(where: { $0.ctLiveProfileId == active.id })
        else {
            return false
        }
        guard target.id != stream.id else {
            // Already the current stream. The dashboard resends the whole list
            // on every reconnect and after every edit, so rebuilding the
            // encoder unconditionally here would blink the preview each time
            // the network flapped. Only a url that actually moved is worth it.
            guard changed.contains(active.id) else {
                return false
            }
            reloadStream()
            sceneUpdated(attachCamera: true, updateRemoteScene: false)
            // The ingest moved under the operator without the stream name
            // changing, which is exactly the case worth announcing.
            return true
        }
        // Which target the phone is pushing to is the one thing an operator or
        // a director will want to reconstruct afterwards, and the stream name
        // alone does not identify the dashboard profile.
        logger.info("ct-live: Switching stream target to profile \(active.id)")
        _ = stopStream()
        stopRecording()
        setCurrentStream(stream: target)
        currentStreamId = target.id
        reloadStream()
        sceneUpdated(attachCamera: true, updateRemoteScene: false)
        return true
    }

    // Returns the profiles whose url is not what the app already had, which is
    // the only reason to touch a running encoder.
    private func upsertCtLiveStreams(profiles: [RemoteControlStreamProfile]) -> Set<String> {
        var changed: Set<String> = []
        for profile in profiles {
            guard let url = profile.toMoblinUrl() else {
                continue
            }
            if let existing = database.streams.first(where: { $0.ctLiveProfileId == profile.id }) {
                existing.name = profile.name
                if existing.url != url {
                    existing.url = url
                    changed.insert(profile.id)
                }
            } else {
                changed.insert(profile.id)
                let new = SettingsStream(name: profile.name)
                new.ctLiveProfileId = profile.id
                new.url = url
                // Encoder settings are the operator's, not the dashboard's.
                // Inheriting them from the stream in use means a remotely
                // created target films the same way as the one it replaces.
                new.resolution = stream.resolution
                new.fps = stream.fps
                new.bitrate = stream.bitrate
                new.codec = stream.codec
                new.audioBitrate = stream.audioBitrate
                new.adaptiveBitrate = stream.adaptiveBitrate
                new.portrait = stream.portrait
                database.streams.append(new)
            }
        }
        return changed
    }

    private func removeCtLiveStreamsNotIn(profiles: [RemoteControlStreamProfile]) {
        let keep = Set(profiles.map(\.id))
        database.streams.removeAll { candidate in
            guard let profileId = candidate.ctLiveProfileId, !keep.contains(profileId) else {
                return false
            }
            // Deleting the stream that is currently going out would leave the
            // app streaming to something it no longer has settings for.
            guard candidate.id != stream.id else {
                logger.info("ct-live: Keeping removed profile, it is the current stream")
                return false
            }
            return true
        }
    }
}
