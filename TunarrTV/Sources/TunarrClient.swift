import Foundation

struct TunarrClient {
    let baseURL: URL

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init?(baseURLString: String) {
        let trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        baseURL = url
    }

    func fetchChannels() async throws -> [Channel] {
        let url = baseURL.appendingPathComponent("api/channels")
        let (data, _) = try await URLSession.shared.data(from: url)
        let channels = try JSONDecoder().decode([Channel].self, from: data)
        return channels
            .sorted { $0.number < $1.number }
    }

    func fetchGuide(from: Date, to: Date) async throws -> [String: [GuideEntry]] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/guide/channels"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "dateFrom", value: Self.isoFormatter.string(from: from)),
            URLQueryItem(name: "dateTo", value: Self.isoFormatter.string(from: to)),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let raw = try JSONDecoder().decode([String: RawGuideChannel].self, from: data)

        var guide: [String: [GuideEntry]] = [:]
        for (channelId, rawChannel) in raw {
            let entries = rawChannel.programs
                .compactMap { GuideEntry(raw: $0, channelId: channelId, channelName: rawChannel.name) }
                .sorted { $0.start < $1.start }
            guide[channelId] = entries
        }
        return guide
    }

    func streamURL(for channel: Channel) -> URL {
        baseURL.appendingPathComponent("stream/channels/\(channel.id).m3u8")
    }

    func fetchVersion() async throws -> String {
        struct VersionResponse: Decodable { let tunarr: String }
        let url = baseURL.appendingPathComponent("api/version")
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(VersionResponse.self, from: data).tunarr
    }
}
