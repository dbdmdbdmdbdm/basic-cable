import Foundation

struct ImmichAsset: Identifiable, Decodable, Hashable {
    let id: String
    let localDateTime: String?
    let exifInfo: ExifInfo?

    struct ExifInfo: Decodable, Hashable {
        let exifImageWidth: Int?
        let exifImageHeight: Int?
        let orientation: String?

        enum CodingKeys: String, CodingKey { case exifImageWidth, exifImageHeight, orientation }

        init(from decoder: Decoder) throws {
            // Widths arrive as Int or Double, orientation as String or Int,
            // depending on Immich version — decode defensively.
            let container = try decoder.container(keyedBy: CodingKeys.self)
            func int(_ key: CodingKeys) -> Int? {
                if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
                if let value = try? container.decodeIfPresent(Double.self, forKey: key) { return Int(value) }
                return nil
            }
            exifImageWidth = int(.exifImageWidth)
            exifImageHeight = int(.exifImageHeight)
            if let text = try? container.decodeIfPresent(String.self, forKey: .orientation) {
                orientation = text
            } else if let number = try? container.decodeIfPresent(Int.self, forKey: .orientation) {
                orientation = String(number)
            } else {
                orientation = nil
            }
        }
    }

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

    /// Taller than wide, accounting for EXIF rotation (5–8 swap the axes).
    /// Unknown dimensions read as landscape so the photo shows solo.
    var isPortrait: Bool {
        guard let exif = exifInfo,
              let width = exif.exifImageWidth, let height = exif.exifImageHeight,
              width > 0, height > 0 else { return false }
        let rotated = ["5", "6", "7", "8"].contains(exif.orientation ?? "")
        return rotated ? width > height : height > width
    }

    /// 1...365 from the capture date (leap days fold into March 1) —
    /// used for the on-this-day seasonal weighting.
    var dayOfYear: Int? {
        guard let localDateTime, localDateTime.count >= 10,
              let month = Int(localDateTime.dropFirst(5).prefix(2)),
              let day = Int(localDateTime.dropFirst(8).prefix(2)),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        let cumulative = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
        return cumulative[month - 1] + day
    }

    /// Weighted shuffle for the slideshow: photos taken within two weeks
    /// of today's calendar date (in any year) surface up to 3x as often —
    /// holidays and anniversaries gently resurface in season.
    static func seasonalShuffle(_ assets: [ImmichAsset], around today: Date = Date()) -> [ImmichAsset] {
        let todayDay = Calendar.current.ordinality(of: .day, in: .year, for: today) ?? 1
        func weight(_ asset: ImmichAsset) -> Double {
            guard let day = asset.dayOfYear else { return 1 }
            let distance = min(abs(day - todayDay), 365 - abs(day - todayDay))
            guard distance <= 14 else { return 1 }
            return 1 + 2 * (Double(14 - distance) / 14)
        }
        // Efraimidis–Spirakis weighted sampling without replacement.
        return assets
            .map { ($0, pow(Double.random(in: 0.0001...1), 1 / weight($0))) }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
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
        var withExif = true
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
