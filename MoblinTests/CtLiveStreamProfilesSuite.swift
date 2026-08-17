import Foundation
@testable import Moblin
import Testing

private func makeProfile(proto: String,
                         url: String,
                         streamKey: String,
                         videoCodec: String? = nil) -> RemoteControlStreamProfile
{
    RemoteControlStreamProfile(id: "p1",
                               name: "Profile",
                               proto: proto,
                               url: url,
                               streamKey: streamKey,
                               isActive: true,
                               videoCodec: videoCodec)
}

struct CtLiveStreamProfilesSuite {
    @Test
    func rtmpUrlGetsTheKeyAppended() {
        let profile = makeProfile(proto: "rtmp", url: "rtmp://a.rtmp.youtube.com/live2", streamKey: "abc-123")
        #expect(profile.toMoblinUrl() == "rtmp://a.rtmp.youtube.com/live2/abc-123")
    }

    @Test
    func rtmpUrlDoesNotDoubleTheSlash() {
        let profile = makeProfile(proto: "rtmps", url: "rtmps://ingest.example.com/live/", streamKey: "key")
        #expect(profile.toMoblinUrl() == "rtmps://ingest.example.com/live/key")
    }

    @Test
    func emptyKeyLeavesTheUrlAlone() {
        let profile = makeProfile(proto: "srt", url: "srt://relay.ctyeh.com:8890", streamKey: "")
        #expect(profile.toMoblinUrl() == "srt://relay.ctyeh.com:8890")
    }

    @Test
    func srtKeyBecomesStreamId() {
        let profile = makeProfile(proto: "srt", url: "srt://relay.ctyeh.com:8890", streamKey: "race1")
        #expect(profile.toMoblinUrl() == "srt://relay.ctyeh.com:8890?streamid=race1")
    }

    @Test
    func srtKeyIsAppendedToAnExistingQuery() {
        let profile = makeProfile(
            proto: "srt",
            url: "srt://relay.ctyeh.com:8890?latency=2000",
            streamKey: "r1"
        )
        #expect(profile.toMoblinUrl() == "srt://relay.ctyeh.com:8890?latency=2000&streamid=r1")
    }

    @Test
    func aStreamIdAlreadyInTheUrlWins() {
        let profile = makeProfile(
            proto: "srt",
            url: "srt://relay.ctyeh.com:8890?streamid=inUrl",
            streamKey: "r1"
        )
        #expect(profile.toMoblinUrl() == "srt://relay.ctyeh.com:8890?streamid=inUrl")
    }

    // Moblin tells srtla from srt by the url scheme alone, and carries the
    // streamid in the query exactly as it does for srt. Bonding then turns
    // itself on. So an srtla profile needs no special handling here, which is
    // only true as long as the scheme survives assembly untouched.
    @Test
    func srtlaKeepsItsSchemeAndTakesAStreamId() {
        let profile = makeProfile(
            proto: "srtla",
            url: "srtla://live.ctyeh.com:5000",
            streamKey: "publish:bike1"
        )
        #expect(profile.isSupportedProtocol())
        #expect(profile.toMoblinUrl() == "srtla://live.ctyeh.com:5000?streamid=publish:bike1")
    }

    // The stream key the dashboard sends for a camera contains a colon. It is
    // legal in a query value and must not be escaped or split.
    @Test
    func aColonInTheStreamKeySurvives() throws {
        let profile = makeProfile(proto: "srt", url: "srt://live.ctyeh.com:8890", streamKey: "publish:bike1")
        let url = try #require(profile.toMoblinUrl())
        #expect(url.hasSuffix("?streamid=publish:bike1"))
        // The same parse Moblin uses to lift the streamid into the SRT handshake.
        #expect(URL(string: url)?.dictionaryFromQuery()["streamid"] == "publish:bike1")
    }

