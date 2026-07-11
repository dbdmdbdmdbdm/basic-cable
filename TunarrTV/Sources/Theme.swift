import SwiftUI

enum Theme {
    // Retro guide palette, modeled on classic cable guides.
    // Cells are colored per show/movie (same title -> same color).
    static let background = Color.black
    static let channelColumn = Color(red: 0.10, green: 0.19, blue: 0.42)
    static let channelColumnTuned = Color(red: 0.15, green: 0.28, blue: 0.60)
    static let cellFlex = Color(white: 0.28)
    static let cellWeather = Color(red: 0.55, green: 0.66, blue: 0.85)
    static let cellDashboard = Color(red: 0.52, green: 0.78, blue: 0.70)
    static let cellPhotos = Color(red: 0.85, green: 0.68, blue: 0.55)

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

    /// Preview hook: `--font <PostScriptName>` swaps the app-wide face so
    /// candidate fonts can be screenshotted side by side. No arg = SF Mono.
    private static let fontOverride: String? = {
        guard let index = CommandLine.arguments.firstIndex(of: "--font"),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }()

    static func mono(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        if let fontOverride {
            return .custom(fontOverride, size: size)
        }
        return .system(size: size, weight: weight, design: .monospaced)
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
