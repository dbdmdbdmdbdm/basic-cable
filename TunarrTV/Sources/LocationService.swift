import Foundation
import CoreLocation

/// One-shot device location for tvOS (WiFi-based, city-level accuracy —
/// plenty for a weather forecast).
final class DeviceLocation: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D?, Never>?

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestOnce() async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { cont in
            guard continuation == nil else {
                cont.resume(returning: nil)
                return
            }
            continuation = cont
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways:
                manager.requestLocation()
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
                // continues in locationManagerDidChangeAuthorization
            default:
                finish(nil)
            }
        }
    }

    private func finish(_ coordinate: CLLocationCoordinate2D?) {
        continuation?.resume(returning: coordinate)
        continuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(nil)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        finish(locations.first?.coordinate)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}

enum LocationResolver {
    /// Accepts "lat, lon", a zip/postal code, or a city name.
    /// Geocoding results are cached so CLGeocoder is hit once per input.
    static func resolve(_ text: String) async -> (latitude: Double, longitude: Double)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ",").compactMap {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        if parts.count == 2 {
            return (parts[0], parts[1])
        }

        let cacheKey = "geocode:\(trimmed.lowercased())"
        if let cached = UserDefaults.standard.string(forKey: cacheKey) {
            let cachedParts = cached.split(separator: ",").compactMap { Double($0) }
            if cachedParts.count == 2 { return (cachedParts[0], cachedParts[1]) }
        }

        guard let placemark = try? await CLGeocoder().geocodeAddressString(trimmed).first,
              let location = placemark.location else { return nil }
        let coordinate = location.coordinate
        UserDefaults.standard.set("\(coordinate.latitude),\(coordinate.longitude)", forKey: cacheKey)
        return (coordinate.latitude, coordinate.longitude)
    }

    /// "City, ST" (or the closest available) for a coordinate, cached so
    /// CLGeocoder is hit once per ~1km cell.
    static func name(latitude: Double, longitude: Double) async -> String? {
        let cacheKey = String(format: "revgeo:%.2f,%.2f", latitude, longitude)
        if let cached = UserDefaults.standard.string(forKey: cacheKey) {
            return cached.isEmpty ? nil : cached
        }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else {
            return nil  // transient failure — leave uncached so we retry
        }
        var name: String?
        if let city = placemark.locality {
            if let region = placemark.administrativeArea ?? placemark.isoCountryCode {
                name = "\(city), \(region)"
            } else {
                name = city
            }
        } else {
            name = placemark.administrativeArea ?? placemark.name
        }
        UserDefaults.standard.set(name ?? "", forKey: cacheKey)
        return name
    }
}
