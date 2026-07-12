import Foundation
import UIKit

/// Canned lineup for demo mode: fake retro channels with believable
/// schedules, each playing a bundled test-pattern clip on loop. Lets App
/// Review (and the curious) explore the guide without a Tunarr server.
enum DemoContent {
    struct Show {
        let title: String
        let minutes: Int
        var subtitle: String? = nil
        var summary: String? = nil
        var year: Int? = nil
        var episodeLabel: String? = nil
    }

    struct DemoChannel {
        let id: String
        let name: String
        let number: Int
        /// Bundled video resource (mp4) this channel loops.
        let clip: String
        /// Repeating schedule block; durations are multiples of 30 min so
        /// program starts land on the quarter hour.
        let shows: [Show]
    }

    static let channels: [DemoChannel] = [
        DemoChannel(id: "demo-retro-one", name: "Retro One", number: 2, clip: "demo-bars", shows: [
            Show(title: "Mall Security", minutes: 30,
                 subtitle: "The Food Court Incident",
                 summary: "Rent-a-cop Randy patrols the food court like it's the wild west.",
                 episodeLabel: "S3 E11"),
            Show(title: "Roommates & Rivals", minutes: 30,
                 subtitle: "The Thermostat War",
                 summary: "Four strangers, one apartment, zero chill.",
                 episodeLabel: "S1 E4"),
            Show(title: "Diner Days", minutes: 30,
                 subtitle: "Free Refill Friday",
                 summary: "Life behind the counter of the last 24-hour diner in town.",
                 episodeLabel: "S2 E8"),
            Show(title: "Cul-De-Sac", minutes: 30,
                 subtitle: "The Lawn Ultimatum",
                 summary: "Suburban neighbors take yard care far too seriously.",
                 episodeLabel: "S4 E2"),
        ]),
        DemoChannel(id: "demo-movie-vault", name: "Movie Vault", number: 5, clip: "demo-synthwave", shows: [
            Show(title: "Laser Quest", minutes: 120,
                 summary: "A mall arcade champion is recruited to fight a very real space war.",
                 year: 1987),
            Show(title: "Midnight Drive", minutes: 90,
                 summary: "A getaway driver takes one last job on the neon streets.",
                 year: 1984),
            Show(title: "Summer Camp Panic", minutes: 90,
                 summary: "The counselors of Camp Wanahonk face their worst season yet: the campers.",
                 year: 1989),
        ]),
        DemoChannel(id: "demo-cartoon-city", name: "Cartoon City", number: 9, clip: "demo-cartoon", shows: [
            Show(title: "Captain Comet & Crew", minutes: 30,
                 summary: "The galaxy's clumsiest hero saves the day, mostly by accident.",
                 episodeLabel: "E23"),
            Show(title: "Robo-Pals", minutes: 30,
                 summary: "Two robots, one paper route, endless malfunctions.",
                 episodeLabel: "E7"),
            Show(title: "The Wacky Woods", minutes: 30,
                 summary: "Forest critters run the world's least organized summer camp.",
                 episodeLabel: "E15"),
            Show(title: "Space Mice", minutes: 30,
                 summary: "Tiny astronauts, big cheese-related ambitions.",
                 episodeLabel: "E31"),
        ]),
        DemoChannel(id: "demo-sports-desk", name: "Sports Desk", number: 14, clip: "demo-static", shows: [
            Show(title: "Classic Game Rewind", minutes: 90,
                 summary: "Relive the 1986 championship — every play, every mullet."),
            Show(title: "Sports Desk Tonight", minutes: 30,
                 summary: "Scores, highlights, and a heated segment about hot dogs."),
            Show(title: "World of Racquetball", minutes: 60,
                 summary: "The fastest-growing sport of 1985, still going strong here."),
        ]),
        DemoChannel(id: "demo-synth-fm", name: "Synth FM", number: 23, clip: "demo-synthwave", shows: [
            Show(title: "Video Jukebox", minutes: 60,
                 summary: "Back-to-back synth-pop videos, hosted by VJ Max Wave."),
            Show(title: "Power Hour", minutes: 60,
                 summary: "Sixty minutes of pure analog energy."),
            Show(title: "Late Night Vibes", minutes: 60,
                 summary: "Slow synths for night owls and neon skylines."),
        ]),
        DemoChannel(id: "demo-news-41", name: "News 41", number: 41, clip: "demo-bars", shows: [
            Show(title: "News 41 at the Top", minutes: 30,
                 summary: "Headlines, weather, and one very good local-interest dog story."),
            Show(title: "Market Watch", minutes: 30,
                 summary: "The numbers that matter, delivered over soothing chart graphics."),
            Show(title: "Community Calendar", minutes: 30,
                 summary: "Everything happening this week, including the swap meet."),
            Show(title: "News 41 Update", minutes: 30,
                 summary: "A quick check-in so you never miss a beat."),
        ]),
    ]

