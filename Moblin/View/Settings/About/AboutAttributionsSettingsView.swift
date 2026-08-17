import SwiftUI

private struct Attribution {
    let name: String
    let text: [String]
}

private let soundAttributions: [Attribution] = [
    Attribution(
        name: "Bad chili fart",
        text: [
            "Bad Chili Fart.wav by deleted_user_1391979",
            "-- https://freesound.org/s/94989/",
            "-- License: Creative Commons 0",
        ]
    ),
    Attribution(
        name: "Boing",
        text: [
            "Boing.wav by juskiddink",
            "-- https://freesound.org/s/140867/",
            "-- License: Attribution 4.0",
        ]
    ),
    Attribution(
        name: "Cash register",
        text: [
            "Cash Register by kiddpark",
            "-- https://freesound.org/s/201159/",
            "-- License: Attribution 4.0",
        ]
    ),
    Attribution(
        name: "Coin dropping",
        text: [
            "Coin dropping.wav by Jace",
            "-- https://freesound.org/s/17502/",
            "-- License: Creative Commons 0",
        ]
    ),
    Attribution(
        name: "Dingaling",
        text: [
            "dingaling by morrisjm",
            "-- https://freesound.org/s/268756/",
            "-- License: Attribution 4.0",
        ]
    ),
    Attribution(
        name: "Fart",
        text: [
            "FART.aif by Manicciola",
            "-- https://freesound.org/s/121783/",
            "-- License: Creative Commons 0",
        ]
    ),
    Attribution(
        name: "Fart 2",
        text: [
            "Fart sound.wav by aditwayer",
            "-- https://freesound.org/s/520671/",
            "-- License: Creative Commons 0",
        ]
    ),
    Attribution(
        name: "Level up",
        text: [
            "320655__rhodesmas__level-up-01.mp3 by shinephoenixstormcrow",
            "-- https://freesound.org/s/337049/",
            "-- License: Attribution 3.0",
        ]
    ),
    Attribution(
        name: "Notification",
        text: [
            "Message Notification 4 by AnthonyRox",
            "-- https://freesound.org/s/740423/",
            "-- License: Creative Commons 0",
        ]
    ),
    Attribution(
        name: "Notification 2",
        text: [
            "notification2-freesound.wav by Thoribass",
            "-- https://freesound.org/s/254819/",
            "-- License: Attribution 4.0",
        ]
    ),
    Attribution(
        name: "Nya",
        text: [
            "Nya.wav by Mike_bes",
            "-- https://freesound.org/s/336012/",
            "-- License: Creative Commons 0",
        ]
    ),
    Attribution(
        name: "Perfect fart",
        text: [
            "perfect-fart.mp3 by TV_LING",
            "-- https://freesound.org/s/523467/",
            "-- License: Creative Commons 0",
        ]
    ),
    Attribution(
        name: "SFX magic",
        text: [
            "SFX Magic by renatalmar",
            "-- https://freesound.org/s/264981/",
            "-- License: Creative Commons 0",
        ]
    ),
    Attribution(
        name: "Silence",
        text: [
            "C0000_silence5sec.mp3 by thanvannispen",
            "-- https://freesound.org/s/107061/",
            "-- License: Attribution 4.0",
        ]
    ),
    Attribution(
        name: "Whoosh",
        text: [
            "Whoosh by qubodup",
            "-- https://freesound.org/s/60013/",
            "-- License: Creative Commons 0",
        ]
    ),
]

private let imageAttributions: [Attribution] = [
    Attribution(
        name: "-100",
        text: [
            "Credit Richie Velasquez ",
            "https://www.deladeso.com/",
        ]
    ),
]

private struct AboutAttributionsSoundsSettingsView: View {
    var body: some View {
        ScrollView {
            HStack {
                LazyVStack(alignment: .leading) {
                    ForEach(soundAttributions, id: \.name) { attribution in
                        Text(attribution.name)
                            .font(.title2)
                            .padding(.top)
                        VStack(alignment: .leading) {
                            ForEach(attribution.text, id: \.self) { line in
                                Text(line)
                            }
                        }
                        .padding([.top, .leading], 5)
                    }
                    Spacer()
                }
                .padding()
                Spacer()
            }
        }
        .navigationTitle("Sounds")
    }
}

private struct AboutAttributionsImagesSettingsView: View {
    var body: some View {
        ScrollView {
            HStack {
                LazyVStack(alignment: .leading) {
                    ForEach(imageAttributions, id: \.name) { attribution in
                        Text(attribution.name)
                            .font(.title2)
                            .padding(.top)
                        VStack(alignment: .leading) {
                            ForEach(attribution.text, id: \.self) { line in
                                Text(line)
                            }
                        }
                        .padding([.top, .leading], 5)
                    }
                    Spacer()
                }
                .padding()
                Spacer()
            }
        }
        .navigationTitle("Images")
    }
}

// CTLiveGo is built on Moblin, whose licence requires the copyright and
// permission notice to travel with every copy of the software. Shipping the app
// without it anywhere a user can read is a licence breach, so this is not
// optional the way a credit line in About was. Verbatim from LICENSE, and not
// localised: a licence text that has been translated is no longer the licence.
private let softwareLicenses: [Attribution] = [
    Attribution(
        name: "Moblin",
        text: [
            "MIT License",
            "",
            "Copyright (c) 2023 Erik Moqvist",
            "",
            "Permission is hereby granted, free of charge, to any person obtaining a copy",
            "of this software and associated documentation files (the \"Software\"), to deal",
            "in the Software without restriction, including without limitation the rights",
            "to use, copy, modify, merge, publish, distribute, sublicense, and/or sell",
            "copies of the Software, and to permit persons to whom the Software is",
            "furnished to do so, subject to the following conditions:",
            "",
            "The above copyright notice and this permission notice shall be included in all",
            "copies or substantial portions of the Software.",
            "",
            "THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR",
            "IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,",
            "FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE",
            "AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER",
            "LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,",
            "OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE",
            "SOFTWARE.",
        ]
    ),
]

private struct AboutAttributionsSoftwareSettingsView: View {
    var body: some View {
        ScrollView {
            HStack {
                LazyVStack(alignment: .leading) {
                    ForEach(softwareLicenses, id: \.name) { attribution in
                        Text(attribution.name)
                            .font(.title2)
                            .padding(.top)
                        VStack(alignment: .leading) {
                            ForEach(Array(attribution.text.enumerated()), id: \.offset) { line in
                                Text(line.element)
                            }
                        }
                        .padding([.top, .leading], 5)
                    }
                    Spacer()
                }
                .padding()
                Spacer()
            }
        }
        .navigationTitle("Software")
    }
}

struct AboutAttributionsSettingsView: View {
    var body: some View {
        Form {
            NavigationLink {
                AboutAttributionsSoftwareSettingsView()
            } label: {
                Text("Software")
            }
            NavigationLink {
                AboutAttributionsSoundsSettingsView()
            } label: {
                Text("Sounds")
            }
            NavigationLink {
                AboutAttributionsImagesSettingsView()
            } label: {
                Text("Images")
            }
        }
        .navigationTitle("Attributions")
    }
}
