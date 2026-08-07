import Foundation

/// Shared container between the tvOS app and its Top Shelf extension —
/// the app mirrors the settings the extension needs (server URL,
/// favorites) into these defaults.
enum AppGroup {
    static let identifier = "group.com.dbdm.tunarrtv"
    static var defaults: UserDefaults? { UserDefaults(suiteName: identifier) }
}
