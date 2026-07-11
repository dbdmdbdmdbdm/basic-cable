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
    @State private var bannerVisible = true
    @State private var bannerTask: Task<Void, Never>?

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
                }
            }

            if bannerVisible, let channel = state.tunedChannel {
                banner(for: channel)
                    .padding(48)
                    .transition(.opacity)
            }
        }
        .focusable(true)
        .focused($focused)
        // Select press returns to the guide (Menu via onExitCommand does too).
        .onTapGesture { state.isFullscreen = false }
        .onPlayPauseCommand { state.togglePause() }
        .onMoveCommand { direction in
            switch direction {
            case .up:
                state.channelUp()
                showBanner()
            case .down:
                state.channelDown()
                showBanner()
            default:
                break
            }
        }
        .onExitCommand { state.isFullscreen = false }
        .onAppear {
            focused = true
            showBanner()
        }
        .onDisappear { bannerTask?.cancel() }
        // Channel changes rebuild parts of the tree and can drop focus,
        // which would strand the Menu/exit command — re-assert it.
        .onChange(of: state.tunedChannel) { _, _ in
            focused = true
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused && state.isFullscreen {
                focused = true
            }
        }
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
