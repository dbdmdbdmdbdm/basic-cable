import SwiftUI
import AVFoundation

@main
struct TunarrTVApp: App {
    @StateObject private var state = AppState()

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
        }
    }
}
