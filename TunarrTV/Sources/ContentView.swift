import SwiftUI
#if os(iOS)
import UIKit
#endif

struct ContentView: View {
    @EnvironmentObject var state: AppState
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSize
    private let isPad = UIDevice.current.userInterfaceIdiom == .pad
    #endif

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            #if os(tvOS)
            tvBody
            #else
            // iPad (regular width) gets the two-pane layout; iPhone and iPad
            // slide-over (compact) keep the stacked phone layout.
            if isPad, hSize == .regular {
                padBody
            } else {
                phoneBody
            }
            #endif
        }
        .overlay(alignment: .top) {
            if !state.isServerReachable {
                OfflineBanner()
                    .padding(.top, 18)
            }
        }
        .overlay(alignment: .topTrailing) {
            // The badge marks demo mode in normal use; `--hide-demo-badge`
            // suppresses it for clean App Store / README screenshots.
            if state.isDemoMode, !CommandLine.arguments.contains("--hide-demo-badge") {
                DemoBadge()
                    .padding(.top, 18)
                    .padding(.trailing, 24)
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
                    // Focusable so up-navigation from the channel column has
                    // somewhere to land; select goes fullscreen.
                    Button {
                        if state.tunedChannel != nil { state.isFullscreen = true }
                    } label: {
                        MiniPlayerPreview()
                    }
                    .buttonStyle(RetroCellButtonStyle())
                    .frame(width: 660, height: 371)
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
                if state.isSyntheticTuned {
                    SyntheticChannelView(compact: true, scale: 0.85)
                } else {
                    PlayerLayerView(player: state.player)
                    if state.isBuffering, let channel = state.tunedChannel {
                        TuningIndicator(channel: channel)
                    } else if let trouble = state.streamTrouble, let channel = state.tunedChannel {
                        StreamTroubleIndicator(channel: channel, trouble: trouble)
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

    // MARK: - iPad

    /// Two-pane layout for the roomier iPad screen: a large video preview and
    /// the program info side by side up top, the full EPG grid below — the
    /// same shape as the Apple TV guide, driven by touch.
    private var padBody: some View {
        GeometryReader { geo in
            let topHeight = geo.size.height * 0.42
            let guideScale = max(0.62, min(0.92, geo.size.width / 1500))
            VStack(spacing: 18) {
                HStack(alignment: .top, spacing: 24) {
                    ZStack {
                        if state.isSyntheticTuned {
                            SyntheticChannelView(compact: true, scale: 0.85)
                        } else {
                            PlayerLayerView(player: state.player)
                            if state.isBuffering, let channel = state.tunedChannel {
                                TuningIndicator(channel: channel)
                            } else if let trouble = state.streamTrouble, let channel = state.tunedChannel {
                                StreamTroubleIndicator(channel: channel, trouble: trouble)
                            }
                        }
                    }
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .overlay(Rectangle().stroke(Color(white: 0.25), lineWidth: 1))
                    .onTapGesture {
                        if state.tunedChannel != nil { state.isFullscreen = true }
                    }

                    InfoPanelView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(height: topHeight)

                GuideView(scale: guideScale)
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
        }
        .fullScreenCover(isPresented: $state.isFullscreen) {
            FullscreenPlayerIOS()
                .environmentObject(state)
        }
    }
    #endif
}

#if os(tvOS)
/// The guide screen's live preview box. Focus shows the standard white
/// ring plus a fullscreen glyph so it reads as "select to go fullscreen".
struct MiniPlayerPreview: View {
    @EnvironmentObject var state: AppState
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        ZStack {
            if state.isSyntheticTuned {
                SyntheticChannelView(compact: true)
            } else {
                PlayerLayerView(player: state.player)
                if state.isBuffering, let channel = state.tunedChannel {
                    TuningIndicator(channel: channel)
                } else if let trouble = state.streamTrouble, let channel = state.tunedChannel {
                    StreamTroubleIndicator(channel: channel, trouble: trouble)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .overlay(alignment: .bottomTrailing) {
            if isFocused {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white)
                    .padding(12)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(8)
                    .padding(14)
            }
        }
        .overlay(
            Rectangle()
                .stroke(isFocused ? Color.white : Color(white: 0.25),
                        lineWidth: isFocused ? 4 : 2)
        )
    }
}
#endif

/// Yellow tag pinned top-right whenever demo mode is active, so sample
/// content is never mistaken for a live lineup.
struct DemoBadge: View {
    var body: some View {
        Text("DEMO")
            .font(Theme.mono(18))
            .foregroundColor(.black)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(red: 0.95, green: 0.78, blue: 0.12))
            .cornerRadius(6)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 2)
            .allowsHitTesting(false)
    }
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

/// Shown once tune retries exhaust: names the failure instead of leaving
/// dead air. "Server busy" (API up, stream won't start — overloaded or a
/// bad source file) reads very differently from "server unreachable".
struct StreamTroubleIndicator: View {
    let channel: Channel
    let trouble: AppState.StreamTrouble

    var body: some View {
        ZStack {
            TVStaticView()
            VStack(spacing: 10) {
                Text(trouble == .busy ? "SERVER BUSY" : "NO SIGNAL")
                    .font(Theme.mono(24))
                    .foregroundColor(Theme.accent)
                Text(detail)
                    .font(Theme.mono(17, weight: .medium))
                    .foregroundColor(Theme.dimText)
                    .multilineTextAlignment(.center)
                Text(hint)
                    .font(Theme.mono(13))
                    .foregroundColor(Theme.dimText)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background(Color.black.opacity(0.65))
            .cornerRadius(8)
        }
    }

    private var detail: String {
        switch trouble {
        case .busy:
            return "CH \(channel.number) WON'T START — SERVER OVERLOADED OR BAD SOURCE"
        case .unreachable:
            return "CAN'T REACH THE TUNARR SERVER"
        }
    }

    private var hint: String {
        #if os(tvOS)
        return "PLAY/PAUSE TO RETRY · UP/DOWN FOR ANOTHER CHANNEL"
        #else
        return "PICK ANOTHER CHANNEL OR RETRY FROM THE GUIDE"
        #endif
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
