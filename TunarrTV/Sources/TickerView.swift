import SwiftUI

/// A news-channel style ticker along the bottom of fullscreen playback:
/// a solid black bar with what's playing on the configured Home Assistant
/// media players on the left (falling back to this channel's program) and
/// weather + clock on the right. Enabled per channel from the player.
struct ChannelTickerView: View {
    @EnvironmentObject var state: AppState
    var compact = false

    @State private var nowPlaying: [HAClient.NowPlayingItem] = []
    @State private var rotationIndex = 0

    private var textSize: CGFloat { compact ? 12 : 22 }

    var body: some View {
        HStack(spacing: compact ? 12 : 28) {
            leftSide
            Spacer(minLength: compact ? 12 : 30)
            rightSide
        }
        .padding(.horizontal, compact ? 16 : 48)
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 34 : 58)
        .background(Color.black)
        .overlay(Rectangle().fill(Color(white: 0.22)).frame(height: 1), alignment: .top)
        .task { await poll() }
    }

    @ViewBuilder
    private var leftSide: some View {
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
                if nowPlaying.count > 1 {
                    Text("\(rotationIndex % nowPlaying.count + 1)/\(nowPlaying.count)")
                        .font(Theme.mono(textSize * 0.75, weight: .medium))
                        .foregroundColor(Theme.dimText)
                }
            }
        } else if let channel = state.tunedChannel,
                  let entry = state.nowPlaying(on: channel) {
            Text("NOW  \(entry.title.uppercased())")
                .font(Theme.mono(textSize, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
        }
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
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            ticks += 1
            rotationIndex += 1
            if ticks.isMultiple(of: 2) {
                nowPlaying = await state.fetchNowPlaying()
            }
        }
    }
}
