import Foundation
@testable import Moblin
import Testing

private func makeProfile(proto: String, url: String, streamKey: String) -> RemoteControlStreamProfile {
    RemoteControlStreamProfile(id: "p1",
                               name: "Profile",
                               proto: proto,
                               url: url,
                               streamKey: streamKey,
                               isActive: true)
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
