import SwiftUI

/// A news-channel style ticker along the bottom of fullscreen playback:
/// a solid black bar with what's playing on the configured Home Assistant
/// media players on the left (falling back to this channel's program) and
/// weather + clock on the right. Enabled per channel from the player.
struct ChannelTickerView: View {
    @EnvironmentObject var state: AppState
    var compact = false

    @State private var nowPlaying: [HAClient.NowPlayingItem] = []
    @State private var chips: [AppState.TickerChip] = []
    @State private var rotationIndex = 0

    private var textSize: CGFloat { compact ? 12 : 22 }

    var body: some View {
        HStack(spacing: compact ? 12 : 28) {
            if state.tickerScroll {
                // Classic news crawl: the whole left side drifts by.
                Marquee(speed: compact ? 40 : 80) { leftSide }
            } else {
                leftSide
            }
            Spacer(minLength: compact ? 12 : 30)
            rightSide
        }
        .padding(.horizontal, compact ? 16 : 48)
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 34 : 58)
        // The bar's black bleeds past the safe area (device corners, home
        // indicator) while the text above stays inside it.
        .background(Color.black.ignoresSafeArea())
        .overlay(Rectangle().fill(Color(white: 0.22)).frame(height: 1), alignment: .top)
        .task { await poll() }
    }

    @ViewBuilder
    private var leftSide: some View {
        HStack(spacing: compact ? 12 : 26) {
            if !nowPlaying.isEmpty {
                let item = nowPlaying[rotationIndex % nowPlaying.count]
                HStack(spacing: compact ? 6 : 12) {
                    Image(systemName: "music.note")
                        .font(.system(size: textSize * 0.85, weight: .bold))
                        .foregroundColor(Theme.onAir)
                    Text(nowPlayingText(item))
                        .font(Theme.mono(textSize, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    // Where it's playing: one named speaker, or a group icon
                    // with the count when several carry the same stream.
                    if item.players.count > 1 {
                        HStack(spacing: 4) {
                            Image(systemName: "hifispeaker.2.fill")
                                .font(.system(size: textSize * 0.75))
                            Text("\(item.players.count)")
                                .font(Theme.mono(textSize * 0.85, weight: .medium))
                        }
                        .foregroundColor(Theme.dimText)
                    } else if let player = item.players.first {
                        Text("· \(player.uppercased())")
                            .font(Theme.mono(textSize * 0.85, weight: .medium))
                            .foregroundColor(Theme.dimText)
                            .lineLimit(1)
                    }
                    if nowPlaying.count > 1 {
                        Text("\(rotationIndex % nowPlaying.count + 1)/\(nowPlaying.count)")
                            .font(Theme.mono(textSize * 0.75, weight: .medium))
                            .foregroundColor(Theme.dimText)
                    }
                }
            } else if chips.isEmpty,
                      let channel = state.tunedChannel,
                      let entry = state.nowPlaying(on: channel) {
                Text("NOW  \(entry.title.uppercased())")
                    .font(Theme.mono(textSize, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            // Entity chips from the add-on config (conditional, styled).
            ForEach(chips) { chip in
                HStack(spacing: compact ? 5 : 9) {
                    Image(systemName: Self.validSymbol(chip.icon))
                        .font(.system(size: textSize * 0.8, weight: .bold))
                        .foregroundColor(Self.namedColor(chip.colorName))
                    Text(chip.text)
                        .font(Theme.mono(textSize, weight: .medium))
                        .foregroundColor(Self.namedColor(chip.colorName))
                        .lineLimit(1)
                }
            }
        }
    }

    static func namedColor(_ name: String?) -> Color {
        switch name?.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "mint": return .mint
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "gray", "grey": return Color(white: 0.65)
        default: return .white
        }
    }

    static func validSymbol(_ name: String) -> String {
        UIImage(systemName: name) != nil ? name : "circle.fill"
    }

    private var rightSide: some View {
        HStack(spacing: compact ? 10 : 22) {
            if let current = state.weatherData.current {
                HStack(spacing: compact ? 5 : 10) {
                    Image(systemName: WMO.symbol(current.code))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: textSize * 0.85))
                    Text("\(Int(current.temperature.rounded()))° \(WMO.description(current.code))")
                        .font(Theme.mono(textSize, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(Theme.timeFormatter.string(from: context.date))
                    .font(Theme.mono(textSize, weight: .medium))
                    .foregroundColor(Theme.dimText)
            }
        }
        .fixedSize()
    }

    private func nowPlayingText(_ item: HAClient.NowPlayingItem) -> String {
        var text = item.title
        if let artist = item.artist, !artist.isEmpty {
            text += " — \(artist)"
        }
        return text.uppercased()
    }

    /// Refresh now-playing every other tick; rotate between distinct
    /// items (different players playing different things) every tick.
    private func poll() async {
        var ticks = 0
        nowPlaying = await state.fetchNowPlaying()
        chips = await state.fetchTickerChips()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            ticks += 1
            rotationIndex += 1
            if ticks.isMultiple(of: 2) {
                nowPlaying = await state.fetchNowPlaying()
                chips = await state.fetchTickerChips()
            }
        }
    }
}

/// A continuous right-to-left crawl: the content repeats with a gap and
/// drifts by at a constant speed, restarting whenever the content changes.
private struct Marquee<Content: View>: View {
    let speed: CGFloat
    @ViewBuilder let content: () -> Content

    @State private var contentWidth: CGFloat = 0
    @State private var animate = false

    private let gap: CGFloat = 120

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: gap) {
                measured
                content().fixedSize()
            }
            .offset(x: animate ? -(contentWidth + gap) : 0)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .clipped()
        }
        .onChange(of: contentWidth) { _, width in
            guard width > 0 else { return }
            animate = false
            withAnimation(.linear(duration: Double((width + gap) / speed)).repeatForever(autoreverses: false)) {
                animate = true
            }
        }
    }

    private var measured: some View {
        content()
            .fixedSize()
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear { contentWidth = geo.size.width }
                }
            )
    }
}
