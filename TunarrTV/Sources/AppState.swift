import Foundation
import AVFoundation
import Combine
import CryptoKit
import UIKit

@MainActor
final class AppState: ObservableObject {
    static let windowMinutes = 120
    static let pageMinutes = 30
    static let fetchHours = 12

    static let weatherChannelId = WeatherChannel.id
    static let photosChannelId = PhotosChannel.id
    static let camerasChannelId = CamerasChannel.id

    /// Client-rendered channels — no Tunarr stream behind them. Dashboard
    /// channels match by prefix ("hadash-local", "hadash-local-1", …).
    static func isSyntheticChannel(_ id: String) -> Bool {
        id == weatherChannelId || id == photosChannelId || id == camerasChannelId
            || id.hasPrefix(HADashboardChannel.id)
    }

    @Published var serverURLString: String {
        didSet { persist(serverURLString, forKey: "serverURL") }
    }
    @Published var manualLocation: String {
        didSet { persist(manualLocation, forKey: "manualLocation") }
    }
    @Published var haURLString: String {
        didSet { persist(haURLString, forKey: "haURL") }
    }
    @Published var haToken: String {
        didSet { persist(haToken, forKey: "haToken") }
    }
    @Published var haSensorEntities: String {
        didSet { persist(haSensorEntities, forKey: "haSensorEntities") }
    }
    /// Optional `weather.*` entity — when set, the weather channel's
    /// forecast comes from Home Assistant instead of Open-Meteo.
    @Published var haWeatherEntity: String {
        didSet { persist(haWeatherEntity, forKey: "haWeatherEntity") }
    }
    @Published var haCameraEntities: String {
        didSet { persist(haCameraEntities, forKey: "haCameraEntities") }
    }
    /// Cameras toggled off in settings — hidden from the grid without
    /// losing their place in the configured list.
    @Published var hiddenCameraIds: Set<String> {
        didSet { persist(hiddenCameraIds.sorted().joined(separator: ","), forKey: "hiddenCameras") }
    }
    @Published var dashImageURLString: String {
        didSet { persist(dashImageURLString, forKey: "dashImageURL") }
    }
    @Published var immichURLString: String {
        didSet { persist(immichURLString, forKey: "immichURL") }
    }
    @Published var immichAPIKey: String {
        didSet { persist(immichAPIKey, forKey: "immichKey") }
    }
    /// Media players feeding the ticker's now-playing side.
    @Published var mediaPlayerEntities: String {
        didSet { persist(mediaPlayerEntities, forKey: "mediaPlayerEntities") }
    }
    /// The bottom ticker, global across every channel — flip it on from
    /// the player and it rides along while zapping until turned off.
    @Published var tickerEnabled: Bool {
        didSet { persist(tickerEnabled ? "true" : "false", forKey: "tickerEnabled") }
    }
    /// Album feeding the photos channel; empty = favorites (the default).
    @Published var immichAlbumId: String {
        didSet { persist(immichAlbumId, forKey: "immichAlbumId") }
    }
    @Published var immichAlbumName: String {
        didSet { persist(immichAlbumName, forKey: "immichAlbumName") }
    }
    /// Current-conditions badge over the photos / cameras channels.
    /// Persisted as "true"/"false" strings to ride the same sync plumbing
    /// as the text settings.
    @Published var weatherOverlayOnPhotos: Bool {
        didSet { persist(weatherOverlayOnPhotos ? "true" : "false", forKey: "weatherOverlayPhotos") }
    }
    @Published var weatherOverlayOnCameras: Bool {
        didSet { persist(weatherOverlayOnCameras ? "true" : "false", forKey: "weatherOverlayCameras") }
    }
    /// Mirror settings through iCloud key-value storage so configuring the
    /// iPhone app configures the Apple TV app (and vice versa).
    @Published var iCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: "iCloudSyncEnabled")
            if iCloudSyncEnabled { pushAllToCloud() }
        }
    }
    @Published var weatherData = WeatherData()

    @Published private(set) var channels: [Channel] = []
    @Published private(set) var guide: [String: [GuideEntry]] = [:]
    @Published private(set) var tunedChannel: Channel?
    @Published var focusedEntry: GuideEntry?
    @Published var windowStart: Date
    @Published var now: Date = Date()
    // Launch into fullscreen playing the last channel, like turning on a TV.
    @Published var isFullscreen = true
    @Published var showSettings = false
    @Published var isPaused = false
    @Published var loadError: String?
    @Published var isBuffering = false
    @Published var isServerReachable = true
    /// Set once tune retries exhaust: names WHY the channel won't start so
    /// the static screen can say "server busy" instead of leaving dead air.
    enum StreamTrouble { case unreachable, busy }
    @Published var streamTrouble: StreamTrouble?
    /// Demo mode: canned lineup + bundled looping clips, no server needed.
    @Published private(set) var isDemoMode = false

    private var missedHeartbeats = 0
    private var demoLoopObserver: NSObjectProtocol?

    let player: AVPlayer = {
        let player = AVPlayer()
        // Let AVPlayer hand video off to AirPlay (Apple TV / AirPlay 2) when
        // the user picks a route. Default is already true on iOS; set it
        // explicitly so the intent is clear and survives SDK default changes.
        player.allowsExternalPlayback = true
        return player
    }()
    let deviceLocation = DeviceLocation()

    /// Cameras channel spotlight: index into `visibleCameraIds` of the camera
    /// shown large (with the others as a side filmstrip), or nil for the grid.
    @Published var cameraSpotlight: Int?

    /// Move the spotlight focus by `delta`, wrapping; entering the spotlight
    /// from the grid (nil) lands on the first camera going right, last going left.
    func cameraSpotlightMove(_ delta: Int) {
        let count = visibleCameraIds.count
        guard count > 0 else { cameraSpotlight = nil; return }
        let current = cameraSpotlight ?? (delta >= 0 ? -1 : 0)
        cameraSpotlight = ((current + delta) % count + count) % count
    }

    func cameraSpotlightFocus(_ index: Int) {
        guard index >= 0, index < visibleCameraIds.count else { return }
        cameraSpotlight = index
    }

    func cameraSpotlightExit() { cameraSpotlight = nil }

    #if os(iOS)
    /// Chromecast sender (open-source CASTV2, no Google SDK). iOS/iPad only.
    let cast = CastController()

    /// The live HLS URL for the tuned channel, or nil when there's nothing to
    /// cast — a synthetic channel, demo mode, or no server configured.
    var castableStreamURL: URL? {
        guard !isDemoMode, let channel = tunedChannel,
              !Self.isSyntheticChannel(channel.id), let client else { return nil }
        return client.streamURL(for: channel)
    }

    /// A human title for the cast receiver ("CHANNEL · PROGRAM").
    var castableChannelTitle: String {
        guard let channel = tunedChannel else { return "Basic Cable" }
        if let program = nowPlaying(on: channel)?.title {
            return "\(channel.name) · \(program)"
        }
        return channel.name
    }
    #endif

    private var refreshTask: Task<Void, Never>?
    private var guideFetchedThrough: Date = .distantPast
    private var prefetchTask: Task<Void, Never>?
    private var lastPrefetchedChannelId: String?
    private var itemFailureWatch: AnyCancellable?
    private var pendingTune: Task<Void, Never>?
    private var retryCount = 0
    private var bufferingSince: Date?

    // The grid never shows more than ~15 min of the past: it starts at the
    // last quarter-hour and auto-advances, keeping the now-line near the left.
    var earliestWindowStart: Date { Self.floorToQuarterHour(Date()) }
    var windowEnd: Date { windowStart.addingTimeInterval(TimeInterval(Self.windowMinutes * 60)) }

    var client: TunarrClient? { TunarrClient(baseURLString: serverURLString) }

    var isConfigured: Bool {
        !serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && client != nil
    }

    /// The app works without Tunarr: any configured synthetic channel (or a
    /// weather location) is enough to run on the built-in lineup alone.
    var hasStandaloneConfig: Bool {
        !manualLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || haClient != nil
            || immichClient != nil
            || !dashboards.isEmpty
            || !cameraEntityIds.isEmpty
    }

    var isWeatherTuned: Bool { tunedChannel?.id == Self.weatherChannelId }
    var isDashboardTuned: Bool { tunedChannel?.id.hasPrefix(HADashboardChannel.id) == true }
    var isPhotosTuned: Bool { tunedChannel?.id == Self.photosChannelId }
    var isCamerasTuned: Bool { tunedChannel?.id == Self.camerasChannelId }
    var isSyntheticTuned: Bool {
        guard let id = tunedChannel?.id else { return false }
        return Self.isSyntheticChannel(id)
    }

    var haClient: HAClient? { HAClient(urlString: haURLString, token: haToken) }

    /// Camera entities configured for the security channel, in list order.
    var cameraEntityIds: [String] {
        haCameraEntities
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The cameras actually shown in the grid (configured minus hidden),
    /// in list order — the add-on config's order wins when present.
    var visibleCameraIds: [String] {
        effectiveCameraIds.filter { !hiddenCameraIds.contains($0) }
    }

    var mediaPlayerIds: [String] { Self.parseEntityList(mediaPlayerEntities) }

    // MARK: - Remote config (served by the ha-screencap add-on)

    /// Optional app config served by the ha-screencap add-on at /appconfig.
    /// When present, its lists override the on-device settings, so cameras,
    /// weather sensors, media players, and the ticker are all managed from
    /// Home Assistant.
    struct RemoteAppConfig: Decodable, Equatable {
        struct TickerEntity: Decodable, Equatable {
            let entity: String
            let name: String?
            let show_when: String?
            let color: String?
            let icon: String?
            let display: String?
        }
        struct Ticker: Decodable, Equatable {
            let scroll: Bool?
            let entities: [TickerEntity]?
        }
        struct Dashboard: Decodable, Equatable {
            let index: Int
            let name: String?
        }
        let dashboards: [Dashboard]?
        let cameras: [String]?
        let weather_sensors: [String]?
        let weather_entity: String?
        let media_players: [String]?
        let ticker: Ticker?
    }

    @Published private(set) var remoteConfig: RemoteAppConfig?
    /// The origin that served /appconfig — remote dashboards resolve to
    /// /latest/<index>.png on it.
    @Published private(set) var remoteConfigOrigin: URL?

    /// Probes each configured dashboard origin for /appconfig — the add-on
    /// that serves the snapshots also serves the app config.
    func refreshRemoteConfig() async {
        var origins: [URL] = []
        // Probe the on-device snapshot URLs (not the effective list —
        // that would be circular once remote dashboards take over).
        for dashboard in Self.parseDashboards(dashImageURLString) {
            guard var components = URLComponents(url: dashboard.url, resolvingAgainstBaseURL: false) else { continue }
            components.path = "/appconfig"
            components.query = nil
            if let url = components.url, !origins.contains(url) { origins.append(url) }
        }
        for url in origins {
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 5
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let config = try? JSONDecoder().decode(RemoteAppConfig.self, from: data) {
                var origin = URLComponents(url: url, resolvingAgainstBaseURL: false)
                origin?.path = ""
                if config != remoteConfig { remoteConfig = config }
                remoteConfigOrigin = origin?.url
                return
            }
        }
        if remoteConfig != nil { remoteConfig = nil }
        remoteConfigOrigin = nil
    }

    /// Non-empty remote lists win over the on-device fields.
    private static func override(_ remote: [String]?, _ local: [String]) -> [String] {
        guard let remote, !remote.isEmpty else { return local }
        return remote
    }

    var effectiveCameraIds: [String] { Self.override(remoteConfig?.cameras, cameraEntityIds) }
    var effectiveWeatherSensorIds: [String] {
        Self.override(remoteConfig?.weather_sensors, Self.parseEntityList(haSensorEntities))
    }
    var effectiveWeatherEntity: String {
        let remote = remoteConfig?.weather_entity?.trimmingCharacters(in: .whitespaces) ?? ""
        return remote.isEmpty ? haWeatherEntity.trimmingCharacters(in: .whitespaces) : remote
    }
    var effectiveMediaPlayerIds: [String] { Self.override(remoteConfig?.media_players, mediaPlayerIds) }
    var tickerScroll: Bool { remoteConfig?.ticker?.scroll ?? false }
    var tickerEntityConfigs: [RemoteAppConfig.TickerEntity] { remoteConfig?.ticker?.entities ?? [] }

    /// Now-playing across the configured media players, deduped.
    func fetchNowPlaying() async -> [HAClient.NowPlayingItem] {
        guard let ha = haClient, !effectiveMediaPlayerIds.isEmpty else { return [] }
        return await ha.fetchNowPlaying(effectiveMediaPlayerIds)
    }

    /// Extra ticker items from the add-on config: live entity states,
    /// optionally conditional (show_when), styled with a color and icon.
    struct TickerChip: Identifiable, Equatable {
        let id: String
        let text: String
        let icon: String
        let colorName: String?
    }

    func fetchTickerChips() async -> [TickerChip] {
        let configs = tickerEntityConfigs
        guard let ha = haClient, !configs.isEmpty else { return [] }
        var chips: [TickerChip] = []
        for config in configs {
            guard let state = await ha.fetchDisplayState(config.entity) else { continue }
            if let condition = config.show_when, !condition.isEmpty,
               state.state.lowercased() != condition.lowercased() { continue }
            let name = (config.name ?? state.name).uppercased()
            let value = state.state.replacingOccurrences(of: "_", with: " ").uppercased()
            let text: String
            switch config.display {
            case "name": text = name
            case "state": text = value
            default: text = "\(name) \(value)"
            }
            chips.append(TickerChip(id: config.entity, text: text,
                                    icon: config.icon ?? "circle.fill",
                                    colorName: config.color))
        }
        return chips
    }

    var immichClient: ImmichClient? { ImmichClient(urlString: immichURLString, apiKey: immichAPIKey) }

    struct DashboardConfig: Equatable {
        let name: String
        let url: URL
    }

    /// Dashboard channels. Normally parsed from the settings field
    /// (comma-separated snapshot URLs, optionally "NAME=URL"); when the
    /// add-on's app config lists dashboards, those win — each resolves to
    /// /latest/<index>.png on the add-on's origin. First keeps channel
    /// 998; extras count down from 996 (997 is photos). Capped at 8.
    var dashboards: [DashboardConfig] {
        if let remote = remoteConfig?.dashboards, !remote.isEmpty, let origin = remoteConfigOrigin {
            return remote.prefix(8).map { dashboard in
                let path = dashboard.index == 0 ? "latest.png" : "latest/\(dashboard.index).png"
                return DashboardConfig(name: dashboard.name ?? "",
                                       url: origin.appendingPathComponent(path))
            }
        }
        return Self.parseDashboards(dashImageURLString)
    }

    static func parseDashboards(_ text: String) -> [DashboardConfig] {
        var configs: [DashboardConfig] = []
        for entry in text.split(separator: ",") {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            var name = ""
            var urlText = trimmed
            // "NAME=URL" — but never split inside a bare URL's query string.
            if let eq = trimmed.firstIndex(of: "="), !trimmed[..<eq].contains("://") {
                name = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                urlText = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            }
            guard var url = URL(string: urlText), url.scheme != nil else { continue }
            // A bare server address ("http://ha:8090") means its default
            // snapshot — /latest.png is assumed.
            if url.path.isEmpty || url.path == "/" {
                url = url.appendingPathComponent("latest.png")
            }
            configs.append(DashboardConfig(name: name, url: url))
            if configs.count == 8 { break }
        }
        return configs
    }

    static func dashboardChannelId(index: Int) -> String {
        index == 0 ? HADashboardChannel.id : "\(HADashboardChannel.id)-\(index)"
    }

    static func dashboardChannelNumber(index: Int) -> Int {
        index == 0 ? HADashboardChannel.number : 996 - (index - 1)
    }

    /// The snapshot URL for the tuned dashboard channel, if one is tuned.
    var tunedDashboardURL: URL? {
        guard let id = tunedChannel?.id, id.hasPrefix(HADashboardChannel.id) else { return nil }
        let configs = dashboards
        guard !configs.isEmpty else { return nil }
        let index = Int(id.dropFirst(HADashboardChannel.id.count + 1)) ?? 0
        return configs.indices.contains(index) ? configs[index].url : configs[0].url
    }

    init() {
        let defaults = UserDefaults.standard
        let cloud = NSUbiquitousKeyValueStore.default
        let syncEnabled = defaults.object(forKey: "iCloudSyncEnabled") as? Bool ?? true
        iCloudSyncEnabled = syncEnabled
        cloud.synchronize()

        // Local value wins; an empty local slot adopts the iCloud value, so
        // a freshly installed Apple TV app inherits the iPhone's settings.
        func setting(_ key: String) -> String {
            if let local = defaults.string(forKey: key), !local.isEmpty { return local }
            if syncEnabled, let synced = cloud.string(forKey: key), !synced.isEmpty { return synced }
            return ""
        }
        serverURLString = setting("serverURL")
        manualLocation = setting("manualLocation")
        haURLString = setting("haURL")
        haToken = setting("haToken")
        haSensorEntities = setting("haSensorEntities")
        haWeatherEntity = setting("haWeatherEntity")
        haCameraEntities = setting("haCameraEntities")
        hiddenCameraIds = Set(
            setting("hiddenCameras")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        dashImageURLString = setting("dashImageURL")
        immichURLString = setting("immichURL")
        immichAPIKey = setting("immichKey")
        immichAlbumId = setting("immichAlbumId")
        immichAlbumName = setting("immichAlbumName")
        mediaPlayerEntities = setting("mediaPlayerEntities")
        // Migrates from the short-lived per-channel set: any channel
        // enabled means the global ticker starts on.
        tickerEnabled = setting("tickerEnabled") == "true"
            || !setting("tickerChannels").isEmpty
        weatherOverlayOnPhotos = setting("weatherOverlayPhotos") == "true"
        weatherOverlayOnCameras = setting("weatherOverlayCameras") == "true"
        windowStart = Self.floorToQuarterHour(Date())

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { [weak self] note in
            let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] ?? []
            Task { @MainActor [weak self] in
                self?.adoptCloudChanges(changed)
            }
        }
        player.preventsDisplaySleepDuringVideoPlayback = true
        // NOTE: automaticallyWaitsToMinimizeStalling stays TRUE — with it
        // disabled, a mid-play buffer underrun freezes the frame forever
        // instead of rebuffering. playImmediately() in tune() still gives
        // the fast initial start.
        //
        // isBuffering tracks timeControlStatus, NOT isPlaybackLikelyToKeepUp:
        // the latter can stay false indefinitely on live HLS while playback
        // runs fine, which left the TUNING static stuck over live video.
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .map { $0 == .waitingToPlayAtSpecifiedRate }
            .assign(to: &$isBuffering)
    }

    // MARK: - Settings persistence & iCloud sync

    private func persist(_ value: String, forKey key: String) {
        UserDefaults.standard.set(value, forKey: key)
        if iCloudSyncEnabled {
            NSUbiquitousKeyValueStore.default.set(value, forKey: key)
        }
    }

    private func pushAllToCloud() {
        persist(serverURLString, forKey: "serverURL")
        persist(manualLocation, forKey: "manualLocation")
        persist(haURLString, forKey: "haURL")
        persist(haToken, forKey: "haToken")
        persist(haSensorEntities, forKey: "haSensorEntities")
        persist(haWeatherEntity, forKey: "haWeatherEntity")
        persist(haCameraEntities, forKey: "haCameraEntities")
        persist(hiddenCameraIds.sorted().joined(separator: ","), forKey: "hiddenCameras")
        persist(dashImageURLString, forKey: "dashImageURL")
        persist(immichURLString, forKey: "immichURL")
        persist(immichAPIKey, forKey: "immichKey")
        persist(immichAlbumId, forKey: "immichAlbumId")
        persist(immichAlbumName, forKey: "immichAlbumName")
        persist(mediaPlayerEntities, forKey: "mediaPlayerEntities")
        persist(tickerEnabled ? "true" : "false", forKey: "tickerEnabled")
        persist(weatherOverlayOnPhotos ? "true" : "false", forKey: "weatherOverlayPhotos")
        persist(weatherOverlayOnCameras ? "true" : "false", forKey: "weatherOverlayCameras")
    }

    // MARK: - Settings backup / restore / reset

    /// Every persisted settings key — backup, restore, and reset all walk
    /// this list, so a new setting only needs adding here (plus a case in
    /// applySetting).
    static let settingsKeys = [
        "serverURL", "manualLocation", "haURL", "haToken",
        "haSensorEntities", "haWeatherEntity", "haCameraEntities",
        "hiddenCameras", "dashImageURL", "immichURL", "immichKey",
        "immichAlbumId", "immichAlbumName", "mediaPlayerEntities",
        "tickerEnabled", "weatherOverlayPhotos", "weatherOverlayCameras",
    ]

    private func applySetting(_ key: String, _ value: String) {
        switch key {
        case "serverURL": serverURLString = value
        case "manualLocation": manualLocation = value
        case "haURL": haURLString = value
        case "haToken": haToken = value
        case "haSensorEntities": haSensorEntities = value
        case "haWeatherEntity": haWeatherEntity = value
        case "haCameraEntities": haCameraEntities = value
        case "hiddenCameras":
            hiddenCameraIds = Set(value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty })
        case "dashImageURL": dashImageURLString = value
        case "immichURL": immichURLString = value
        case "immichKey": immichAPIKey = value
        case "immichAlbumId": immichAlbumId = value
        case "immichAlbumName": immichAlbumName = value
        case "mediaPlayerEntities": mediaPlayerEntities = value
        case "tickerEnabled": tickerEnabled = value == "true"
        case "weatherOverlayPhotos": weatherOverlayOnPhotos = value == "true"
        case "weatherOverlayCameras": weatherOverlayOnCameras = value == "true"
        default: break
        }
    }

    func settingsSnapshot() -> [String: String] {
        var snapshot: [String: String] = [:]
        for key in Self.settingsKeys {
            if let value = UserDefaults.standard.string(forKey: key), !value.isEmpty {
                snapshot[key] = value
            }
        }
        return snapshot
    }

    // MARK: - Backup secret encryption
    //
    // The settings backup rides the add-on's /data (and therefore Home
    // Assistant's own backups, which propagate off-box to cloud storage) and
    // is served unauthenticated on the LAN. The powerful credentials in it —
    // the HA long-lived token and the Immich key — are therefore encrypted at
    // the app boundary with AES-GCM so the stored/served blob is opaque. The
    // symmetric key never leaves the user's own devices (on-device +
    // iCloud KVS, the same trust domain the settings already sync through), so
    // restore works across the user's devices; a device without the key simply
    // can't decrypt those two fields (both are user-regenerable) and leaves the
    // existing values untouched. Non-secret settings stay plaintext so a
    // config restore always works even without the key.

    /// Setting keys whose values are encrypted before leaving the device.
    static let secretSettingKeys: Set<String> = ["haToken", "immichKey"]
    private static let backupEncPrefix = "enc:v1:"
    private static let backupKeyDefaultsKey = "backupCryptoKey"

    /// Fetches (or lazily creates + syncs) the 256-bit backup key.
    private func backupCryptoKey() -> SymmetricKey {
        let stored = UserDefaults.standard.string(forKey: Self.backupKeyDefaultsKey)
            ?? NSUbiquitousKeyValueStore.default.string(forKey: Self.backupKeyDefaultsKey)
        if let b64 = stored, let data = Data(base64Encoded: b64), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let b64 = key.withUnsafeBytes { Data($0).base64EncodedString() }
        UserDefaults.standard.set(b64, forKey: Self.backupKeyDefaultsKey)
        NSUbiquitousKeyValueStore.default.set(b64, forKey: Self.backupKeyDefaultsKey)
        NSUbiquitousKeyValueStore.default.synchronize()
        return key
    }

    private func encryptSecret(_ plaintext: String) -> String? {
        guard let data = plaintext.data(using: .utf8),
              let sealed = try? AES.GCM.seal(data, using: backupCryptoKey()),
              let combined = sealed.combined else { return nil }
        return Self.backupEncPrefix + combined.base64EncodedString()
    }

    /// Returns the plaintext, passing through values that aren't encrypted
    /// (older plaintext backups), or nil when a ciphertext can't be opened.
    private func decryptSecret(_ value: String) -> String? {
        guard value.hasPrefix(Self.backupEncPrefix) else { return value }
        let b64 = String(value.dropFirst(Self.backupEncPrefix.count))
        guard let combined = Data(base64Encoded: b64),
              let box = try? AES.GCM.SealedBox(combined: combined),
              let data = try? AES.GCM.open(box, using: backupCryptoKey()),
              let plaintext = String(data: data, encoding: .utf8) else { return nil }
        return plaintext
    }

    /// Wipes every setting. includeCloud also clears the iCloud copy —
    /// without it, a synced device re-inherits from iCloud on relaunch.
    func resetAllSettings(includeCloud: Bool) {
        if includeCloud {
            let cloud = NSUbiquitousKeyValueStore.default
            for key in Self.settingsKeys { cloud.removeObject(forKey: key) }
            cloud.synchronize()
        }
        for key in Self.settingsKeys + ["lastChannelId"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for key in Self.settingsKeys { applySetting(key, "") }
        remoteConfig = nil
        remoteConfigOrigin = nil
        isFullscreen = false
        showSettings = true          // straight back to first-run setup
        Task { await reload() }
    }

    /// The screencap add-on's origin, derived from the dashboard field —
    /// the same probe target /appconfig uses.
    private func addonOrigin() -> URL? {
        for dashboard in Self.parseDashboards(dashImageURLString) {
            guard var components = URLComponents(url: dashboard.url, resolvingAgainstBaseURL: false) else { continue }
            components.path = ""
            components.query = nil
            if let url = components.url { return url }
        }
        return nil
    }

    /// Backs up all on-device settings to the add-on (stored under its
    /// /data, which HA's own backups include). Returns a status line.
    func backupSettingsToAddon() async -> String {
        guard let origin = addonOrigin() else {
            return "SET THE DASHBOARD/ADD-ON URL FIRST — THAT'S WHERE BACKUPS GO"
        }
        var settings = settingsSnapshot()
        // Encrypt the credential fields so the backup blob (which reaches HA's
        // off-box backups and is served unauthenticated on the LAN) never
        // carries the HA token or Immich key in cleartext.
        for key in Self.secretSettingKeys {
            if let value = settings[key], !value.isEmpty, let sealed = encryptSecret(value) {
                settings[key] = sealed
            }
        }
        let payload: [String: Any] = [
            "version": 2,
            "savedAt": ISO8601DateFormatter().string(from: Date()),
            "device": UIDevice.current.name,
            "settings": settings,
        ]
        var request = URLRequest(url: origin.appendingPathComponent("config/appbackup"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return "BACKUP FAILED — IS THE ADD-ON REACHABLE?"
        }
        return "BACKED UP \(settings.count) SETTINGS ✓"
    }

    func restoreSettingsFromAddon() async -> String {
        guard let origin = addonOrigin() else {
            return "SET THE DASHBOARD/ADD-ON URL FIRST — THAT'S WHERE BACKUPS LIVE"
        }
        var request = URLRequest(url: origin.appendingPathComponent("config/appbackup"))
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return "RESTORE FAILED — IS THE ADD-ON REACHABLE?"
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            return "NO BACKUP STORED ON THE ADD-ON YET"
        }
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = payload["settings"] as? [String: String] else {
            return "RESTORE FAILED — BACKUP UNREADABLE"
        }
        for key in Self.settingsKeys {
            var value = settings[key] ?? ""
            if Self.secretSettingKeys.contains(key), value.hasPrefix(Self.backupEncPrefix) {
                // Encrypted credential: decrypt with this device's key. If it
                // can't be opened (no key synced here), leave the existing
                // value in place rather than wiping a working token.
                guard let plaintext = decryptSecret(value) else { continue }
                value = plaintext
            }
            applySetting(key, value)
        }
        Task {
            await reload()
            await refreshWeather(force: true)
        }
        let device = payload["device"] as? String ?? "?"
        let savedAt = (payload["savedAt"] as? String ?? "").prefix(16).replacingOccurrences(of: "T", with: " ")
        return "RESTORED \(settings.count) SETTINGS ✓ (FROM \(device.uppercased()), \(savedAt))"
    }

    /// Applies settings changed on another device. Local edits re-persist
    /// through `persist`, which is idempotent, so no feedback loop.
    private func adoptCloudChanges(_ keys: [String]) {
        guard iCloudSyncEnabled, !isDemoMode else { return }
        let cloud = NSUbiquitousKeyValueStore.default
        var serverChanged = false
        var weatherChanged = false
        var lineupChanged = false
        for key in keys {
            let value = cloud.string(forKey: key) ?? ""
            switch key {
            case "serverURL" where value != serverURLString && !value.isEmpty:
                serverURLString = value
                serverChanged = true
            case "manualLocation" where value != manualLocation:
                manualLocation = value
                weatherChanged = true
            case "haURL" where value != haURLString:
                haURLString = value
                weatherChanged = true
            case "haToken" where value != haToken:
                haToken = value
                weatherChanged = true
            case "haSensorEntities" where value != haSensorEntities:
                haSensorEntities = value
                weatherChanged = true
            case "haWeatherEntity" where value != haWeatherEntity:
                haWeatherEntity = value
                weatherChanged = true
            case "haCameraEntities" where value != haCameraEntities:
                haCameraEntities = value
                lineupChanged = true
            case "hiddenCameras":
                let ids = Set(value.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty })
                if ids != hiddenCameraIds { hiddenCameraIds = ids }
            case "dashImageURL" where value != dashImageURLString:
                dashImageURLString = value
                lineupChanged = true
            case "immichURL" where value != immichURLString:
                immichURLString = value
                lineupChanged = true
            case "immichKey" where value != immichAPIKey:
                immichAPIKey = value
                lineupChanged = true
            case "mediaPlayerEntities" where value != mediaPlayerEntities:
                mediaPlayerEntities = value
            case "tickerEnabled":
                tickerEnabled = value == "true"
            case "immichAlbumId" where value != immichAlbumId:
                immichAlbumId = value
            case "immichAlbumName" where value != immichAlbumName:
                immichAlbumName = value
            case "weatherOverlayPhotos":
                weatherOverlayOnPhotos = value == "true"
            case "weatherOverlayCameras":
                weatherOverlayOnCameras = value == "true"
            default:
                break
            }
        }
        if serverChanged {
            loadError = nil
            Task { await reload() }
        } else if lineupChanged {
            // Synthetic channels appeared/disappeared — rebuild the guide.
            Task { await reload() }
        }
        if weatherChanged {
            Task { await refreshWeather(force: true) }
        }
    }

    static func floorToQuarterHour(_ date: Date) -> Date {
        let interval: TimeInterval = 15 * 60
        let t = floor(date.timeIntervalSince1970 / interval) * interval
        return Date(timeIntervalSince1970: t)
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        if !isConfigured, !hasStandaloneConfig {
            // Screenshot/UI-test hook: launch straight into the demo lineup.
            // Optional: --tune <number> picks the channel, --fullscreen
            // skips the guide.
            if CommandLine.arguments.contains("--demo") {
                startDemo()
                let args = CommandLine.arguments
                if let index = args.firstIndex(of: "--tune"), index + 1 < args.count,
                   let number = Int(args[index + 1]),
                   let channel = channels.first(where: { $0.number == number }) {
                    tune(channel)
                }
                if args.contains("--fullscreen") { isFullscreen = true }
                startTimers()
                return
            }
            loadError = "Set your Tunarr server URL in SETTINGS"
            isFullscreen = false
            showSettings = true
        } else {
            await reload()
            // Screenshot hooks: land on the guide / open settings.
            if CommandLine.arguments.contains("--guide") { isFullscreen = false }
            if CommandLine.arguments.contains("--settings") {
                isFullscreen = false
                showSettings = true
            }
        }
        await refreshWeather()
        startTimers()
    }

    func reload() async {
        if isDemoMode {
            reloadDemoGuide()
            return
        }
        // The add-on's app config (if any) shapes the lineup — fetch first.
        await refreshRemoteConfig()
        guard client != nil || hasStandaloneConfig else {
            loadError = "Set your Tunarr server URL in SETTINGS"
            return
        }
        let from = earliestWindowStart
        let to = from.addingTimeInterval(TimeInterval(Self.fetchHours * 3600))
        var channels: [Channel] = []
        var guide: [String: [GuideEntry]] = [:]

        // Tunarr is optional — with no server the lineup is just the
        // client-rendered channels (weather, dashboards, photos, cameras).
        if let client {
            do {
                channels = try await client.fetchChannels()
                guide = try await client.fetchGuide(from: from, to: to)
            } catch {
                loadError = "Can't reach Tunarr at \(serverURLString)"
                // A transient Tunarr failure (e.g. the every-5-min background
                // refresh hitting a blip) must NOT boot the viewer out of
                // fullscreen or wipe the lineup — especially when a synthetic
                // channel (weather/photos/cameras/dashboard) is tuned and
                // doesn't even use Tunarr. If we already have a lineup, keep
                // it and just surface the error; the next good reload clears it.
                if !self.channels.isEmpty { return }
                // First-load failure: fall through so the synthetic channels
                // below still populate a usable guide instead of a dead screen.
            }
        }

        for (channel, entries) in syntheticChannels(from: from, to: to) {
            channels.append(channel)
            guide[channel.id] = entries
        }

        self.channels = channels
        self.guide = guide
        self.guideFetchedThrough = to
        self.loadError = nil
        if windowStart < earliestWindowStart {
            windowStart = earliestWindowStart
        }
        if tunedChannel == nil {
            let lastId = UserDefaults.standard.string(forKey: "lastChannelId")
            if let target = channels.first(where: { $0.id == lastId }) ?? channels.first {
                tune(target)
            }
        } else if let tuned = tunedChannel,
                  let fresh = channels.first(where: { $0.id == tuned.id }),
                  fresh != tuned {
            // Keep the retained tuned channel pointing at the freshly-decoded
            // instance so channel up/down (which locates it in `channels`)
            // still finds it after a rename/icon change across reloads.
            tunedChannel = fresh
        }
    }

    private func startTimers() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self else { return }
                self.now = Date()
                // Slide the window forward as time passes, unless the user
                // has paged ahead (their position is untouched).
                if self.windowStart < self.earliestWindowStart {
                    self.windowStart = self.earliestWindowStart
                }
                // Watchdog: buffering that never resolves means the stream
                // died under us (e.g. server reaped the session) — re-tune.
                if self.isBuffering, !self.isSyntheticTuned, self.tunedChannel != nil {
                    if let since = self.bufferingSince {
                        if Date().timeIntervalSince(since) > 25 {
                            self.bufferingSince = nil
                            self.retryTune()
                        }
                    } else {
                        self.bufferingSince = Date()
                    }
                } else {
                    self.bufferingSince = nil
                }
                ticks += 1
                // Heartbeat every 30s so the UI can flag a dead server.
                if ticks % 2 == 0 {
                    await self.heartbeat()
                }
                // Refresh guide data every 5 minutes.
                if ticks % 20 == 0 {
                    await self.reload()
                }
                // Refresh weather every 15 minutes (no-op if data is fresh).
                if ticks % 60 == 0 {
                    await self.refreshWeather()
                }
            }
        }
    }

    // MARK: - Demo mode

    func startDemo() {
        isDemoMode = true
        showSettings = false
        loadError = nil
        isServerReachable = true
        reloadDemoGuide()
        // Land on the guide — it's the heart of the app.
        isFullscreen = false
        if let first = channels.first { tune(first) }
        Task { await refreshWeather(force: true) }
    }

    func exitDemo(returnToSetup: Bool = true) {
        guard isDemoMode else { return }
        isDemoMode = false
        clearDemoLoop()
        player.replaceCurrentItem(with: nil)
        tunedChannel = nil
        focusedEntry = nil
        channels = []
        guide = [:]
        guideFetchedThrough = .distantPast
        weatherData = WeatherData()
        if returnToSetup {
            isFullscreen = false
            showSettings = true
            loadError = "Set your Tunarr server URL in SETTINGS"
        }
    }

    /// (Re)generates the demo guide relative to the current time so a long
    /// demo session never runs out of listings. Entry ids are deterministic,
    /// so periodic regeneration doesn't disturb the UI.
    private func reloadDemoGuide() {
        let from = earliestWindowStart
        let to = from.addingTimeInterval(TimeInterval(Self.fetchHours * 3600))
        var channels = DemoContent.asChannels
        var guide = DemoContent.guide(from: from, to: to)

        for (channel, entries) in syntheticChannels(from: from, to: to) {
            channels.append(channel)
            guide[channel.id] = entries
        }

        self.channels = channels
        self.guide = guide
        self.guideFetchedThrough = to
        if windowStart < earliestWindowStart {
            windowStart = earliestWindowStart
        }
    }

    private func clearDemoLoop() {
        if let demoLoopObserver {
            NotificationCenter.default.removeObserver(demoLoopObserver)
            self.demoLoopObserver = nil
        }
    }

    // MARK: - Synthetic channels

    /// The client-rendered lineup, in channel-number order. Weather is
    /// always present; the photos and dashboard channels appear only once
    /// configured in settings. Each is one continuous all-day guide block.
    private func syntheticChannels(from: Date, to: Date) -> [(Channel, [GuideEntry])] {
        var lineup: [(Channel, [GuideEntry])] = []
        if isDemoMode {
            // Demo mode has no real HA/Immich config, so surface fake versions
            // of the cameras, photos, and dashboard channels (bundled images).
            let cameras = Channel(id: Self.camerasChannelId, name: "Security",
                                  number: CamerasChannel.number, icon: nil, groupTitle: nil)
            lineup.append((cameras, [Self.allDayEntry(
                id: "cams-full", channelId: cameras.id, from: from, to: to,
                kind: .cameras, title: "SECURITY CAMERAS",
                summary: "A live multi-camera wall — press left/right to spotlight a camera.")]))
            let photos = Channel(id: Self.photosChannelId, name: "Photos",
                                 number: PhotosChannel.number, icon: nil, groupTitle: nil)
            lineup.append((photos, [Self.allDayEntry(
                id: "photos-full", channelId: photos.id, from: from, to: to,
                kind: .photos, title: "FAMILY ALBUM",
                summary: "A rotating slideshow of your photos.")]))
            let dashboard = Channel(id: Self.dashboardChannelId(index: 0), name: "Home",
                                    number: Self.dashboardChannelNumber(index: 0), icon: nil, groupTitle: nil)
            lineup.append((dashboard, [Self.allDayEntry(
                id: "hadash-full-0", channelId: dashboard.id, from: from, to: to,
                kind: .haDashboard, title: "HOME DASHBOARD",
                summary: "Your Home Assistant dashboard as a channel.")]))
            let weather = Self.makeWeatherChannel()
            lineup.append((weather, [Self.allDayEntry(
                id: "wx-full", channelId: weather.id, from: from, to: to,
                kind: .weather, title: "LOCAL FORECAST",
                summary: "Current conditions, extended forecast, and around-the-house readings.")]))
            lineup.sort { $0.0.number < $1.0.number }
            return lineup
        }
        if haClient != nil, !effectiveCameraIds.isEmpty {
            let channel = Channel(id: Self.camerasChannelId, name: "Security",
                                  number: CamerasChannel.number, icon: nil, groupTitle: nil)
            lineup.append((channel, [Self.allDayEntry(
                id: "cams-full", channelId: channel.id, from: from, to: to,
                kind: .cameras, title: "SECURITY CAMERAS",
                summary: "A live multi-camera wall, streamed straight from your Home Assistant cameras."
            )]))
        }
        if immichClient != nil {
            let channel = Channel(id: Self.photosChannelId, name: "Photos",
                                  number: PhotosChannel.number, icon: nil, groupTitle: nil)
            lineup.append((channel, [Self.allDayEntry(
                id: "photos-full", channelId: channel.id, from: from, to: to,
                kind: .photos, title: "FAMILY ALBUM",
                summary: immichAlbumId.isEmpty
                    ? "A rotating slideshow of your Immich favorite photos."
                    : "A rotating slideshow of your \"\(immichAlbumName)\" album."
            )]))
        }
        for (index, dashboard) in dashboards.enumerated() {
            let name = dashboard.name.isEmpty
                ? (index == 0 ? "Home" : "Home \(index + 1)")
                : dashboard.name
            let channel = Channel(id: Self.dashboardChannelId(index: index), name: name,
                                  number: Self.dashboardChannelNumber(index: index),
                                  icon: nil, groupTitle: nil)
            lineup.append((channel, [Self.allDayEntry(
                id: "hadash-full-\(index)", channelId: channel.id, from: from, to: to,
                kind: .haDashboard, title: "\(name.uppercased()) DASHBOARD",
                summary: "Your Home Assistant dashboard, live from the ha-screencap companion."
            )]))
        }
        let weather = Self.makeWeatherChannel()
        lineup.append((weather, [Self.allDayEntry(
            id: "wx-full", channelId: weather.id, from: from, to: to,
            kind: .weather, title: "LOCAL FORECAST",
            summary: "Current conditions, extended forecast, and around-the-house readings."
        )]))
        // Extra dashboards count down from 996, so sort to keep the guide
        // in channel-number order.
        lineup.sort { $0.0.number < $1.0.number }
        return lineup
    }

    static func makeWeatherChannel() -> Channel {
        Channel(id: weatherChannelId, name: "Weather", number: WeatherChannel.number, icon: nil, groupTitle: nil)
    }

    private static func allDayEntry(id: String, channelId: String, from: Date, to: Date,
                                    kind: GuideEntry.Kind, title: String, summary: String) -> GuideEntry {
        GuideEntry(
            id: id, channelId: channelId, start: from, stop: to, kind: kind,
            title: title, subtitle: nil, summary: summary, year: nil, episodeLabel: nil
        )
    }

    func refreshWeather(force: Bool = false) async {
        guard force || Date().timeIntervalSince(weatherData.fetchedAt) > 600 else { return }

        var latitude: Double?
        var longitude: Double?
        var sensors: [WeatherData.HouseSensor] = []

        if let ha = haClient {
            if let location = try? await ha.fetchLocation() {
                (latitude, longitude) = location
            }
            sensors = await ha.fetchSensors(effectiveWeatherSensorIds)

            // A configured weather entity makes HA the forecast source
            // (e.g. a Tempest/WeatherFlow station); Open-Meteo stays the
            // fallback if the entity errors.
            let weatherEntity = effectiveWeatherEntity
            if !weatherEntity.isEmpty, !isDemoMode,
               let (current, days, source) = try? await ha.fetchWeather(entity: weatherEntity) {
                var locationName: String?
                if let latitude, let longitude {
                    locationName = await LocationResolver.name(latitude: latitude, longitude: longitude)
                }
                weatherData = WeatherData(current: current, days: days, houseSensors: sensors,
                                          locationName: locationName, fetchedAt: Date(),
                                          source: source ?? "HOME ASSISTANT")
                return
            }
        }

        // Fallback when HA isn't configured: the location field accepts
        // "lat,lon", a zip code, or a city name (geocoded and cached).
        if latitude == nil, let resolved = await LocationResolver.resolve(manualLocation) {
            latitude = resolved.latitude
            longitude = resolved.longitude
        }

        if isDemoMode {
            if latitude == nil {
                latitude = DemoContent.fallbackCoordinate.latitude
                longitude = DemoContent.fallbackCoordinate.longitude
            }
            if sensors.isEmpty {
                sensors = DemoContent.houseSensors
            }
        }

        guard let latitude, let longitude else {
            weatherData.houseSensors = sensors
            return
        }
        if let (current, days) = try? await OpenMeteoClient().fetch(latitude: latitude, longitude: longitude) {
            let locationName = await LocationResolver.name(latitude: latitude, longitude: longitude)
            weatherData = WeatherData(current: current, days: days, houseSensors: sensors,
                                      locationName: locationName, fetchedAt: Date())
        } else {
            weatherData.houseSensors = sensors
        }
    }

    // MARK: - Tuning

    func tune(_ channel: Channel, isRetry: Bool = false) {
        if !isRetry {
            retryCount = 0
            streamTrouble = nil
        }
        bufferingSince = nil
        let previous = tunedChannel
        tunedChannel = channel
        isPaused = false
        // Leaving (or re-tuning) the cameras channel drops back to the grid.
        if channel.id != previous?.id { cameraSpotlight = nil }
        UserDefaults.standard.set(channel.id, forKey: "lastChannelId")
        // NOTE: no explicit session teardown on tune-away. Tunarr 1.3.8's
        // DELETE /channels/:id/sessions removes the session record but
        // LEAKS the ffmpeg (verified 2026-07-11) — a CPU-eating zombie per
        // zap. Dropping our player connection and letting Tunarr's idle
        // reaper handle it is the safe path.
        _ = previous
        // The ticker shows weather on whatever channel is tuned.
        if tickerEnabled {
            Task { await refreshWeather() }
        }
        if Self.isSyntheticChannel(channel.id) {
            itemFailureWatch = nil
            pendingTune?.cancel()
            clearDemoLoop()
            player.replaceCurrentItem(with: nil)
            // Cameras always want weather: a spare grid slot shows the
            // mini weather monitor (plus the optional overlay badge).
            if channel.id == Self.weatherChannelId
                || channel.id == Self.camerasChannelId
                || (channel.id == Self.photosChannelId && weatherOverlayOnPhotos) {
                Task { await refreshWeather() }
            }
            return
        }
        if isDemoMode {
            itemFailureWatch = nil
            pendingTune?.cancel()
            clearDemoLoop()
            guard let url = DemoContent.clipURL(for: channel) else {
                player.replaceCurrentItem(with: nil)
                return
            }
            let item = AVPlayerItem(url: url)
            let player = self.player
            demoLoopObserver = NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification,
                object: item,
                queue: .main
            ) { _ in
                player.seek(to: .zero)
                player.play()
            }
            player.replaceCurrentItem(with: item)
            player.play()
            return
        }
        // Surf guard: while the user is actively zapping, drop the old
        // stream immediately but only start the new one once they settle —
        // surfing spawns one session, not one per press. Deliberate tunes
        // (guide picks, retries, first tune) start instantly.
        itemFailureWatch = nil
        player.replaceCurrentItem(with: nil)
        pendingTune?.cancel()
        let surfing = Date().timeIntervalSince(lastZapAt) < 2.0
        if isRetry || !surfing {
            startStream(channel)
            return
        }
        // Busy probe runs alongside the settle window and is only honored
        // if it finished in time — it never delays the tune by itself.
        let busy = BusyFlag()
        let probe = Task { [weak self] in
            if let snapshot = try? await self?.client?.sessionSnapshot(), snapshot.total >= 6 {
                await MainActor.run { busy.value = true }
            }
        }
        pendingTune = Task { [weak self] in
            defer { probe.cancel() }
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled, let self, self.tunedChannel?.id == channel.id else { return }
            if busy.value {
                try? await Task.sleep(nanoseconds: 850_000_000)
                guard !Task.isCancelled, self.tunedChannel?.id == channel.id else { return }
            }
            self.startStream(channel)
        }
    }

    /// Main-actor mailbox for the surf guard's busy probe.
    final class BusyFlag {
        var value = false
    }

    private func startStream(_ channel: Channel) {
        guard let client else { return }
        let item = AVPlayerItem(url: client.streamURL(for: channel))
        item.preferredForwardBufferDuration = 2
        // A session torn down server-side mid-join leaves the item dead;
        // retry with a fresh item (which spawns a fresh Tunarr session).
        itemFailureWatch = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                if status == .failed { self?.retryTune() }
                if status == .readyToPlay { self?.streamTrouble = nil }
            }
        player.replaceCurrentItem(with: item)
        player.playImmediately(atRate: 1.0)
    }

    /// Backgrounding stops playback outright — dropping our playlist
    /// connection is what lets Tunarr's idle reaper end the session and
    /// its ffmpeg cleanly. (Explicitly DELETEing the session leaks the
    /// ffmpeg on Tunarr 1.3.8, so we deliberately don't.)
    func appDidEnterBackground() {
        guard let channel = tunedChannel, !Self.isSyntheticChannel(channel.id), !isDemoMode else { return }
        _ = channel
        pendingTune?.cancel()
        itemFailureWatch = nil
        player.replaceCurrentItem(with: nil)
    }

    func appDidBecomeActive() {
        guard let channel = tunedChannel, !Self.isSyntheticChannel(channel.id), !isDemoMode,
              player.currentItem == nil else { return }
        tune(channel, isRetry: true)
    }

    private func retryTune() {
        guard let channel = tunedChannel,
              !Self.isSyntheticChannel(channel.id) else { return }
        guard retryCount < 3 else {
            diagnoseStreamTrouble()
            return
        }
        retryCount += 1
        let target = channel
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.tunedChannel?.id == target.id else { return }
            self.tune(target, isRetry: true)
        }
    }

    /// Retries exhausted — probe the server so the static screen can name
    /// the failure. API answering but the stream never starting is the
    /// overload/bad-source signature (established streams keep playing
    /// while every NEW transcode fails, which otherwise looks senseless).
    private func diagnoseStreamTrouble() {
        Task { [weak self] in
            guard let self, let client = self.client else { return }
            let apiUp = (try? await client.fetchVersion()) != nil
            await MainActor.run {
                guard let channel = self.tunedChannel,
                      !Self.isSyntheticChannel(channel.id) else { return }
                self.streamTrouble = apiUp ? .busy : .unreachable
            }
        }
    }

    /// Warm a channel's Tunarr session before the user commits to it —
    /// a single GET of the playlist makes the server spin up ffmpeg, so a
    /// following tune() lands on a session that's already seconds warm.
    func prefetch(_ channel: Channel) {
        guard isConfigured, !isDemoMode,
              !Self.isSyntheticChannel(channel.id),
              channel.id != tunedChannel?.id,
              channel.id != lastPrefetchedChannelId else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self] in
            // Debounce so scrubbing focus across the guide doesn't spawn
            // a transcode session per cell.
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self, let client = self.client else { return }
            self.lastPrefetchedChannelId = channel.id
            var request = URLRequest(url: client.streamURL(for: channel))
            request.timeoutInterval = 20
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    private var lastZapAt: Date = .distantPast

    func channelUp() {
        lastZapAt = Date()
        step(by: 1)
    }

    func channelDown() {
        lastZapAt = Date()
        step(by: -1)
    }

    private func step(by delta: Int) {
        guard !channels.isEmpty else { return }
        guard let tuned = tunedChannel,
              let index = channels.firstIndex(where: { $0.id == tuned.id }) else {
            tune(channels[0])
            return
        }
        let next = (index + delta + channels.count) % channels.count
        tune(channels[next])
        // NOTE: no speculative prefetch of the channel after `next` — with
        // several devices surfing at once it stacked enough concurrent
        // transcodes to starve the server (2026-07-10). Guide-focus
        // prefetch (deliberate, debounced, one at a time) is enough.
    }

    func togglePause() {
        // On the trouble screen, play/pause means "try again", not pause.
        if streamTrouble != nil, let channel = tunedChannel {
            tune(channel)
            return
        }
        if isPaused {
            player.play()
        } else {
            player.pause()
        }
        isPaused.toggle()
    }

    // MARK: - Guide window paging

    func pageForward() {
        let next = windowStart.addingTimeInterval(TimeInterval(Self.pageMinutes * 60))
        // Keep at least one page of guide data beyond the window.
        if next.addingTimeInterval(TimeInterval(Self.windowMinutes * 60)) < guideFetchedThrough {
            windowStart = next
        }
    }

    func pageBack() {
        let previous = windowStart.addingTimeInterval(TimeInterval(-Self.pageMinutes * 60))
        windowStart = max(previous, earliestWindowStart)
    }

    var canPageBack: Bool { windowStart > earliestWindowStart }

    // MARK: - Lookup helpers

    func channel(withId id: String) -> Channel? {
        channels.first { $0.id == id }
    }

    func entries(for channel: Channel, in window: ClosedRange<Date>) -> [GuideEntry] {
        (guide[channel.id] ?? []).filter { $0.stop > window.lowerBound && $0.start < window.upperBound }
    }

    func nowPlaying(on channel: Channel) -> GuideEntry? {
        (guide[channel.id] ?? []).first { $0.airs(at: now) }
    }

    /// The entry shown in the info panel: focused guide cell, else what's playing.
    var displayedEntry: GuideEntry? {
        if let focusedEntry { return focusedEntry }
        if let tunedChannel { return nowPlaying(on: tunedChannel) }
        return nil
    }

    /// Pings /api/version; after two consecutive misses the UI shows the
    /// offline banner. Recovery reloads the guide (it's stale by then).
    func heartbeat() async {
        guard !isDemoMode, isConfigured, let client else { return }
        if (try? await client.fetchVersion()) != nil {
            missedHeartbeats = 0
            if !isServerReachable {
                isServerReachable = true
                await reload()
            }
        } else {
            missedHeartbeats += 1
            if missedHeartbeats >= 2 {
                isServerReachable = false
            }
        }
    }

    // MARK: - Connection test

    /// Probes /api/version on the given URL. Returns a user-facing result string.
    func testConnection(to urlString: String) async -> String {
        guard let client = TunarrClient(baseURLString: urlString) else {
            return "INVALID URL"
        }
        do {
            let version = try await client.fetchVersion()
            return "OK — TUNARR \(version)"
        } catch {
            return "FAILED — CAN'T REACH SERVER"
        }
    }

    // MARK: - Integration tests (settings TEST buttons)

    struct IntegrationTestResult {
        let message: String
        var preview: UIImage?
        var isSuccess: Bool { message.hasPrefix("OK") }
    }

    private static func parseEntityList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    func testHomeAssistant(urlString: String, token: String, sensorEntities: String) async -> IntegrationTestResult {
        guard let ha = HAClient(urlString: urlString, token: token) else {
            return .init(message: "FAILED — ENTER THE URL AND TOKEN FIRST")
        }
        do {
            let summary = try await ha.fetchConfigSummary()
            let ids = Self.parseEntityList(sensorEntities)
            guard !ids.isEmpty else { return .init(message: "OK — \(summary)") }
            let sensors = await ha.fetchSensors(ids)
            return .init(message: "OK — \(summary) · \(sensors.count)/\(ids.count) SENSORS")
        } catch HAClient.HAError.unauthorized {
            return .init(message: "FAILED — TOKEN REJECTED (401)")
        } catch {
            return .init(message: "FAILED — CAN'T REACH HOME ASSISTANT")
        }
    }

    /// Exercises the exact playback path the channel uses: entity lookup,
    /// then a websocket camera/stream request and a GET of the returned
    /// HLS playlist. Preview is a still frame from the first camera.
    func testCameras(urlString: String, token: String, cameraEntities: String) async -> IntegrationTestResult {
        guard let ha = HAClient(urlString: urlString, token: token) else {
            return .init(message: "FAILED — SET THE HOME ASSISTANT URL AND TOKEN ABOVE")
        }
        let ids = Self.parseEntityList(cameraEntities)
        guard !ids.isEmpty else {
            return .init(message: "FAILED — ADD CAMERA ENTITIES FIRST")
        }
        var found: [String] = []
        var missing: [String] = []
        for id in ids {
            if await ha.entityExists(id) { found.append(id) } else { missing.append(id) }
        }
        guard let first = found.first else {
            return .init(message: "FAILED — NO CAMERAS FOUND, CHECK THE ENTITY IDS")
        }

        var streamOK = false
        if let url = try? await HACameraStream.fetchStreamURL(
            haURLString: urlString, token: token, entityId: first) {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                streamOK = true
            }
        }
        guard streamOK else {
            return .init(message: "FAILED — CAMERA FOUND BUT ITS STREAM DIDN'T START")
        }

        let preview = await ha.fetchCameraStill(first)
        var message = "OK — \(found.count)/\(ids.count) CAMERAS · STREAM READY"
        if let firstMissing = missing.first {
            message += " · NOT FOUND: \(firstMissing)"
        }
        return .init(message: message, preview: preview)
    }

    /// Tests every configured dashboard URL; the preview is the first
    /// snapshot that loads.
    func testDashboard(urlString: String) async -> IntegrationTestResult {
        let configs = Self.parseDashboards(urlString)
        guard !configs.isEmpty else {
            return .init(message: "FAILED — ENTER A SNAPSHOT URL FIRST")
        }
        var preview: UIImage?
        var failedNames: [String] = []
        for (index, config) in configs.enumerated() {
            var request = URLRequest(url: config.url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 10
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let image = UIImage(data: data) {
                if preview == nil { preview = image }
            } else {
                failedNames.append(config.name.isEmpty ? "#\(index + 1)" : config.name.uppercased())
            }
        }
        if failedNames.isEmpty {
            return .init(message: "OK — \(configs.count) DASHBOARD\(configs.count == 1 ? "" : "S")",
                         preview: preview)
        }
        if preview == nil {
            return .init(message: "FAILED — NO IMAGE AT THAT URL")
        }
        return .init(message: "FAILED — NO IMAGE FOR: \(failedNames.joined(separator: ", "))",
                     preview: preview)
    }

    func testImmich(urlString: String, apiKey: String) async -> IntegrationTestResult {
        guard let client = ImmichClient(urlString: urlString, apiKey: apiKey) else {
            return .init(message: "FAILED — ENTER THE URL AND API KEY FIRST")
        }
        do {
            let usingAlbum = !immichAlbumId.isEmpty
            let assets = try await (usingAlbum
                ? client.fetchAlbumAssets(albumId: immichAlbumId)
                : client.fetchFavorites())
            let source = usingAlbum ? "\"\(immichAlbumName.uppercased())\"" : "FAVORITES"
            guard let sample = assets.randomElement() else {
                return .init(message: "OK — CONNECTED, BUT \(source) IS EMPTY")
            }
            var preview: UIImage?
            if let (data, response) = try? await URLSession.shared.data(for: client.imageRequest(for: sample)),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                preview = UIImage(data: data)
            }
            return .init(message: "OK — \(source): \(assets.count) PHOTOS", preview: preview)
        } catch {
            return .init(message: "FAILED — CHECK THE URL AND API KEY")
        }
    }

    // MARK: - Entity suggestions (settings)

    struct SuggestedEntity: Identifiable {
        let id: String
        let detail: String
    }

    /// Likely "around the house" readings: temperature and humidity
    /// sensors with a live numeric state.
    func suggestWeatherSensors(urlString: String, token: String) async -> [SuggestedEntity] {
        guard let ha = HAClient(urlString: urlString, token: token),
              let entities = try? await ha.fetchEntitySummaries() else { return [] }
        let interesting = entities.filter { entity in
            guard entity.entityId.hasPrefix("sensor."), Double(entity.state) != nil else { return false }
            if let deviceClass = entity.deviceClass, ["temperature", "humidity"].contains(deviceClass) {
                return true
            }
            return ["°F", "°C"].contains(entity.unit ?? "")
        }
        // Temperature first, then humidity; stable name order within each.
        let ranked = interesting.sorted {
            let left = ($0.deviceClass == "temperature" ? 0 : 1, $0.entityId)
            let right = ($1.deviceClass == "temperature" ? 0 : 1, $1.entityId)
            return left < right
        }
        return ranked.prefix(20).map {
            SuggestedEntity(id: $0.entityId, detail: "\($0.state)\($0.unit ?? "")")
        }
    }

    /// Media players that exist and are reachable, active ones first.
    func suggestMediaPlayers(urlString: String, token: String) async -> [SuggestedEntity] {
        guard let ha = HAClient(urlString: urlString, token: token),
              let entities = try? await ha.fetchEntitySummaries() else { return [] }
        return entities
            .filter { $0.entityId.hasPrefix("media_player.") && !["unavailable", "unknown"].contains($0.state) }
            .sorted {
                let left = ($0.state == "playing" ? 0 : 1, $0.entityId)
                let right = ($1.state == "playing" ? 0 : 1, $1.entityId)
                return left < right
            }
            .prefix(20)
            .map { SuggestedEntity(id: $0.entityId, detail: $0.state.uppercased()) }
    }

    /// Cameras with a live feed (unavailable ones are left out).
    func suggestCameras(urlString: String, token: String) async -> [SuggestedEntity] {
        guard let ha = HAClient(urlString: urlString, token: token),
              let entities = try? await ha.fetchEntitySummaries() else { return [] }
        return entities
            .filter { $0.entityId.hasPrefix("camera.") && !["unavailable", "unknown"].contains($0.state) }
            .sorted { $0.entityId < $1.entityId }
            .prefix(20)
            .map { SuggestedEntity(id: $0.entityId, detail: $0.state.uppercased()) }
    }
}
