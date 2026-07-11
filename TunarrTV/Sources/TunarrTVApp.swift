import SwiftUI
import AVFoundation

@main
struct TunarrTVApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // Stop streaming (and reap our Tunarr session) when the app
            // leaves the foreground; rejoin fresh when it returns.
            switch phase {
            case .background:
                state.appDidEnterBackground()
            case .active:
                state.appDidBecomeActive()
            default:
                break
            }
        }
    }
}