    // The dashboard switches the codec because its own preview cannot play
    // H.265 outside Safari. An absent value must leave the encoder alone
    // rather than quietly resetting it to a default.
    @Test
    func theCodecIsOnlyOverriddenWhenAskedFor() {
        #expect(makeProfile(proto: "srt", url: "u", streamKey: "").toCodec() == nil)
        #expect(makeProfile(proto: "srt", url: "u", streamKey: "", videoCodec: "h264").toCodec() == .h264avc)
        #expect(makeProfile(proto: "srt", url: "u", streamKey: "", videoCodec: "H.264").toCodec() == .h264avc)
        #expect(makeProfile(proto: "srt", url: "u", streamKey: "", videoCodec: "avc").toCodec() == .h264avc)
        #expect(makeProfile(proto: "srt", url: "u", streamKey: "", videoCodec: "h265").toCodec() == .h265hevc)
        #expect(makeProfile(proto: "srt", url: "u", streamKey: "", videoCodec: "HEVC").toCodec() == .h265hevc)
        // Anything unrecognised is left alone rather than guessed at.
        #expect(makeProfile(proto: "srt", url: "u", streamKey: "", videoCodec: "av1").toCodec() == nil)
    }

    // A dashboard that predates the field must keep decoding.
    @Test
    func aProfileWithoutTheCodecFieldStillDecodes() throws {
        let json = """
        {"setStreamProfiles":{"profiles":[\
        {"id":"uuid-1","name":"Main","protocol":"srtla","url":"srtla://a:5000",\
        "streamKey":"publish:bike1","isActive":true}]}}
        """
        let request = try JSONDecoder().decode(RemoteControlRequest.self, from: Data(json.utf8))
        guard case let .setStreamProfiles(profiles: profiles) = request else {
            Issue.record("Decoded to the wrong case")
            return
        }
        #expect(profiles[0].videoCodec == nil)
        #expect(profiles[0].toCodec() == nil)
    }

    // Instant unlock from the dashboard. The pairing check carries the same
    // flag, so this only has to decode; getting it wrong would mean an
    // administrator flips the switch and nothing happens until a relaunch.
    @Test
    func setManualSetupEnabledDecodes() throws {
        let json = #"{"setManualSetupEnabled":{"enabled":true}}"#
        let request = try JSONDecoder().decode(RemoteControlRequest.self, from: Data(json.utf8))
        guard case let .setManualSetupEnabled(enabled: enabled) = request else {
            Issue.record("Decoded to the wrong case")
            return
        }
        #expect(enabled)
    }

    // A row of dots reads as empty, and that is how a delivered target was
    // once misread as "CTLive never sent anything". The host has to stay
    // legible; only the credential is worth hiding.
    @Test
    func onlyTheStreamIdIsHiddenForSrtla() {
        let stream = SettingsStream(name: "Main")
        stream.ctLiveProfileId = "p1"
        stream.url = "srtla://live.ctyeh.com:5000?streamid=publish:bike1"
        let shown = stream.redactedUrl()
        #expect(shown.hasPrefix("srtla://live.ctyeh.com:5000?streamid="))
        #expect(!shown.contains("bike1"))
        #expect(shown.contains("•"))
    }

    @Test
    func onlyTheKeyIsHiddenForRtmp() {
        let stream = SettingsStream(name: "Main")
        stream.ctLiveProfileId = "p1"
        stream.url = "rtmp://a.rtmp.youtube.com/live2/secret-key"
        let shown = stream.redactedUrl()
        #expect(shown.hasPrefix("rtmp://a.rtmp.youtube.com/live2/"))
        #expect(!shown.contains("secret-key"))
    }

    // Main and backup must be distinguishable at a glance, which was the whole
    // point of not masking the host.
    @Test
    func mainAndBackupLookDifferent() {
        let main = SettingsStream(name: "Main")
        main.url = "srtla://live.ctyeh.com:5000?streamid=publish:bike1"
        let backup = SettingsStream(name: "Backup")
        backup.url = "srtla://live2.ctyeh.com:5000?streamid=publish:bike1"
        #expect(main.redactedUrl() != backup.redactedUrl())
        #expect(main.redactedUrl().contains("live.ctyeh.com"))
        #expect(backup.redactedUrl().contains("live2.ctyeh.com"))
    }

    @Test
    func aProfileWithoutAUrlIsUnusable() {
        let profile = makeProfile(proto: "rtmp", url: "   ", streamKey: "key")
        #expect(profile.toMoblinUrl() == nil)
    }

