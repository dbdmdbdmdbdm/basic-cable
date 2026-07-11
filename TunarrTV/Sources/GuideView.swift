import SwiftUI

enum FocusTarget: Hashable {
    case cell(String)
    case channelLabel(String)
    case pagerLeft(String)
    case pagerRight(String)
}

struct GuideView: View {
    @EnvironmentObject var state: AppState
    @FocusState private var focus: FocusTarget?

    /// 1.0 for the TV layout; smaller on iOS.
    var scale: CGFloat = 1

    private var labelWidth: CGFloat { 210 * scale }
    private var pagerWidth: CGFloat { 42 * scale }
    private var rowHeight: CGFloat { 60 * scale }
    private var spacing: CGFloat { max(3 * scale, 2) }
    private var headerHeight: CGFloat { 36 * scale }

    var body: some View {
        GeometryReader { geo in
            let cellAreaWidth = geo.size.width - labelWidth - pagerWidth * 2 - spacing * 3
            let ppm = cellAreaWidth / CGFloat(AppState.windowMinutes)

            VStack(spacing: 4) {
                headerRow(ppm: ppm)
                    .frame(height: headerHeight)

                ZStack(alignment: .topLeading) {
                    ScrollView(.vertical) {
                        VStack(spacing: spacing) {
                            ForEach(state.channels) { channel in
                                row(channel, ppm: ppm, cellAreaWidth: cellAreaWidth)
                            }
                        }
                    }
                    nowLine(ppm: ppm, height: geo.size.height - headerHeight - 4)
                }
            }
        }
        .onChange(of: focus) { _, newValue in
            switch newValue {
            case .cell(let id):
                if let entry = entry(withId: id) {
                    state.focusedEntry = entry
                    // Warm the session while the user is still deciding.
                    if let channel = state.channel(withId: entry.channelId) {
                        state.prefetch(channel)
                    }
                }
            case .channelLabel(let channelId):
                if let channel = state.channel(withId: channelId) {
                    state.prefetch(channel)
                }
            default:
                break
            }
        }
    }

    // MARK: - Header

    private func headerRow(ppm: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: labelWidth + pagerWidth + spacing * 2)
            ForEach(0..<(AppState.windowMinutes / 15), id: \.self) { slot in
                let slotStart = state.windowStart.addingTimeInterval(TimeInterval(slot * 15 * 60))
                let slotEnd = slotStart.addingTimeInterval(15 * 60)
                let isNow = state.now >= slotStart && state.now < slotEnd
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color(white: 0.5))
                        .frame(width: 2)
                    Text(Theme.timeFormatter.string(from: slotStart))
                        .font(Theme.mono(22 * scale))
                        .foregroundColor(isNow ? Theme.accent : .white)
                        .padding(.leading, 8 * scale)
                    Spacer(minLength: 0)
                }
                .frame(width: 15 * ppm)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Rows

    private func row(_ channel: Channel, ppm: CGFloat, cellAreaWidth: CGFloat) -> some View {
        HStack(spacing: spacing) {
            channelLabel(channel)
            pagerButton(.pagerLeft(channel.id), symbol: "chevron.left") {
                state.pageBack()
            }
            .disabled(!state.canPageBack)

            entryCells(channel, ppm: ppm)
                .frame(width: cellAreaWidth, height: rowHeight, alignment: .leading)
                .clipped()

            pagerButton(.pagerRight(channel.id), symbol: "chevron.right") {
                state.pageForward()
            }
        }
        .frame(height: rowHeight)
    }

    private var hasMultipleGroups: Bool {
        Set(state.channels.compactMap(\.groupTitle)).count > 1
    }

    private func channelLabel(_ channel: Channel) -> some View {
        Button {
            // Same semantics as program cells: tap to tune, tap the
            // tuned channel again for fullscreen.
            if state.tunedChannel?.id == channel.id {
                state.isFullscreen = true
            } else {
                state.tune(channel)
            }
        } label: {
            ChannelLabelView(
                channel: channel,
                isTuned: state.tunedChannel?.id == channel.id,
                accent: Theme.channelAccent(for: channel, multipleGroups: hasMultipleGroups),
                scale: scale
            )
        }
        .buttonStyle(RetroCellButtonStyle())
        .frame(width: labelWidth, height: rowHeight)
        .focused($focus, equals: .channelLabel(channel.id))
    }

    /// Shade per title, assigned in order of first appearance across the
    /// channel's full fetched lineup (stable while paging the window).
    private func shadeMap(for channel: Channel) -> [String: Color] {
        var map: [String: Color] = [:]
        var next = 0
        for entry in state.guide[channel.id] ?? [] where map[entry.title] == nil {
            map[entry.title] = Theme.cellShades[next % Theme.cellShades.count]
            next += 1
        }
        return map
    }

    private func entryCells(_ channel: Channel, ppm: CGFloat) -> some View {
        let window = state.windowStart...state.windowEnd
        let entries = state.entries(for: channel, in: window)
        let shades = shadeMap(for: channel)

        return HStack(spacing: spacing) {
            if entries.isEmpty {
                Text("NO GUIDE DATA")
                    .font(Theme.mono(18 * scale))
                    .foregroundColor(Color(white: 0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, 10)
                    .background(Theme.cellFlex)
            } else {
                ForEach(entries) { entry in
                    let visibleStart = max(entry.start, state.windowStart)
                    let visibleEnd = min(entry.stop, state.windowEnd)
                    let minutes = visibleEnd.timeIntervalSince(visibleStart) / 60
                    let width = max(CGFloat(minutes) * ppm - spacing, 26)
                    let isOnAir = entry.airs(at: state.now) && state.tunedChannel?.id == channel.id
                    let visibleSpan = visibleEnd.timeIntervalSince(visibleStart)
                    let progress: Double? = (isOnAir && visibleSpan > 0)
                        ? min(max(state.now.timeIntervalSince(visibleStart) / visibleSpan, 0), 1)
                        : nil

                    Button {
                        // Select on the already-tuned channel goes fullscreen;
                        // otherwise tune to it.
                        if state.tunedChannel?.id == channel.id {
                            state.isFullscreen = true
                        } else {
                            state.tune(channel)
                        }
                    } label: {
                        GuideCellView(
                            entry: entry,
                            isOnAir: isOnAir,
                            shade: shades[entry.title] ?? Theme.cellShades[0],
                            progress: progress,
                            scale: scale
                        )
                    }
                    .buttonStyle(RetroCellButtonStyle())
                    .frame(width: width, height: rowHeight)
                    .focused($focus, equals: .cell(entry.id))
                }
            }
        }
    }

    private func pagerButton(_ target: FocusTarget, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PagerLabel(symbol: symbol, scale: scale)
        }
        .buttonStyle(RetroCellButtonStyle())
        .frame(width: pagerWidth, height: rowHeight)
        .focused($focus, equals: target)
    }

    // MARK: - Now line

    @ViewBuilder
    private func nowLine(ppm: CGFloat, height: CGFloat) -> some View {
        let minutes = state.now.timeIntervalSince(state.windowStart) / 60
        if minutes >= 0 && minutes <= Double(AppState.windowMinutes) {
            Rectangle()
                .fill(Theme.nowLine)
                .frame(width: 3, height: max(height, 0))
                .offset(x: labelWidth + pagerWidth + spacing * 2 + CGFloat(minutes) * ppm)
                .allowsHitTesting(false)
        }
    }

    private func entry(withId id: String) -> GuideEntry? {
        for entries in state.guide.values {
            if let match = entries.first(where: { $0.id == id }) {
                return match
            }
        }
        return nil
    }
}

