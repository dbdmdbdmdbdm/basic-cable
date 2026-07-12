import SwiftUI
import AVFoundation

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
        if uiView.playerLayer.videoGravity != gravity {
            uiView.playerLayer.videoGravity = gravity
        }
    }
}

#if os(tvOS)
struct FullscreenPlayerView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focused: Bool
    @FocusState private var panelFocused: Bool
    @State private var bannerVisible = true
    @State private var bannerTask: Task<Void, Never>?
    @State private var showQuickPanel = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if state.isSyntheticTuned {
                SyntheticChannelView()
                    .ignoresSafeArea()
            } else {
                PlayerLayerView(player: state.player)
                    .ignoresSafeArea()

                if state.isBuffering, let channel = state.tunedChannel {
                    TuningIndicator(channel: channel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                } else if let trouble = state.streamTrouble, let channel = state.tunedChannel {
                    StreamTroubleIndicator(channel: channel, trouble: trouble)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .ignoresSafeArea()
                }
            }

            if state.tickerEnabled {
                VStack {
                    Spacer()
                    ChannelTickerView()
                }
                .ignoresSafeArea()
            }

            if bannerVisible, let channel = state.tunedChannel {
                banner(for: channel)
                    .padding(48)
                    .transition(.opacity)
            }

            if showQuickPanel, let channel = state.tunedChannel {
                quickPanel(for: channel)
            }
        }
        .focusable(true)
        .focused($focused)
        // Select press returns to the guide (Menu via onExitCommand does too);
        // press-and-hold select opens quick options instead.
        .onTapGesture {
            guard !showQuickPanel else { return }
            if state.isCamerasTuned {
                // Select toggles the camera spotlight rather than exiting.
                if state.cameraSpotlight == nil { state.cameraSpotlightMove(1) }
                else { state.cameraSpotlightExit() }
            } else {
                state.isFullscreen = false
            }
        }
        .onLongPressGesture(minimumDuration: 0.6) {
            guard !showQuickPanel else { return }
            showQuickPanel = true
            panelFocused = true
        }
        .onPlayPauseCommand { state.togglePause() }
        .onMoveCommand { direction in
            // On the cameras channel, left/right walks the spotlight through
            // the bank; up/down still zaps channels.
            if state.isCamerasTuned {
                switch direction {
                case .up: state.channelUp(); showBanner()
                case .down: state.channelDown(); showBanner()
                case .left: state.cameraSpotlightMove(-1)
                case .right: state.cameraSpotlightMove(1)
                @unknown default: break
                }
                return
            }
            switch direction {
            case .up:
                state.channelUp()
                showBanner()
            case .down:
                state.channelDown()
                showBanner()
            case .left, .right:
                // Quick options for the tuned channel (up/down keep zapping).
                showQuickPanel = true
                panelFocused = true
            @unknown default:
                break
            }
        }
        .onExitCommand {
            if showQuickPanel {
                closeQuickPanel()
            } else if state.isCamerasTuned, state.cameraSpotlight != nil {
                // Menu backs out of the spotlight to the camera grid first.
                state.cameraSpotlightExit()
            } else {
                state.isFullscreen = false
            }
        }
        .onAppear {
            focused = true
            showBanner()
        }
        .onDisappear { bannerTask?.cancel() }
        // Channel changes rebuild parts of the tree and can drop focus,
        // which would strand the Menu/exit command — re-assert it.
        .onChange(of: state.tunedChannel) { _, _ in
            if !showQuickPanel { focused = true }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && state.isFullscreen && !showQuickPanel {
                focused = true
            }
        }
    }

    // MARK: - Quick options panel

    private func quickPanel(for channel: Channel) -> some View {
        VStack {
            Spacer()
            VStack(alignment: .leading, spacing: 18) {
                Text("CH \(channel.number) · \(channel.name.uppercased())")
                    .font(Theme.mono(22))
                    .foregroundColor(Theme.dimText)
                Toggle(isOn: tickerBinding()) {
                    Text("BOTTOM TICKER (ALL CHANNELS)")
                        .font(Theme.mono(24, weight: .medium))
                }
                .focused($panelFocused)
                Text("HOLD SELECT ANYTIME FOR THIS PANEL · SET PLAYERS IN SETTINGS · MENU TO CLOSE")
                    .font(Theme.mono(15, weight: .medium))
                    .foregroundColor(Theme.dimText)
            }
            .padding(36)
            .frame(maxWidth: 900)
            .background(Color.black.opacity(0.92))
            .cornerRadius(12)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.3), lineWidth: 2))
            .padding(.bottom, 120)
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    private func closeQuickPanel() {
        showQuickPanel = false
        focused = true
    }

    private func tickerBinding() -> Binding<Bool> {
        Binding(
            get: { state.tickerEnabled },
            set: { on in
                state.tickerEnabled = on
                if on { Task { await state.refreshWeather() } }
            }
        )
    }

    private func banner(for channel: Channel) -> some View {
        HStack(spacing: 16) {
            Text("\(channel.number)")
                .font(Theme.mono(40))
                .foregroundColor(Theme.onAir)
            VStack(alignment: .leading, spacing: 4) {
                Text(channel.name.uppercased())
                    .font(Theme.mono(28))
                    .foregroundColor(.white)
                if let entry = state.nowPlaying(on: channel) {
                    Text(entry.title.uppercased())
                        .font(Theme.mono(20, weight: .medium))
                        .foregroundColor(Theme.dimText)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .background(Color.black.opacity(0.75))
        .cornerRadius(8)
    }

    private func showBanner() {
        bannerTask?.cancel()
        withAnimation { bannerVisible = true }
        bannerTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                withAnimation { bannerVisible = false }
            }
        }
    }
}
#endif