    @Test
    func onlyTheAgreedProtocolsAreAccepted() {
        #expect(makeProfile(proto: "rtmp", url: "u", streamKey: "").isSupportedProtocol())
        #expect(makeProfile(proto: "RTMPS", url: "u", streamKey: "").isSupportedProtocol())
        #expect(makeProfile(proto: "srt", url: "u", streamKey: "").isSupportedProtocol())
        #expect(!makeProfile(proto: "whip", url: "u", streamKey: "").isSupportedProtocol())
    }

    // The wire name is protocol, which Swift cannot use as a property name. A
    // rename would silently stop decoding every profile the dashboard sends.
    @Test
    func theDashboardRequestDecodes() throws {
        let json = """
        {"setStreamProfiles":{"profiles":[\
        {"id":"uuid-1","name":"YouTube","protocol":"rtmp","url":"rtmp://a/live2",\
        "streamKey":"k","isActive":true}]}}
        """
        let request = try JSONDecoder().decode(RemoteControlRequest.self, from: Data(json.utf8))
        guard case let .setStreamProfiles(profiles: profiles) = request else {
            Issue.record("Decoded to the wrong case")
            return
        }
        #expect(profiles.count == 1)
        #expect(profiles[0].id == "uuid-1")
        #expect(profiles[0].proto == "rtmp")
        #expect(profiles[0].isActive)
    }

    @Test
    func setActiveStreamProfileDecodes() throws {
        let json = #"{"setActiveStreamProfile":{"id":"uuid-2"}}"#
        let request = try JSONDecoder().decode(RemoteControlRequest.self, from: Data(json.utf8))
        guard case let .setActiveStreamProfile(id: id) = request else {
            Issue.record("Decoded to the wrong case")
            return
        }
        #expect(id == "uuid-2")
    }

    // The dashboard wants to show which target the phone actually ended up on.
    @Test
    func theResponseCarriesTheAppliedId() throws {
        let message = RemoteControlMessageToAssistant.response(id: 3,
                                                               result: .ok,
                                                               data: .setStreamProfiles(appliedId: "uuid-1"))
        let json = try message.toJson()
        #expect(json.contains("\"appliedId\":\"uuid-1\""))
    }

    // The whole point of keeping profiles in the keychain is that the settings
    // file never sees the stream key. The url carries it, so a managed stream
    // must persist without one. If this ever regresses it does so silently.
    @Test
    func aManagedStreamDoesNotPersistItsUrl() throws {
        let stream = SettingsStream(name: "CTLive target")
        stream.ctLiveProfileId = "profile-1"
        stream.url = "rtmp://ingest.example.com/live2/secret-key"
        let encoded = try JSONEncoder().encode(stream)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("secret-key"))
        let decoded = try JSONDecoder().decode(SettingsStream.self, from: encoded)
        #expect(decoded.ctLiveProfileId == "profile-1")
        #expect(decoded.isCtLiveManaged())
    }

    // An ordinary stream must keep behaving exactly as before.
    @Test
    func anUnmanagedStreamStillPersistsItsUrl() throws {
        let stream = SettingsStream(name: "My stream")
        stream.url = "rtmp://ingest.example.com/live2/my-key"
        let encoded = try JSONEncoder().encode(stream)
        let decoded = try JSONDecoder().decode(SettingsStream.self, from: encoded)
        #expect(decoded.url == "rtmp://ingest.example.com/live2/my-key")
        #expect(decoded.ctLiveProfileId == nil)
        #expect(!decoded.isCtLiveManaged())
    }

    // Duplicating a managed stream has to hand the operator a normal local
    // stream, otherwise the next profile sync deletes their copy.
    @Test
    func duplicatingAManagedStreamDropsTheMarker() {
        let stream = SettingsStream(name: "CTLive target")
        stream.ctLiveProfileId = "profile-1"
        stream.url = "rtmp://ingest.example.com/live2/key"
        let copy = stream.clone()
        #expect(copy.ctLiveProfileId == nil)
        #expect(!copy.isCtLiveManaged())
        #expect(copy.url == "rtmp://ingest.example.com/live2/key")
    }

    // A stream key must never reach a log, including when a message fails to
    // decode and gets logged verbatim.
    @Test
    func streamKeysAreRedactedFromLogs() {
        let json = #"{"setStreamProfiles":{"profiles":[{"streamKey":"secret","url":"rtmp://a/live2/secret"}]}}"#
        let redacted = redactSensitiveJsonValues(json)
        #expect(!redacted.contains("secret"))
    }
}