    static var asChannels: [Channel] {
        channels.map { Channel(id: $0.id, name: $0.name, number: $0.number, icon: nil, groupTitle: nil) }
    }

    /// Sample "around the house" readings for the weather channel's third page.
    static let houseSensors: [WeatherData.HouseSensor] = [
        .init(id: "demo-pool", name: "POOL", value: "84°"),
        .init(id: "demo-garage", name: "GARAGE", value: "91°"),
        .init(id: "demo-wine", name: "WINE FRIDGE", value: "55°"),
    ]

    /// Demo weather location when none is configured (Cupertino, CA).
    static let fallbackCoordinate = (latitude: 37.323, longitude: -122.032)

    // MARK: - Demo synthetic-channel content
    //
    // Fake, self-generated images (no real Home Assistant / Immich instance)
    // so the cameras, photos, and dashboard channels have something to show in
    // demo mode and App Store screenshots. Bundled under Resources/.

    struct DemoCamera { let id: String; let name: String; let image: String }

    static let demoCameras: [DemoCamera] = [
        .init(id: "demo-cam-0", name: "FRONT DOOR", image: "demo-cam-0"),
        .init(id: "demo-cam-1", name: "BACKYARD", image: "demo-cam-1"),
        .init(id: "demo-cam-2", name: "DRIVEWAY", image: "demo-cam-2"),
        .init(id: "demo-cam-3", name: "SIDE GATE", image: "demo-cam-3"),
    ]
    static var demoCameraIds: [String] { demoCameras.map(\.id) }
    static func demoCamera(_ id: String) -> DemoCamera? { demoCameras.first { $0.id == id } }

    static let demoPhotos = [
        "demo-photo-1", "demo-photo-2", "demo-photo-3",
        "demo-photo-4", "demo-photo-5", "demo-photo-6",
    ]
    static let demoDashboard = "demo-dashboard"

    /// Loads a bundled demo image (loose Resource file, not an asset catalog).
    static func demoImage(_ name: String, ext: String = "jpg") -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func clipURL(for channel: Channel) -> URL? {
        guard let spec = channels.first(where: { $0.id == channel.id }) else { return nil }
        return Bundle.main.url(forResource: spec.clip, withExtension: "mp4")
    }

    /// Deterministic guide: each channel's schedule block tiles forward from
    /// a fixed epoch, so entry ids stay stable across regenerations and
    /// program starts stay aligned to the quarter hour.
    static func guide(from: Date, to: Date) -> [String: [GuideEntry]] {
        var guide: [String: [GuideEntry]] = [:]
        for channel in channels {
            guide[channel.id] = entries(for: channel, from: from, to: to)
        }
        return guide
    }

    private static func entries(for channel: DemoChannel, from: Date, to: Date) -> [GuideEntry] {
        let cycleSeconds = TimeInterval(channel.shows.reduce(0) { $0 + $1.minutes } * 60)
        guard cycleSeconds > 0 else { return [] }
        var t = floor(from.timeIntervalSince1970 / cycleSeconds) * cycleSeconds
        var entries: [GuideEntry] = []
        while t < to.timeIntervalSince1970 {
            for show in channel.shows {
                let start = Date(timeIntervalSince1970: t)
                let stop = start.addingTimeInterval(TimeInterval(show.minutes * 60))
                if stop > from && start < to {
                    entries.append(GuideEntry(
                        id: "\(channel.id)-\(Int(t))",
                        channelId: channel.id,
                        start: start,
                        stop: stop,
                        kind: .content,
                        title: show.title,
                        subtitle: show.subtitle,
                        summary: show.summary,
                        year: show.year,
                        episodeLabel: show.episodeLabel
                    ))
                }
                t = stop.timeIntervalSince1970
                if t >= to.timeIntervalSince1970 { break }
            }
        }
        return entries
    }
}