struct GuideCellView: View {
    @Environment(\.isFocused) private var isFocused
    let entry: GuideEntry
    let isOnAir: Bool
    let shade: Color
    var progress: Double?
    var scale: CGFloat = 1

    private var background: Color {
        if isOnAir { return Theme.onAir }
        if entry.kind == .weather { return Theme.cellWeather }
        if entry.isFlex { return Theme.cellFlex }
        return shade
    }

    private var textColor: Color {
        entry.isFlex ? Color(white: 0.6) : Theme.cellText
    }

    var body: some View {
        Text(entry.title.uppercased())
            .font(Theme.mono(18 * scale))
            .foregroundColor(textColor)
            .lineLimit(1)
            .padding(.leading, 10 * scale)
            .padding(.trailing, 4 * scale)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        background
                        // Elapsed portion of the on-air program.
                        if isOnAir, let progress {
                            Theme.onAirElapsed
                                .frame(width: geo.size.width * progress)
                        }
                    }
                }
            )
            .overlay(
                Rectangle()
                    .stroke(isFocused ? Color.white : Color.clear, lineWidth: 4)
            )
    }
}

struct ChannelLabelView: View {
    @Environment(\.isFocused) private var isFocused
    let channel: Channel
    let isTuned: Bool
    let accent: Color
    let scale: CGFloat

    var body: some View {
        HStack(spacing: 8 * scale) {
            Rectangle()
                .fill(accent)
                .frame(width: max(5 * scale, 3))
            ChannelLogoView(channel: channel, size: 38 * scale)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(channel.number)")
                    .font(Theme.mono(16 * scale, weight: .medium))
                    .foregroundColor(Color(white: 0.8))
                Text(channel.name.uppercased())
                    .font(Theme.mono(17 * scale))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(isTuned ? Theme.channelColumnTuned : Theme.channelColumn)
        .overlay(
            Rectangle()
                .stroke(isFocused ? Color.white : Color.clear, lineWidth: 4)
        )
    }
}

/// Channel icon from Tunarr (or a symbol for the synthetic weather channel).
struct ChannelLogoView: View {
    let channel: Channel
    let size: CGFloat

    var body: some View {
        Group {
            if channel.id == WeatherChannel.id {
                Image(systemName: "cloud.sun.fill")
                    .font(.system(size: size * 0.55))
                    .foregroundColor(.yellow)
            } else if let path = channel.icon?.path, !path.isEmpty, let url = URL(string: path) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
    }
}

struct PagerLabel: View {
    @Environment(\.isFocused) private var isFocused
    let symbol: String
    var scale: CGFloat = 1

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 20 * scale, weight: .heavy))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isFocused ? Color(white: 0.35) : Color(white: 0.12))
            .overlay(
                Rectangle()
                    .stroke(isFocused ? Color.white : Color.clear, lineWidth: 3)
            )
    }
}
