import AVFoundation
import CoreText
import SwiftUI

@main
struct celestiApp: App {
    @StateObject private var appModel = CelestiAppModel()

    init() {
        let fonts = [
            "encode_sans_regular",
            "encode_sans_semibold",
            "libre_franklin_medium",
            "libre_franklin_regular",
        ]
        for name in fonts {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else {
                print("Font not found: \(name).ttf")
                continue
            }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback)
        try? session.setActive(true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .preferredColorScheme(.dark)
        }
    }
}
