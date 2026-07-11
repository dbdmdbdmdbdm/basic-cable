import Foundation

/// Constants for the client-side synthetic weather channel.
enum WeatherChannel {
    static let id = "weather-local"
    static let number = 999
}

struct Channel: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let number: Int
    let icon: ChannelIcon?
    let groupTitle: String?

    struct ChannelIcon: Decodable, Hashable {
        let path: String?
    }

    /// Trims templated boilerplate from channel names so the guide column
    /// reads at a glance: "Directed by X" → "X", "Best of X" → "X",
    /// "X Marathon" → "X".
    static func displayName(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespaces)
        for prefix in ["directed by ", "best of "] where name.lowercased().hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            break
        }
        if name.lowercased().hasSuffix(" marathon") {
            name = String(name.dropLast(" marathon".count))
        }
        return name.trimmingCharacters(in: .whitespaces)
    }
}

struct GuideEntry: Identifiable, Hashable {
    let id: String
    let channelId: String
    let start: Date
    let stop: Date
    let kind: Kind
    let title: String
    let subtitle: String?
    let summary: String?
    let year: Int?
    let episodeLabel: String?

    enum Kind: Hashable {
        case content
        case flex
        case weather
        case other
    }

    var isFlex: Bool { kind == .flex }

    func airs(at date: Date) -> Bool {
        date >= start && date < stop
    }
}

// MARK: - Raw guide decoding

struct RawGuideChannel: Decodable {
    let id: String
    let name: String
    let number: Int
    let programs: [RawGuideProgram]
}

struct RawGuideProgram: Decodable {
    let type: String?
    let id: String?
    let start: Double?
    let stop: Double?
    let duration: Double?
    let program: RawProgram?
}

struct RawProgram: Decodable {
    let title: String?
    let type: String?
    let episodeNumber: Int?
    let year: Int?
    let summary: String?
    let show: RawShow?
    let season: RawSeason?

    struct RawShow: Decodable {
        let title: String?

        init(from decoder: Decoder) throws {
            // `show` may be an object, a string id, or absent — decode defensively.
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                title = try? container.decodeIfPresent(String.self, forKey: .title)
            } else {
                title = nil
            }
        }

        enum CodingKeys: String, CodingKey { case title }
    }

    struct RawSeason: Decodable {
        let index: Int?

        init(from decoder: Decoder) throws {
            if let container = try? decoder.container(keyedBy: CodingKeys.self) {
                index = try? container.decodeIfPresent(Int.self, forKey: .index)
            } else {
                index = nil
            }
        }

        enum CodingKeys: String, CodingKey { case index }
    }
}

extension GuideEntry {
    init?(raw: RawGuideProgram, channelId: String, channelName: String) {
        guard let startMs = raw.start else { return nil }
        let stopMs = raw.stop ?? (startMs + (raw.duration ?? 0))
        guard stopMs > startMs else { return nil }

        let start = Date(timeIntervalSince1970: startMs / 1000)
        let stop = Date(timeIntervalSince1970: stopMs / 1000)

        switch raw.type {
        case "content":
            let program = raw.program
            let showTitle = program?.show?.title
            let episodeTitle = program?.title
            let isEpisode = program?.type == "episode"

            let title: String
            let subtitle: String?
            if isEpisode, let showTitle, !showTitle.isEmpty {
                title = showTitle
                subtitle = episodeTitle
            } else {
                title = episodeTitle ?? channelName
                subtitle = nil
            }

            var episodeLabel: String?
            if let ep = program?.episodeNumber {
                if let season = program?.season?.index {
                    episodeLabel = "S\(season) E\(ep)"
                } else {
                    episodeLabel = "E\(ep)"
                }
            }

            self.init(
                id: "\(raw.id ?? "p")-\(Int(startMs))",
                channelId: channelId,
                start: start,
                stop: stop,
                kind: .content,
                title: title,
                subtitle: subtitle,
                summary: program?.summary,
                year: program?.year,
                episodeLabel: episodeLabel
            )
        case "flex":
            self.init(
                id: "flex-\(channelId)-\(Int(startMs))",
                channelId: channelId,
                start: start,
                stop: stop,
                kind: .flex,
                title: "OFF AIR",
                subtitle: nil,
                summary: nil,
                year: nil,
                episodeLabel: nil
            )
        default:
            self.init(
                id: "\(raw.id ?? raw.type ?? "x")-\(Int(startMs))",
                channelId: channelId,
                start: start,
                stop: stop,
                kind: .other,
                title: raw.program?.title ?? channelName,
                subtitle: nil,
                summary: raw.program?.summary,
                year: raw.program?.year,
                episodeLabel: nil
            )
        }
    }
}
