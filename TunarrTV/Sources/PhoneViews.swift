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
        GeometryReader { geo in
        ZStack {
            Color.black.ignoresSafeArea()

            if state.isSyntheticTuned {
                // The cameras channel handles taps on the tiles themselves
                // (open a camera / switch / back to the grid), so the swipe
                // rides on the scene and there's no tap layer over it. Other
                // synthetic channels use the shared tap layer below.
                if state.isCamerasTuned {
                    SyntheticChannelView(scale: 0.55)
                        .ignoresSafeArea()
                        .simultaneousGesture(cameraSwipeGesture)
                } else {
                    SyntheticChannelView(scale: 0.55)
                        .ignoresSafeArea()
                }
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

            // Tap toggles controls; swipe up/down zaps. Excluded on cameras —
            // there the tiles handle taps and the scene handles the swipe.
            if !state.isCamerasTuned {
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { showControls.toggle() }
                        if showControls { scheduleHide() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 40)
                            .onEnded { value in
                                let dy = value.translation.height
                                let dx = value.translation.width
                                if abs(dy) > 60, abs(dy) > abs(dx) {
                                    if dy < 0 { state.channelUp() } else { state.channelDown() }
                                } else if abs(dx) > 60, state.tunedMixInfo != nil {
                                    // Mix channels: horizontal swipe hops
                                    // between the family's variants.
                                    state.cycleVariant(dx < 0 ? 1 : -1)
                                } else {
                                    return
                                }
                                withAnimation { showControls = true }
                                scheduleHide()
                            }
                    )
            }

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
                // Keep the controls inside the safe area so the top button row
                // clears the Dynamic Island / notch (otherwise the Cast and
                // AirPlay buttons render underneath it and vanish) and the zap
                // chevrons clear the home indicator. The video/scene layers
                // below still bleed full-screen via their own .ignoresSafeArea().
                controls
                    .padding(.top, geo.safeAreaInsets.top)
                    .padding(.bottom, geo.safeAreaInsets.bottom)
            }

            // While a Chromecast session is live the stream plays on the TV and
            // the phone is paused (AppState.castWatch). Cover the frozen frame
            // with an interactive casting card — it's the control surface (stop,
            // play/pause, channel ±), so it sits on top of everything.
            if let castName = castingDeviceName {
                CastingOverlayIOS(deviceName: castName)
            }
        }
        .ignoresSafeArea()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { if state.isCamerasTuned { showControls = true } else { scheduleHide() } }
        // Cameras keep the controls up (taps open cameras, not the controls),
        // so make sure they're showing whenever the cameras channel is tuned.
        .onChange(of: state.isCamerasTuned) { _, cameras in
            if cameras { withAnimation { showControls = true } } else { scheduleHide() }
        }
    }

    /// Cameras channel: horizontal swipe walks the spotlight, vertical zaps.
    private var cameraSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 40).onEnded { value in
            let dx = value.translation.width
            let dy = value.translation.height
            if abs(dx) > abs(dy), abs(dx) > 60 {
                state.cameraSpotlightMove(dx < 0 ? 1 : -1)
            } else if abs(dy) > 60 {
                if dy < 0 { state.channelUp() } else { state.channelDown() }
            }
        }
    }

    private var controls: some View {
        VStack {
            HStack(alignment: .top) {
                // Back to the camera grid from the spotlight.
                if state.isCamerasTuned, state.cameraSpotlight != nil {
                    Button {
                        state.cameraSpotlightExit()
                        scheduleHide()
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 48, height: 48)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                if let channel = state.tunedChannel {
                    let mix = state.tunedMixInfo
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(mix?.baseNumber ?? channel.number)  \((mix?.baseName ?? channel.name).uppercased())"
                             + (mix.map { " · MIX \($0.index + 1)/\($0.count)" } ?? ""))
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
                // Cast / AirPlay only apply to a live Tunarr stream. Synthetic
                // channels (weather/cameras/photos/dashboards) render on-device
                // with no AVPlayer stream to hand off, so hide the dead controls
                // there rather than leave them non-functional over the scene.
                if !state.isSyntheticTuned {
                    // Cast: send the live channel to a Chromecast on the LAN.
                    CastButton(controller: state.cast,
                               streamURL: state.castableStreamURL,
                               title: state.castableChannelTitle)
                    // AirPlay: hand the stream off to an Apple TV / AirPlay 2 receiver.
                    AirPlayButton()
                        .frame(width: 24, height: 24)
                        .frame(width: 48, height: 48)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Circle())
                }
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
                    // Mix channels: hop to the next variant (or swipe
                    // horizontally anywhere on the video).
                    if state.tunedMixInfo != nil {
                        zapButton("shuffle", tint: Theme.onAir) {
                            state.cycleVariant(1)
                            scheduleHide()
                        }
                    }
                }
                .padding(.trailing, 16)
            }
            .padding(.bottom, 30)
        }
    }

    private func zapButton(_ symbol: String, tint: Color = .white,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 48, height: 48)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
        }
    }

    /// The receiver name while a cast session is connecting or live, else nil.
    private var castingDeviceName: String? {
        switch state.cast.status {
        case .connecting(let name), .casting(let name): return name
        case .idle, .discovering, .failed: return nil
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        // Cameras keep the controls up (taps open cameras, not the controls).
        if state.isCamerasTuned { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                withAnimation { showControls = false }
            }
        }
    }
}

/// Shown over the (paused) local player while casting to a Chromecast: the
/// stream plays on the TV, so the phone shows a status + control card instead
/// of running the same video a second time. This is the cast control surface —
/// stop, play/pause, and channel changes all route to the receiver.
private struct CastingOverlayIOS: View {
    @EnvironmentObject var state: AppState
    let deviceName: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "tv.fill")
                    .font(.system(size: 48))
                    .foregroundColor(Theme.onAir)
                Text("CASTING TO")
                    .font(Theme.mono(14))
                    .foregroundColor(Theme.dimText)
                Text(deviceName.uppercased())
                    .font(Theme.mono(24, weight: .medium))
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)

                if let channel = state.tunedChannel {
                    Text("\(channel.number)  \(channel.name.uppercased())")
                        .font(Theme.mono(16))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.top, 6)
                    if let entry = state.nowPlaying(on: channel) {
                        Text(entry.title.uppercased())
                            .font(Theme.mono(12, weight: .medium))
                            .foregroundColor(Theme.dimText)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 26) {
                    ctl("chevron.down") { state.channelDown() }
                    ctl(state.cast.isPaused ? "play.fill" : "pause.fill") { state.cast.togglePlayPause() }
                    ctl("stop.fill", tint: Theme.accent) { state.cast.stopCasting() }
                    ctl("chevron.up") { state.channelUp() }
                }
                .padding(.top, 14)

                Button { state.isFullscreen = false } label: {
                    Text("EXIT FULLSCREEN")
                        .font(Theme.mono(13))
                        .foregroundColor(Theme.dimText)
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(40)
        }
    }

    private func ctl(_ symbol: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(tint)
                .frame(width: 60, height: 60)
                .background(Color.white.opacity(0.12))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
#endif
