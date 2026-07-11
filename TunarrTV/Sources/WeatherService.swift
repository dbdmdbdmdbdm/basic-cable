import Foundation
import UIKit

struct WeatherData {
    struct Current {
        let temperature: Double
        let feelsLike: Double
        let humidity: Int
        let windSpeed: Double
        let windDirection: Double
        let code: Int
    }

    struct Day: Identifiable {
        let id: String
        let date: Date
        let code: Int
        let high: Double
        let low: Double
        let precipChance: Int
    }

    struct HouseSensor: Identifiable {
        let id: String
        let name: String
        let value: String
    }

    var current: Current?
    var days: [Day] = []
    var houseSensors: [HouseSensor] = []
    /// "City, ST" for the forecast coordinates (reverse-geocoded, cached).
    var locationName: String?
    var fetchedAt = Date.distantPast

    var hasForecast: Bool { current != nil && !days.isEmpty }
}

/// WMO weather interpretation codes (used by Open-Meteo).
enum WMO {
    static func description(_ code: Int) -> String {
        switch code {
        case 0: return "CLEAR"
        case 1: return "MOSTLY CLEAR"
        case 2: return "PARTLY CLOUDY"
        case 3: return "CLOUDY"
        case 45, 48: return "FOGGY"
        case 51...57: return "DRIZZLE"
        case 61...67: return "RAIN"
        case 71...77: return "SNOW"
        case 80...82: return "SHOWERS"
        case 85, 86: return "SNOW SHOWERS"
        case 95...99: return "THUNDERSTORMS"
        default: return "—"
        }
    }

    static func symbol(_ code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1: return "sun.max.fill"
        case 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67: return "cloud.rain.fill"
        case 71...77: return "cloud.snow.fill"
        case 80...82: return "cloud.heavyrain.fill"
        case 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "questionmark"
        }
    }

    static func compass(_ degrees: Double) -> String {
        let dirs = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int((degrees + 22.5) / 45.0) % 8
        return dirs[index]
    }
}

/// Free, keyless forecast API — https://open-meteo.com
struct OpenMeteoClient {
    func fetch(latitude: Double, longitude: Double) async throws -> (WeatherData.Current, [WeatherData.Day]) {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m,wind_direction_10m"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "7"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let response = try JSONDecoder().decode(Response.self, from: data)

        let current = WeatherData.Current(
            temperature: response.current.temperature_2m,
            feelsLike: response.current.apparent_temperature,
            humidity: response.current.relative_humidity_2m,
            windSpeed: response.current.wind_speed_10m,
            windDirection: response.current.wind_direction_10m,
            code: response.current.weather_code
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current

        var days: [WeatherData.Day] = []
        for (index, dayString) in response.daily.time.enumerated() {
            guard let date = formatter.date(from: dayString),
                  index < response.daily.weather_code.count,
                  index < response.daily.temperature_2m_max.count,
                  index < response.daily.temperature_2m_min.count else { continue }
            days.append(WeatherData.Day(
                id: dayString,
                date: date,
                code: response.daily.weather_code[index],
                high: response.daily.temperature_2m_max[index],
                low: response.daily.temperature_2m_min[index],
                precipChance: index < (response.daily.precipitation_probability_max?.count ?? 0)
                    ? (response.daily.precipitation_probability_max?[index] ?? 0)
                    : 0
            ))
        }
        return (current, days)
    }

    private struct Response: Decodable {
        let current: Current
        let daily: Daily

        struct Current: Decodable {
            let temperature_2m: Double
            let relative_humidity_2m: Int
            let apparent_temperature: Double
            let weather_code: Int
            let wind_speed_10m: Double
            let wind_direction_10m: Double
        }

        struct Daily: Decodable {
            let time: [String]
            let weather_code: [Int]
            let temperature_2m_max: [Double]
            let temperature_2m_min: [Double]
            let precipitation_probability_max: [Int]?
        }
    }
}

/// Optional Home Assistant integration: supplies the server's configured
/// lat/lon and live readings from local sensor entities.
struct HAClient {
    let baseURL: URL
    let token: String

    init?(urlString: String, token: String) {
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedToken.isEmpty,
              let url = URL(string: trimmedURL), url.scheme != nil else { return nil }
        baseURL = url
        self.token = trimmedToken
    }

    private func request(path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5
        return request
    }

    enum HAError: Error {
        case unauthorized
        case unreachable
    }

    /// One-line identity check for the settings TEST button:
    /// "HA 2026.7 · HOME". 401/403 → bad token; anything else → unreachable.
    func fetchConfigSummary() async throws -> String {
        struct Config: Decodable {
            let version: String?
            let location_name: String?
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request(path: "api/config")) else {
            throw HAError.unreachable
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw HAError.unauthorized }
        guard status == 200, let config = try? JSONDecoder().decode(Config.self, from: data) else {
            throw HAError.unreachable
        }
        var summary = "HA \(config.version ?? "?")"
        if let name = config.location_name, !name.isEmpty {
            summary += " · \(name.uppercased())"
        }
        return summary
    }

