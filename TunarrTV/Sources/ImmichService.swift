import Foundation

struct ImmichAsset: Identifiable, Decodable, Hashable {
    let id: String
    let localDateTime: String?

    /// "JULY 2026" — a retro date stamp for the slideshow overlay.
    var displayDate: String? {
        guard let localDateTime, localDateTime.count >= 7,
              let year = Int(localDateTime.prefix(4)),
              let month = Int(localDateTime.dropFirst(5).prefix(2)),
              (1...12).contains(month) else { return nil }
        let names = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE",
                     "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"]
        return "\(names[month - 1]) \(year)"
    }
}

/// Optional Immich integration: feeds the synthetic photos channel with the
/// user's favorite photos. Auth is an Immich API key sent as x-api-key.
struct ImmichClient {
    let baseURL: URL
    let apiKey: String

    init?(urlString: String, apiKey: String) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedKey.isEmpty,
              let url = URL(string: trimmedURL), url.scheme != nil else { return nil }
        baseURL = url
        self.apiKey = trimmedKey
    }

    /// All favorite photos (videos excluded), paginated defensively.
    func fetchFavorites() async throws -> [ImmichAsset] {
        var all: [ImmichAsset] = []
        for page in 1...5 {
            var request = URLRequest(url: baseURL.appendingPathComponent("api/search/metadata"))
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 15
            request.httpBody = try JSONEncoder().encode(SearchBody(page: page))
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
            all += decoded.assets.items
            if decoded.assets.nextPage == nil { break }
        }
        return all
    }

    func imageRequest(for asset: ImmichAsset) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/assets/\(asset.id)/thumbnail"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "size", value: "preview")]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.timeoutInterval = 15
        return request
    }

    private struct SearchBody: Encodable {
        var isFavorite = true
        var type = "IMAGE"
        var size = 1000
        var page: Int
    }

    private struct SearchResponse: Decodable {
        let assets: Assets

        struct Assets: Decodable {
            let items: [ImmichAsset]
            let nextPage: String?

            enum CodingKeys: String, CodingKey { case items, nextPage }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                items = try container.decode([ImmichAsset].self, forKey: .items)
                // nextPage is a string in current Immich, but decode
                // defensively — a number here shouldn't kill the channel.
                if let text = try? container.decode(String.self, forKey: .nextPage) {
                    nextPage = text
                } else if let number = try? container.decode(Int.self, forKey: .nextPage) {
                    nextPage = String(number)
                } else {
                    nextPage = nil
                }
            }
        }
    }
}
