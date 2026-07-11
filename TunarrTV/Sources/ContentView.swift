import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            #if os(tvOS)
            tvBody
            #else
            phoneBody
            #endif
        }
        .overlay(alignment: .top) {
            if !state.isServerReachable {
                OfflineBanner()
                    .padding(.top, 18)
            }
        }
        .sheet(isPresented: $state.showSettings) {
            SettingsView()
        }
        .task {
            await state.bootstrap()
        }
    }

    // MARK: - tvOS

    #if os(tvOS)
    @ViewBuilder
    private var tvBody: some View {
        if state.isFullscreen {
            FullscreenPlayerView()
        } else {
            VStack(spacing: 26) {
                HStack(alignment: .top, spacing: 36) {
                    ZStack {
                        if state.isWeatherTuned {
                            WeatherSceneView(compact: true)
                        } else {
                            PlayerLayerView(player: state.player)
                            if state.isBuffering, let channel = state.tunedChannel {
                                TuningIndicator(channel: channel)
                            }
                        }
                    }
                    .frame(width: 660, height: 371)
                    .background(Color.black)
                    .overlay(
                        Rectangle()
                            .stroke(Color(white: 0.25), lineWidth: 2)
                    )
                    InfoPanelView()
                        .frame(height: 371)
                }
                GuideView()
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 12)
            // Fill the screen edge-to-edge; modern TVs don't overscan.
            .ignoresSafeArea()
            // Back/Menu from the guide returns to watching (exit the app
            // from fullscreen or via the Home button instead).
            .onExitCommand {
                if state.tunedChannel != nil { state.isFullscreen = true }
            }
            .onPlayPauseCommand {
                if state.tunedChannel != nil { state.isFullscreen = true }
            }
        }
    }
    #else

    // MARK: - iOS

    private var phoneBody: some View {
        VStack(spacing: 10) {
            ZStack {
                if state.isWeatherTuned {
                    WeatherSceneView(compact: true, scale: 0.85)
                } else {
                    PlayerLayerView(player: state.player)
                    if state.isBuffering, let channel = state.tunedChannel {
                        TuningIndicator(channel: channel)
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Color.black)
            .overlay(
                Rectangle()
                    .stroke(Color(white: 0.25), lineWidth: 1)
            )
            .onTapGesture {
                if state.tunedChannel != nil { state.isFullscreen = true }
            }

            CompactInfoBar()
            GuideView(scale: 0.55)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .fullScreenCover(isPresented: $state.isFullscreen) {
            FullscreenPlayerIOS()
                .environmentObject(state)
        }
    }
    #endif
}

/// Red pill shown at the top of every screen while Tunarr is unreachable.
struct OfflineBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 18, weight: .bold))
            Text("TUNARR UNREACHABLE — RETRYING...")
                .font(Theme.mono(18))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(Theme.accent)
        .cornerRadius(8)
        .shadow(color: .black.opacity(0.5), radius: 8, y: 2)
    }
}

struct TuningIndicator: View {
    let channel: Channel

    var body: some View {
        ZStack {
            TVStaticView()
            label
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .background(Color.black.opacity(0.65))
                .cornerRadius(8)
        }
    }

    private var label: some View {
        VStack(spacing: 10) {
            Text("TUNING")
                .font(Theme.mono(24))
                .foregroundColor(Theme.onAir)
            Text("CH \(channel.number)  \(channel.name.uppercased())")
                .font(Theme.mono(17, weight: .medium))
                .foregroundColor(Theme.dimText)
        }
    }
}
