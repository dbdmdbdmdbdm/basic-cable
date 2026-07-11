import Foundation
import AVFoundation
import Combine
import UIKit

@MainActor
final class AppState: ObservableObject {
    static let windowMinutes = 120
    static let pageMinutes = 30
    static let fetchHours = 12

    static let weatherChannelId = WeatherChannel.id
    static let dashboardChannelId = HADashboardChannel.id
    static let photosChannelId = PhotosChannel.id
    static let camerasChannelId = CamerasChannel.id

    /// Client-rendered channels — no Tunarr stream behind them.
    static func isSyntheticChannel(_ id: String) -> Bool {
        id == weatherChannelId || id == dashboardChannelId || id == photosChannelId
            || id == camerasChannelId
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
    /// Demo mode: canned lineup + bundled looping clips, no server needed.
    @Published private(set) var isDemoMode = false

    private var missedHeartbeats = 0
    private var demoLoopObserver: NSObjectProtocol?

    let player = AVPlayer()
    let deviceLocation = DeviceLocation()

    private var refreshTask: Task<Void, Never>?
    private var guideFetchedThrough: Date = .distantPast
    private var prefetchTask: Task<Void, Never>?
    private var lastPrefetchedChannelId: String?
    private var itemFailureWatch: AnyCancellable?
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

    var isWeatherTuned: Bool { tunedChannel?.id == Self.weatherChannelId }
    var isDashboardTuned: Bool { tunedChannel?.id == Self.dashboardChannelId }
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

    /// The cameras actually shown in the grid (configured minus hidden).
    var visibleCameraIds: [String] {
        cameraEntityIds.filter { !hiddenCameraIds.contains($0) }
    }

    var immichClient: ImmichClient? { ImmichClient(urlString: immichURLString, apiKey: immichAPIKey) }

    /// The ha-screencap snapshot URL, when the dashboard channel is set up.
    var dashImageURL: URL? {
        let trimmed = dashImageURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
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
        persist(haCameraEntities, forKey: "haCameraEntities")
        persist(hiddenCameraIds.sorted().joined(separator: ","), forKey: "hiddenCameras")
        persist(dashImageURLString, forKey: "dashImageURL")
        persist(immichURLString, forKey: "immichURL")
        persist(immichAPIKey, forKey: "immichKey")
        persist(weatherOverlayOnPhotos ? "true" : "false", forKey: "weatherOverlayPhotos")
        persist(weatherOverlayOnCameras ? "true" : "false", forKey: "weatherOverlayCameras")
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
        if !isConfigured {
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
        guard let client else {
            loadError = "Set your Tunarr server URL in SETTINGS"
            return
        }
        do {
            var channels = try await client.fetchChannels()
            let from = earliestWindowStart
            let to = from.addingTimeInterval(TimeInterval(Self.fetchHours * 3600))
            var guide = try await client.fetchGuide(from: from, to: to)

            // Synthetic channels, rendered client-side (Tunarr knows nothing about them).
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
            }
        } catch {
            loadError = "Can't reach Tunarr at \(serverURLString)"
            isFullscreen = false
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
        if haClient != nil, !cameraEntityIds.isEmpty {
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
                summary: "A rotating slideshow of your Immich favorite photos."
            )]))
        }
        if dashImageURL != nil {
            let channel = Channel(id: Self.dashboardChannelId, name: "Home",
                                  number: HADashboardChannel.number, icon: nil, groupTitle: nil)
            lineup.append((channel, [Self.allDayEntry(
                id: "hadash-full", channelId: channel.id, from: from, to: to,
                kind: .haDashboard, title: "HOME DASHBOARD",
                summary: "Your Home Assistant dashboard, live from the ha-screencap companion."
            )]))
        }
        let weather = Self.makeWeatherChannel()
        lineup.append((weather, [Self.allDayEntry(
            id: "wx-full", channelId: weather.id, from: from, to: to,
            kind: .weather, title: "LOCAL FORECAST",
            summary: "Current conditions, extended forecast, and around-the-house readings."
        )]))
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
            let entityIds = haSensorEntities
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            sensors = await ha.fetchSensors(entityIds)
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
        if !isRetry { retryCount = 0 }
        bufferingSince = nil
        tunedChannel = channel
        isPaused = false
        UserDefaults.standard.set(channel.id, forKey: "lastChannelId")
        if Self.isSyntheticChannel(channel.id) {
            itemFailureWatch = nil
            clearDemoLoop()
            player.replaceCurrentItem(with: nil)
            if channel.id == Self.weatherChannelId
                || (channel.id == Self.photosChannelId && weatherOverlayOnPhotos)
                || (channel.id == Self.camerasChannelId && weatherOverlayOnCameras) {
                Task { await refreshWeather() }
            }
            return
        }
        if isDemoMode {
            itemFailureWatch = nil
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
        guard let client else { return }
        let item = AVPlayerItem(url: client.streamURL(for: channel))
        item.preferredForwardBufferDuration = 2
        // A session torn down server-side mid-join leaves the item dead;
        // retry with a fresh item (which spawns a fresh Tunarr session).
        itemFailureWatch = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                if status == .failed { self?.retryTune() }
            }
        player.replaceCurrentItem(with: item)
        player.playImmediately(atRate: 1.0)
    }

    private func retryTune() {
        guard let channel = tunedChannel,
              !Self.isSyntheticChannel(channel.id),
              retryCount < 3 else { return }
        retryCount += 1
        let target = channel
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, self.tunedChannel?.id == target.id else { return }
            self.tune(target, isRetry: true)
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

    func channelUp() { step(by: 1) }
    func channelDown() { step(by: -1) }

    private func step(by delta: Int) {
        guard !channels.isEmpty else { return }
        guard let tuned = tunedChannel,
              let index = channels.firstIndex(of: tuned) else {
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

    func testDashboard(urlString: String) async -> IntegrationTestResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), url.scheme != nil else {
            return .init(message: "FAILED — ENTER THE SNAPSHOT URL FIRST")
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data) else {
            return .init(message: "FAILED — NO IMAGE AT THAT URL")
        }
        let size = "\(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale))"
        return .init(message: "OK — SNAPSHOT \(size)", preview: image)
    }

    func testImmich(urlString: String, apiKey: String) async -> IntegrationTestResult {
        guard let client = ImmichClient(urlString: urlString, apiKey: apiKey) else {
            return .init(message: "FAILED — ENTER THE URL AND API KEY FIRST")
        }
        do {
            let favorites = try await client.fetchFavorites()
            guard let sample = favorites.randomElement() else {
                return .init(message: "OK — CONNECTED, BUT NO FAVORITES YET")
            }
            var preview: UIImage?
            if let (data, response) = try? await URLSession.shared.data(for: client.imageRequest(for: sample)),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                preview = UIImage(data: data)
            }
            return .init(message: "OK — \(favorites.count) FAVORITE PHOTOS", preview: preview)
        } catch {
            return .init(message: "FAILED — CHECK THE URL AND API KEY")
        }
    }
}