    struct EntitySummary {
        let entityId: String
        let name: String?
        let state: String
        let unit: String?
        let deviceClass: String?
    }

    /// Every entity's id/state/attributes — used to suggest sensor and
    /// camera entities in settings.
    func fetchEntitySummaries() async throws -> [EntitySummary] {
        struct RawState: Decodable {
            let entity_id: String
            let state: String
            let attributes: Attrs
            struct Attrs: Decodable {
                let friendly_name: String?
                let unit_of_measurement: String?
                let device_class: String?
            }
        }
        var request = request(path: "api/states")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HAError.unreachable }
        return try JSONDecoder().decode([RawState].self, from: data).map {
            EntitySummary(entityId: $0.entity_id, name: $0.attributes.friendly_name,
                          state: $0.state, unit: $0.attributes.unit_of_measurement,
                          deviceClass: $0.attributes.device_class)
        }
    }

    struct NowPlayingItem: Hashable {
        let title: String
        let artist: String?
        /// Every player carrying this same stream — grouped speakers show
        /// as one entry with a count, not one entry per room.
        let players: [String]
    }

    /// What the given media players are playing right now, consolidated:
    /// players on the same title+artist collapse into one item that lists
    /// all of them.
    func fetchNowPlaying(_ entityIds: [String]) async -> [NowPlayingItem] {
        struct EntityState: Decodable {
            let state: String
            let attributes: Attributes
            struct Attributes: Decodable {
                let friendly_name: String?
                let media_title: String?
                let media_artist: String?
            }
        }
        var groups: [(key: String, title: String, artist: String?, players: [String])] = []
        for entityId in entityIds {
            guard let (data, response) = try? await URLSession.shared.data(for: request(path: "api/states/\(entityId)")),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let entity = try? JSONDecoder().decode(EntityState.self, from: data),
                  entity.state == "playing",
                  let title = entity.attributes.media_title, !title.isEmpty else { continue }
            let player = entity.attributes.friendly_name ?? entityId
            let key = "\(title)|\(entity.attributes.media_artist ?? "")"
            if let index = groups.firstIndex(where: { $0.key == key }) {
                groups[index].players.append(player)
            } else {
                groups.append((key, title, entity.attributes.media_artist, [player]))
            }
        }
        return groups.map { NowPlayingItem(title: $0.title, artist: $0.artist, players: $0.players) }
    }

    func entityExists(_ entityId: String) async -> Bool {
        guard let (_, response) = try? await URLSession.shared.data(for: request(path: "api/states/\(entityId)")) else {
            return false
        }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    /// Still frame via /api/camera_proxy — used as the TEST preview.
    func fetchCameraStill(_ entityId: String) async -> UIImage? {
        var request = request(path: "api/camera_proxy/\(entityId)")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return UIImage(data: data)
    }

    func fetchLocation() async throws -> (latitude: Double, longitude: Double) {
        struct Config: Decodable {
            let latitude: Double
            let longitude: Double
        }
        let (data, _) = try await URLSession.shared.data(for: request(path: "api/config"))
        let config = try JSONDecoder().decode(Config.self, from: data)
        return (config.latitude, config.longitude)
    }

    /// Fetches each entity's state; entities that fail are skipped.
    func fetchSensors(_ entityIds: [String]) async -> [WeatherData.HouseSensor] {
        struct EntityState: Decodable {
            let state: String
            let attributes: Attributes
            struct Attributes: Decodable {
                let friendly_name: String?
                let unit_of_measurement: String?
            }
        }

        var sensors: [WeatherData.HouseSensor] = []
        for entityId in entityIds {
            guard let (data, _) = try? await URLSession.shared.data(for: request(path: "api/states/\(entityId)")),
                  let entity = try? JSONDecoder().decode(EntityState.self, from: data),
                  entity.state != "unavailable", entity.state != "unknown" else { continue }

            var value = entity.state
            // Round numeric readings to one decimal for display.
            if let number = Double(value) {
                value = number.truncatingRemainder(dividingBy: 1) == 0
                    ? String(Int(number))
                    : String(format: "%.1f", number)
            }
            if let unit = entity.attributes.unit_of_measurement {
                value += unit.hasPrefix("°") ? unit : " \(unit)"
            }
            sensors.append(WeatherData.HouseSensor(
                id: entityId,
                name: (entity.attributes.friendly_name ?? entityId).uppercased(),
                value: value
            ))
        }
        return sensors
    }
}
