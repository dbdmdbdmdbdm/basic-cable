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
    @State private var serverStats: ServerStats?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Player layer — owns channel zapping and its remote gestures. The
            // quick panel is deliberately a SIBLING of this (below), not a
            // child: that keeps the panel's toggles outside this view's
            // .onMoveCommand scope, so the focus engine — not the channel
            // zapper — drives up/down navigation between the toggles.
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Not focusable while the panel is open, so focus can't leak back
            // here from the panel's toggles and let .onMoveCommand hijack the
            // D-pad (which was zapping channels instead of driving the menu).
            .focusable(!showQuickPanel)
            .focused($focused)
            // Select press returns to the guide (Menu via onExitCommand does
            // too); press-and-hold select opens quick options instead.
            .onTapGesture {
                guard !showQuickPanel else { return }
                if state.isCamerasTuned {
                    // Select opens the highlighted camera (or backs out of one).
                    if state.cameraSpotlight == nil { state.cameraSpotlightFocus(state.cameraGridSelection) }
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
            .onMoveCommand { direction in
                // Only fires while the panel is closed — once it opens this
                // layer isn't focusable, so the panel's own focus engine takes
                // over navigation.
                // On the cameras channel, left/right walks the spotlight
                // through the bank; up/down still zaps channels.
                if state.isCamerasTuned {
                    switch direction {
                    case .up: state.channelUp(); showBanner()
                    case .down: state.channelDown(); showBanner()
                    // In the grid, ◀/▶ walk the highlight; once a camera is open
                    // they switch which camera is spotlighted.
                    case .left:
                        if state.cameraSpotlight == nil { state.cameraGridSelectionMove(-1) }
                        else { state.cameraSpotlightMove(-1) }
                    case .right:
                        if state.cameraSpotlight == nil { state.cameraGridSelectionMove(1) }
                        else { state.cameraSpotlightMove(1) }
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
                case .left where state.tunedMixInfo != nil:
                    // Mix channels: ◀/▶ hop between the family's variants
                    // (quick options stay on hold-select).
                    state.cycleVariant(-1)
                    showBanner()
                case .right where state.tunedMixInfo != nil:
                    state.cycleVariant(1)
                    showBanner()
                case .left, .right:
                    // Quick options for the tuned channel (up/down keep zapping).
                    showQuickPanel = true
                    panelFocused = true
                @unknown default:
                    break
                }
            }
            // These fire while the panel is CLOSED (this layer holds focus).
            // When the panel is open, focus is inside it and its own
            // .onExitCommand (below) handles Menu.
            .onPlayPauseCommand { state.togglePause() }
            .onExitCommand {
                if state.isCamerasTuned, state.cameraSpotlight != nil {
                    // Menu backs out of the spotlight to the camera grid first.
                    state.cameraSpotlightExit()
                } else {
                    state.isFullscreen = false
                }
            }

            // Quick options — a SIBLING of the player layer so its toggles sit
            // outside the .onMoveCommand above and navigate with the focus
            // engine. It carries its own .onExitCommand so Menu closes it: the
            // outer container isn't focusable, so an exit handler there wouldn't
            // fire while focus is on a toggle in here.
            if showQuickPanel, let channel = state.tunedChannel {
                quickPanel(for: channel)
                    .onExitCommand { closeQuickPanel() }
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
                Divider().background(Color(white: 0.25))
                statsSection()
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
        .task { await statsLoop() }
    }

    // MARK: - Server stats

    /// Snapshot for the panel's SERVER STATS readout: live sessions straight
    /// from Tunarr, plus slower-moving health pushed into HA by the LXC-side
    /// watchdog/push scripts (absent entities just hide their line).
    struct ServerStats {
        var tunarrReachable = false
        var version: String?
        var sessions: [TunarrClient.SessionDetail] = []
        var ffmpegCount: Int?          // real process count (≤5 min stale, via HA)
        var watchdogRestarts24h: Int?
        var factoryState: String?      // idle | transcoding | capped
        var currentMovie: String?
        var libraryGB: Double?
    }

    /// Refreshes stats every few seconds while the panel is open; the .task
    /// on the panel cancels this when it closes.
    private func statsLoop() async {
        while !Task.isCancelled {
            await loadStats()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func loadStats() async {
        guard !state.isDemoMode, let client = state.client else { return }
        var stats = ServerStats()
        do {
            async let version = client.fetchVersion()
            async let sessions = client.fetchSessionDetails()
            stats.version = try await version
            stats.sessions = try await sessions
                .sorted { ($0.newestHeartbeatAge ?? .max) < ($1.newestHeartbeatAge ?? .max) }
            stats.tunarrReachable = true
        } catch {
            stats.tunarrReachable = false
        }
        if let ha = state.haClient {
            if let detail = await ha.fetchStateDetail(entityId: "sensor.tunarr_transcode_status") {
                stats.factoryState = detail.state
                stats.ffmpegCount = detail.attributes["ffmpeg_count"] as? Int
                if detail.attributes["transcoding_now"] as? Bool == true {
                    stats.currentMovie = detail.attributes["current_movie"] as? String
                }
                stats.libraryGB = (detail.attributes["library_gb"] as? NSNumber)?.doubleValue
            }
            if let detail = await ha.fetchStateDetail(entityId: "sensor.tunarr_watchdog_restarts_24h") {
                stats.watchdogRestarts24h = Int(detail.state)
            }
        }
        serverStats = stats
    }

    @ViewBuilder
    private func statsSection() -> some View {
        if state.isDemoMode {
            Text("SERVER STATS UNAVAILABLE IN DEMO MODE")
                .font(Theme.mono(16, weight: .medium))
                .foregroundColor(Theme.dimText)
        } else if state.client == nil {
            Text("NO TUNARR SERVER CONFIGURED")
                .font(Theme.mono(16, weight: .medium))
                .foregroundColor(Theme.dimText)
        } else if let stats = serverStats {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("SERVER STATS")
                        .font(Theme.mono(18))
                        .foregroundColor(.white)
                    Spacer()
                    Text(stats.tunarrReachable
                         ? "TUNARR \(stats.version ?? "?") · UP"
                         : "TUNARR UNREACHABLE")
                        .font(Theme.mono(16, weight: .medium))
                        .foregroundColor(stats.tunarrReachable ? Theme.onAir : Theme.accent)
                }
                if stats.tunarrReachable {
                    Text("ACTIVE STREAMS: \(stats.sessions.count)")
                        .font(Theme.mono(16, weight: .medium))
                        .foregroundColor(Theme.dimText)
                    ForEach(stats.sessions) { session in
                        HStack(spacing: 12) {
                            Text(channelLabel(for: session.channelId))
                                .font(Theme.mono(16, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            Spacer()
                            Text(sessionDetailLabel(session))
                                .font(Theme.mono(15, weight: .medium))
                                .foregroundColor(Theme.dimText)
                        }
                    }
                }
                if let health = healthLine(stats) {
                    Text(health)
                        .font(Theme.mono(15, weight: .medium))
                        .foregroundColor(Theme.dimText)
                }
            }
        } else {
            Text("LOADING SERVER STATS…")
                .font(Theme.mono(16, weight: .medium))
                .foregroundColor(Theme.dimText)
        }
    }

    private func channelLabel(for channelId: String) -> String {
        if let channel = state.allChannels.first(where: { $0.id == channelId }) {
            return "CH \(channel.number) \(channel.name.uppercased())"
        }
        return String(channelId.prefix(8)).uppercased()
    }

    private func sessionDetailLabel(_ session: TunarrClient.SessionDetail) -> String {
        var parts = ["\(session.numConnections) \(session.numConnections == 1 ? "VIEWER" : "VIEWERS")"]
        if let age = session.newestHeartbeatAge {
            parts.append("HB \(age)S")
        }
        return parts.joined(separator: " · ")
    }

    /// One line of slower-moving health from the HA sensors; nil when HA
    /// isn't configured or the sensors don't exist on this install.
    private func healthLine(_ stats: ServerStats) -> String? {
        var parts: [String] = []
        if let count = stats.ffmpegCount { parts.append("FFMPEG PROCS \(count)") }
        if let restarts = stats.watchdogRestarts24h { parts.append("WATCHDOG 24H \(restarts)") }
        if let factory = stats.factoryState {
            var label = "COPY FACTORY \(factory.uppercased())"
            if let movie = stats.currentMovie { label += " (\(movie.uppercased()))" }
            parts.append(label)
        }
        if let gb = stats.libraryGB { parts.append("SDR LIB \(Int(gb))GB") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        // A mix member wears its family's identity — same number and name
        // as the guide entry, plus which mix is on.
        let mix = state.tunedMixInfo
        return HStack(spacing: 16) {
            Text("\(mix?.baseNumber ?? channel.number)")
                .font(Theme.mono(40))
                .foregroundColor(Theme.onAir)
            VStack(alignment: .leading, spacing: 4) {
                Text((mix?.baseName ?? channel.name).uppercased())
                    .font(Theme.mono(28))
                    .foregroundColor(.white)
                if let entry = state.nowPlaying(on: channel) {
                    Text(entry.title.uppercased())
                        .font(Theme.mono(20, weight: .medium))
                        .foregroundColor(Theme.dimText)
                }
                if let mix {
                    Text("MIX \(mix.index + 1)/\(mix.count) · LEFT/RIGHT TO SWITCH")
                        .font(Theme.mono(15, weight: .medium))
                        .foregroundColor(Theme.onAir)
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
