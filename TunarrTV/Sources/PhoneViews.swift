#if os(iOS)
import SwiftUI

/// Condensed program info shown between the player and the guide on iOS.
struct CompactInfoBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let entry = state.displayedEntry,
               let channel = state.channel(withId: entry.channelId) {
                HStack {
                    Text("\(channel.number)  \(channel.name.uppercased())")
                        .font(Theme.mono(12, weight: .medium))
                        .foregroundColor(Theme.dimText)
                    if let tuned = state.tunedChannel, tuned.id == channel.id {
                        Text("● ON NOW")
                            .font(Theme.mono(11, weight: .medium))
                            .foregroundColor(Theme.onAir)
                    }
                    Spacer()
                    Text(entry.isSynthetic
                        ? "ALL DAY"
                        : "\(Theme.timeFormatter.string(from: entry.start)) - \(Theme.timeFormatter.string(from: entry.stop))")
                        .font(Theme.mono(12, weight: .medium))
                        .foregroundColor(Theme.dimText)
                }
                HStack(spacing: 8) {
                    Text(entry.title)
                        .font(Theme.mono(16))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        state.showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Theme.dimText)
                    }
                }
                if !entry.isSynthetic, entry.airs(at: state.now) {
                    let total = entry.stop.timeIntervalSince(entry.start)
                    let fraction = total > 0
                        ? min(max(state.now.timeIntervalSince(entry.start) / total, 0), 1)
                        : 0
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(white: 0.25))
                            Capsule().fill(Theme.onAir)
                                .frame(width: geo.size.width * fraction)
                        }
                    }
                    .frame(height: 4)
                }
            } else {
                HStack {
                    Text(state.loadError ?? "LOADING...")
                        .font(Theme.mono(14))
                        .foregroundColor(Theme.dimText)
                    Spacer()
                    Button {
                        state.showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(Theme.dimText)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
    }
}

/// Fullscreen playback on iOS: tap to show/hide controls, chevrons to zap.
struct FullscreenPlayerIOS: View {
    @EnvironmentObject var state: AppState
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if state.isSyntheticTuned {
                SyntheticChannelView(scale: 0.55)
                    .ignoresSafeArea()
            } else {
                PlayerLayerView(player: state.player)
                    .ignoresSafeArea()
                if state.isBuffering, let channel = state.tunedChannel {
                    TuningIndicator(channel: channel)
                        .ignoresSafeArea()
                } else if let trouble = state.streamTrouble, let channel = state.tunedChannel {
                    StreamTroubleIndicator(channel: channel, trouble: trouble)
                        .ignoresSafeArea()
                }
            }

            // Tap layer sits under the controls so buttons always win taps.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation { showControls.toggle() }
                    if showControls { scheduleHide() }
                }
                // Swipe up/down anywhere to zap channels.
                .gesture(
                    DragGesture(minimumDistance: 40)
                        .onEnded { value in
                            let dy = value.translation.height
                            guard abs(dy) > 60, abs(dy) > abs(value.translation.width) else { return }
                            if dy < 0 {
                                state.channelUp()
                            } else {
                                state.channelDown()
                            }
                            withAnimation { showControls = true }
                            scheduleHide()
                        }
                )

            // Content stays within the safe area (rounded corners, home
            // indicator would clip it); the bar's background still bleeds
            // to the physical edges.
            if state.tickerEnabled {
                VStack {
                    Spacer()
                    ChannelTickerView(compact: true)
                }
            }

            if showControls {
                controls
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { scheduleHide() }
    }

    private var controls: some View {
        VStack {
            HStack(alignment: .top) {
                if let channel = state.tunedChannel {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(channel.number)  \(channel.name.uppercased())")
                            .font(Theme.mono(15))
                            .foregroundColor(.white)
                        if let entry = state.nowPlaying(on: channel) {
                            Text(entry.title.uppercased())
                                .font(Theme.mono(12, weight: .medium))
                                .foregroundColor(Theme.dimText)
                                .lineLimit(1)
                        }
                    }
                    .padding(10)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(6)
                }
                Spacer()
                // AirPlay: hand the stream off to an Apple TV / AirPlay 2 receiver.
                AirPlayButton()
                    .frame(width: 24, height: 24)
                    .frame(width: 48, height: 48)
                    .background(Color.black.opacity(0.6))
                    .clipShape(Circle())
                Button {
                    state.tickerEnabled.toggle()
                    if state.tickerEnabled {
                        Task { await state.refreshWeather() }
                    }
                    scheduleHide()
                } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(state.tickerEnabled ? Theme.onAir : .white)
                        .frame(width: 48, height: 48)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                Button {
                    state.isFullscreen = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 48)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding()

            Spacer()

            HStack {
                Spacer()
                VStack(spacing: 14) {
                    zapButton("chevron.up") { state.channelUp(); scheduleHide() }
                    zapButton("chevron.down") { state.channelDown(); scheduleHide() }
                }
                .padding(.trailing, 16)
            }
            .padding(.bottom, 30)
        }
    }

    private func zapButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 48, height: 48)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                withAnimation { showControls = false }
            }
        }
    }
}
#endif
