import SwiftUI

let settingsHalfWidth = 350.0

struct SettingsView: View {
    @EnvironmentObject var model: Model
    @ObservedObject var database: Database

    var body: some View {
        Form {
            if model.isLive {
                InfoBannerView(text: "Settings that would stop the stream are disabled when live.")
            }
            Section {
                NavigationLink {
                    StreamsSettingsView(createStreamWizard: model.createStreamWizard, database: database)
                } label: {
                    Label("Streams", systemImage: "dot.radiowaves.left.and.right")
                }
                NavigationLink {
                    RtmpServerStandaloneSettingsView(rtmpServer: database.rtmpServer)
                } label: {
                    Label("RTMP server", systemImage: "antenna.radiowaves.left.and.right")
                }
                NavigationLink {
                    AtemDevicesSettingsView(database: database, atemDevices: database.atemDevices)
                } label: {
                    Label("ATEM switchers", systemImage: "slider.horizontal.below.rectangle")
                }
                NavigationLink {
                    ScenesSettingsView(database: database)
                } label: {
                    Label("Scenes", systemImage: "photo.on.rectangle")
                }
                NavigationLink {
                    DisplaySettingsView(database: database)
                } label: {
                    Label("Display", systemImage: "rectangle.inset.topright.fill")
                }
                NavigationLink {
                    CameraSettingsView(database: database, stream: model.stream, color: database.color)
                } label: {
                    Label("Camera", systemImage: "camera")
                }
                if database.showAllSettings {
                    NavigationLink {
                        AudioSettingsView(database: database,
                                          stream: model.stream,
                                          mic: model.mic,
                                          debug: database.debug,
                                          audio: database.audio)
                    } label: {
                        Label("Audio", systemImage: "waveform")
                    }
                }
                // CTLive drives the location feed on a managed device, and the
                // settings here would fight it.
                if model.ctLiveIsManualSetupEnabled() {
                    NavigationLink {
                        LocationSettingsView(
                            database: database,
                            location: database.location,
                            stream: $model.stream
                        )
                    } label: {
                        Label("Location", systemImage: "location")
                    }
                }
                NavigationLink {
                    CtLiveSettingsView(model: model, ctLive: database.ctLive, tracker: model.ctLive)
                } label: {
                    Label("CTLive", systemImage: "flag.checkered")
                }
            }
            Section {
                if database.showAllSettings {
                    NavigationLink {
                        IngestsSettingsView(model: model, database: database)
                    } label: {
                        Label("Ingests", systemImage: "server.rack")
                    }
                }
                NavigationLink {
                    MoblinkSettingsView(status: model.statusOther, streamer: database.moblink.streamer)
                } label: {
                    Label("Moblink", systemImage: "app.connected.to.app.below.fill")
                }
                if database.showAllSettings {
                    NavigationLink {
                        MediaPlayersSettingsView(mediaPlayers: database.mediaPlayers)
                    } label: {
                        Label("Media players", systemImage: "play.rectangle.on.rectangle")
                    }
                }
            }
            if database.showAllSettings {
                Section {
                    NavigationLink {
                        GimbalSettingsView(model: model, gimbal: database.gimbal)
                    } label: {
                        Label("Gimbal", systemImage: "iphone.dock.motorized.viewfinder")
                    }
                    NavigationLink {
                        SelfieStickSettingsView(model: model, selfieStick: database.selfieStick)
                    } label: {
                        Label("Selfie stick", systemImage: "line.diagonal")
                    }
                    // Chat, macros, talkback, game controllers, keyboard and
                    // Moblin's own remote control are hidden along with the
                    // gadget integrations. The director drives this phone from
                    // the CTLive dashboard, which is configured under
                    // Settings -> CTLive, not here, so this screen was only a
                    // way to break the connection by accident.
                }
                Section {
                    NavigationLink {
                        DjiDevicesSettingsView(djiDevices: database.djiDevices)
                    } label: {
                        Label("DJI devices", systemImage: "appletvremote.gen1")
                    }
                    NavigationLink {
                        GoProSettingsView()
                    } label: {
                        Label("GoPro", systemImage: "appletvremote.gen1")
                    }
                    // Cat printers, Tesla, workout devices and Black Shark
                    // coolers are hidden. None of them have a place in a race
                    // broadcast, and the settings list is what an operator has
                    // to get through while holding a camera. The screens and
                    // their model code are left in place, only the way in is
                    // gone, so a rebase onto upstream stays cheap.
                }
            }
            Section {
                NavigationLink {
                    RecordingsSettingsView(model: model)
                } label: {
                    Label("Recordings", systemImage: "photo.on.rectangle.angled")
                }
                if database.showAllSettings {
                    NavigationLink {
                        StreamingHistorySettingsView(model: model)
                    } label: {
                        Label("Streaming history", systemImage: "text.book.closed")
                    }
                }
            }
            if database.showAllSettings, isPhone(), model.ctLiveIsManualSetupEnabled() {
                Section {
                    NavigationLink {
                        WatchSettingsView(watch: database.watch)
                    } label: {
                        Label("Apple Watch", systemImage: "applewatch")
                    }
                }
            }
            Section {
                NavigationLink {
                    HelpAndSupportSettingsView()
                } label: {
                    Label("Help and support", systemImage: "questionmark.circle")
                }
                if database.showAllSettings {
                    NavigationLink {
                        AboutSettingsView()
                    } label: {
                        Label("About", systemImage: "info.circle")
                    }
                    if model.ctLiveIsManualSetupEnabled() {
                        NavigationLink {
                            DebugSettingsView(debug: database.debug)
                        } label: {
                            Label("Debug", systemImage: "ladybug")
                        }
                    }
                }
            }
            if database.showAllSettings {
                Section {
                    NavigationLink {
                        ImportExportSettingsView(model: model)
                    } label: {
                        Label("Import and export settings", systemImage: "gearshape")
                    }
                    if model.ctLiveIsManualSetupEnabled() {
                        NavigationLink {
                            DeepLinkCreatorSettingsView(deepLinkCreator: database.deepLinkCreator)
                        } label: {
                            Label("Deep link creator", systemImage: "link.badge.plus")
                        }
                    }
                }
            }
            Section {
                Toggle("Show all settings", isOn: $database.showAllSettings)
            }
            Section {
                ResetSettingsView()
            }
        }
        .navigationTitle("Settings")
    }
}
