import SwiftUI

enum Theme {
    // Retro guide palette, modeled on classic cable guides.
    // Cells are colored per show/movie (same title -> same color).
    static let background = Color.black
    static let channelColumn = Color(red: 0.10, green: 0.19, blue: 0.42)
    static let channelColumnTuned = Color(red: 0.15, green: 0.28, blue: 0.60)
    static let cellFlex = Color(white: 0.28)
    static let cellWeather = Color(red: 0.55, green: 0.66, blue: 0.85)

    /// Three quiet shades for program cells. Within a channel row, each
    /// distinct show/movie takes the next shade in the cycle (episodes of
    /// one show share a shade), so adjacent programs always separate
    /// without the guide turning into a rainbow.
    static let cellShades: [Color] = [
        Color(white: 0.70),                          // light gray
        Color(white: 0.57),                          // mid gray
        Color(red: 0.72, green: 0.69, blue: 0.60),   // warm greige
    ]
    static let cellText = Color.black
    static let onAir = Color(red: 0.13, green: 0.75, blue: 0.25)
    static let onAirElapsed = Color(red: 0.08, green: 0.52, blue: 0.17)
    static let nowLine = Color.red
    static let accent = Color.red
    static let panelText = Color.white
    static let dimText = Color(white: 0.65)
    static let controlBackground = Color(white: 0.16)

    static func mono(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // MARK: - Channel accent colors

    /// Fixed retro palette for channel accent stripes.
    static let accentPalette: [Color] = [
        Color(red: 0.85, green: 0.25, blue: 0.25),  // red
        Color(red: 0.95, green: 0.55, blue: 0.15),  // orange
        Color(red: 0.93, green: 0.78, blue: 0.20),  // yellow
        Color(red: 0.30, green: 0.75, blue: 0.35),  // green
        Color(red: 0.25, green: 0.72, blue: 0.83),  // cyan
        Color(red: 0.55, green: 0.48, blue: 0.90),  // violet
        Color(red: 0.88, green: 0.40, blue: 0.68),  // magenta
    ]

    /// Accent for a channel: by group when the lineup has multiple groups
    /// (so groups cluster visually), otherwise a rainbow by channel number.
    static func channelAccent(for channel: Channel, multipleGroups: Bool) -> Color {
        if channel.id == WeatherChannel.id {
            return Color(red: 0.95, green: 0.78, blue: 0.12)
        }
        if multipleGroups, let group = channel.groupTitle {
            // djb2 — stable across launches, unlike hashValue.
            var hash: UInt64 = 5381
            for byte in group.utf8 { hash = hash &* 33 &+ UInt64(byte) }
            return accentPalette[Int(hash % UInt64(accentPalette.count))]
        }
        return accentPalette[max(0, channel.number - 1) % accentPalette.count]
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter
    }()

    static let timeWithPeriodFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
