import SwiftUI

/// Live status for the guide's top-right corner: weather + clock up top, then
/// the same now-playing and Home Assistant entity chips the bottom ticker
/// shows — so you can see them while browsing the guide without turning the
/// ticker on. Reuses the ticker's data (fetchNowPlaying / fetchTickerChips).
struct GuideStatusPanel: View {
    @EnvironmentObject var state: AppState
    /// Shrinks everything for the smaller iPad top pane; tvOS uses 1.0.
    var scale: CGFloat = 1.0

    @State private var nowPlaying: [HAClient.NowPlayingItem] = []
    @State private var chips: [AppState.TickerChip] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: 16 * scale) {
            weather
            ForEach(chips) { chip in
                row(icon: ChannelTickerView.validSymbol(chip.icon),
                    text: chip.text,
                    color: ChannelTickerView.namedColor(chip.colorName))
            }
            if let item = nowPlaying.first {
                row(icon: "music.note", text: nowPlayingText(item), color: Theme.onAir)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .task { await poll() }
    }

    @ViewBuilder
    private var weather: some View {
        if let current = state.weatherData.current {
            VStack(alignment: .trailing, spacing: 4 * scale) {
                HStack(spacing: 10 * scale) {
                    Image(systemName: WMO.symbol(current.code))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 34 * scale))
                    Text("\(Int(current.temperature.rounded()))°")
                        .font(Theme.mono(42 * scale))
                        .foregroundColor(.white)
                }
                Text(WMO.description(current.code))
                    .font(Theme.mono(18 * scale, weight: .medium))
                    .foregroundColor(Theme.dimText)
                    .lineLimit(1)
                if let name = state.weatherData.locationName {
                    Text(name.uppercased())
                        .font(Theme.mono(14 * scale, weight: .medium))
                        .foregroundColor(Theme.dimText)
                        .lineLimit(1)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(Theme.timeFormatter.string(from: context.date))
                        .font(Theme.mono(20 * scale, weight: .medium))
                        .foregroundColor(Theme.dimText)
                }
            }
        }
    }

    private func row(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 8 * scale) {
            Image(systemName: icon)
                .font(.system(size: 18 * scale, weight: .bold))
                .foregroundColor(color)
            Text(text)
                .font(Theme.mono(18 * scale, weight: .medium))
                .foregroundColor(color)
                .lineLimit(1)
        }
    }

    private func nowPlayingText(_ item: HAClient.NowPlayingItem) -> String {
        var text = item.title
        if let artist = item.artist, !artist.isEmpty { text += " — \(artist)" }
        return text.uppercased()
    }

    private func poll() async {
        await state.refreshWeather()
        nowPlaying = await state.fetchNowPlaying()
        chips = await state.fetchTickerChips()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            nowPlaying = await state.fetchNowPlaying()
            chips = await state.fetchTickerChips()
        }
    }
}
