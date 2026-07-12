import SwiftUI

#if os(iOS)
private let uiScale: CGFloat = 0.62
#else
private let uiScale: CGFloat = 1.0
#endif

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var urlText = ""
    @State private var locationText = ""
    @State private var haURLText = ""
    @State private var haTokenText = ""
    @State private var haSensorsText = ""
    @State private var haWeatherText = ""
    @State private var haCamerasText = ""
    @State private var dashURLText = ""
    @State private var immichURLText = ""
    @State private var immichKeyText = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var integrationResults: [String: AppState.IntegrationTestResult] = [:]
    @State private var integrationTesting: Set<String> = []
    @State private var locating = false
    @State private var locationStatus: String?

    @State private var mediaPlayersText = ""
    @State private var sensorSuggestions: [AppState.SuggestedEntity] = []
    @State private var cameraSuggestions: [AppState.SuggestedEntity] = []
    @State private var mediaPlayerSuggestions: [AppState.SuggestedEntity] = []
    @State private var suggesting: Set<String> = []

    @State private var albums: [ImmichAlbum] = []
    @State private var albumThumbs: [String: UIImage] = [:]
    @State private var loadingAlbums = false
    @State private var albumStatus: String?

    @State private var showAllSections = false

    @State private var backupStatus: String?
    @State private var backupBusy = false
    @State private var armedAction: String?

    /// First-run keeps the form to just the Tunarr URL — unless the user
    /// already runs standalone (built-in channels, no Tunarr).
    private var isFirstRun: Bool {
        state.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !state.hasStandaloneConfig
    }

    /// Field text that differs from what's saved. Toggles, camera
    /// visibility, and the album choice apply immediately and never
    /// count as unsaved.
    private var hasUnsavedChanges: Bool {
        func trimmed(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed(urlText) != state.serverURLString
            || trimmed(locationText) != state.manualLocation
            || trimmed(haURLText) != state.haURLString
            || trimmed(haTokenText) != state.haToken
            || trimmed(haSensorsText) != state.haSensorEntities
            || trimmed(haWeatherText) != state.haWeatherEntity
            || trimmed(haCamerasText) != state.haCameraEntities
            || trimmed(dashURLText) != state.dashImageURLString
            || trimmed(immichURLText) != state.immichURLString
            || trimmed(immichKeyText) != state.immichAPIKey
            || trimmed(mediaPlayersText) != state.mediaPlayerEntities
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                Text(isFirstRun ? "CONNECT TO TUNARR" : "SETTINGS")
                    .font(Theme.mono(38 * uiScale))
                    .foregroundColor(.white)

                unsavedBanner

                if isFirstRun {
                    Text("Enter the address of your Tunarr server — the same URL you use for its web UI.")
                        .font(.system(size: 22 * uiScale))
                        .foregroundColor(Theme.dimText)
                        .frame(maxWidth: 900)
                        .multilineTextAlignment(.center)
                    #if os(tvOS)
                    Text("Tip: set everything up in the iPhone app instead — settings sync here automatically via iCloud.")
                        .font(.system(size: 19 * uiScale))
                        .foregroundColor(Theme.dimText)
                        .frame(maxWidth: 900)
                        .multilineTextAlignment(.center)
                    #endif
                    if !showAllSections {
                        Button("NO TUNARR? USE JUST THE BUILT-IN CHANNELS") {
                            showAllSections = true
                        }
                        .font(Theme.mono(19 * uiScale))
                        Text("Weather, Home Assistant dashboards, security cameras, and an Immich photo slideshow all work without a Tunarr server.")
                            .font(.system(size: 17 * uiScale))
                            .foregroundColor(Theme.dimText)
                            .frame(maxWidth: 900)
                            .multilineTextAlignment(.center)
                    }
                }

                field("TUNARR SERVER URL", placeholder: "http://192.168.1.100:8000", text: $urlText)

                if let testResult {
                    Text(testResult)
                        .font(Theme.mono(22 * uiScale))
                        .foregroundColor(testResult.hasPrefix("OK") ? Theme.onAir : Theme.accent)
                }

                if !isFirstRun || showAllSections {
                    weatherSection
                    camerasSection
                    dashboardSection
                    photosSection
                    tickerSection
                    syncSection
                    backupSection
                }

                buttonRow

                if isFirstRun {
                    demoSection
                }

                aboutSection
            }
            .padding(60 * uiScale)
        }
        .onAppear { loadFields() }
    }

    /// Pulls the saved settings into the editable field texts — on appear,
    /// and again after a restore or reset changes them underneath us.
    private func loadFields() {
        urlText = state.serverURLString
        locationText = state.manualLocation
        haURLText = state.haURLString
        haTokenText = state.haToken
        haSensorsText = state.haSensorEntities
        haWeatherText = state.haWeatherEntity
        haCamerasText = state.haCameraEntities
        dashURLText = state.dashImageURLString
        immichURLText = state.immichURLString
        immichKeyText = state.immichAPIKey
        mediaPlayersText = state.mediaPlayerEntities
    }

    // MARK: - Sections

    private var weatherSection: some View {
        section("WEATHER CHANNEL — \(WeatherChannel.number)", tint: Theme.cellWeather) {
            field("LOCATION (ZIP, CITY, OR LAT,LON) — USED WITHOUT HOME ASSISTANT",
                  placeholder: "90210  /  Austin, TX  /  37.77, -122.42", text: $locationText)
            HStack(spacing: 16) {
                Button(locating ? "LOCATING..." : "USE THIS DEVICE'S LOCATION") {
                    guard !locating else { return }
                    locating = true
                    Task {
                        if let coordinate = await state.deviceLocation.requestOnce() {
                            locationText = String(format: "%.3f, %.3f",
                                                  coordinate.latitude, coordinate.longitude)
                        } else {
                            locationStatus = "LOCATION UNAVAILABLE — CHECK SETTINGS > PRIVACY"
                        }
                        locating = false
                    }
                }
                .font(Theme.mono(19 * uiScale))
                if let locationStatus {
                    Text(locationStatus)
                        .font(Theme.mono(17 * uiScale, weight: .medium))
                        .foregroundColor(Theme.accent)
                }
            }
            field("HOME ASSISTANT URL (OPTIONAL)",
                  placeholder: "http://homeassistant.local:8123", text: $haURLText)
            field("HOME ASSISTANT LONG-LIVED TOKEN",
                  placeholder: "eyJhbGciOi...", text: $haTokenText)
            if let remote = state.remoteConfig?.weather_sensors, !remote.isEmpty {
                managedField("HA SENSOR ENTITIES", values: remote)
            } else {
                field("HA SENSOR ENTITIES (COMMA-SEPARATED)",
                      placeholder: "sensor.outdoor_temp, sensor.pool_temp", text: $haSensorsText)
                suggestionControl("sensors", suggestions: sensorSuggestions, listText: $haSensorsText,
                                  buttonTitle: "SUGGEST SENSORS") {
                    await state.suggestWeatherSensors(urlString: haURLText, token: haTokenText)
                } assign: { sensorSuggestions = $0 }
            }
            if let remote = state.remoteConfig?.weather_entity,
               !remote.trimmingCharacters(in: .whitespaces).isEmpty {
                managedField("HA WEATHER ENTITY", values: [remote])
            } else {
                field("HA WEATHER ENTITY (OPTIONAL) — REPLACES OPEN-METEO AS THE FORECAST SOURCE",
                      placeholder: "weather.home", text: $haWeatherText)
            }
            testControl("ha") {
                await state.testHomeAssistant(urlString: haURLText, token: haTokenText,
                                              sensorEntities: haSensorsText)
            }
        }
    }

    private var camerasSection: some View {
        section("SECURITY CAMERAS CHANNEL — \(CamerasChannel.number) (OPTIONAL)", tint: Theme.cellCameras) {
            if let remote = state.remoteConfig?.cameras, !remote.isEmpty {
                managedField("HA CAMERA ENTITIES", values: remote)
            } else {
                field("HA CAMERA ENTITIES (COMMA-SEPARATED)",
                      placeholder: "camera.front_door, camera.backyard", text: $haCamerasText)
                suggestionControl("cameras", suggestions: cameraSuggestions, listText: $haCamerasText,
                                  buttonTitle: "SUGGEST CAMERAS") {
                    await state.suggestCameras(urlString: haURLText, token: haTokenText)
                } assign: { cameraSuggestions = $0 }
            }
            caption("Shows all cameras live in one grid as channel \(CamerasChannel.number) (list order = grid order). Uses the Home Assistant URL and token above — streams come straight from HA, full motion.")
            testControl("cameras") {
                await state.testCameras(urlString: haURLText, token: haTokenText,
                                        cameraEntities: haCamerasText)
            }
            Toggle(isOn: $state.weatherOverlayOnCameras) {
                Text("SHOW WEATHER OVERLAY")
                    .font(Theme.mono(20 * uiScale, weight: .medium))
            }
            if !state.cameraEntityIds.isEmpty {
                VStack(spacing: 10) {
                    ForEach(state.cameraEntityIds, id: \.self) { entityId in
                        Toggle(isOn: cameraVisibilityBinding(entityId)) {
                            Text("SHOW \(CameraName.display(entityId))")
                                .font(Theme.mono(20 * uiScale, weight: .medium))
                        }
                    }
                }
                caption("Toggles apply immediately — hidden cameras stay in the list above.")
            }
        }
    }

    private var dashboardSection: some View {
        section("HOME DASHBOARD CHANNEL — \(HADashboardChannel.number) (OPTIONAL)", tint: Theme.cellDashboard) {
            field("SNAPSHOT URLS (COMMA-SEPARATED, OPTIONAL NAME=URL)",
                  placeholder: "http://192.168.1.100:8090, Kitchen=http://…/latest/1.png",
                  text: $dashURLText)
            caption("Each URL becomes its own channel — the first is \(HADashboardChannel.number), extras count down from 996. Name them like \"Kitchen=http://…\". Just the server address works too (/latest.png is assumed). Snapshots come from the ha-screencap companion (Home Assistant add-on or Docker container — see the GitHub README).")
            testControl("dashboard") {
                await state.testDashboard(urlString: dashURLText)
            }
        }
    }

    private var photosSection: some View {
        section("PHOTOS CHANNEL — \(PhotosChannel.number) (OPTIONAL)", tint: Theme.cellPhotos) {
            field("IMMICH URL",
                  placeholder: "http://192.168.1.100:2283", text: $immichURLText)
            field("IMMICH API KEY",
                  placeholder: "create one in Immich under Account Settings > API Keys", text: $immichKeyText)
            caption("Shows a slideshow of your Immich photos as channel \(PhotosChannel.number). Create the key in Immich under Account Settings → API Keys — it only needs the read-only asset.read and asset.view permissions (plus album.read to pick an album below).")
            albumPicker
            testControl("photos") {
                await state.testImmich(urlString: immichURLText, apiKey: immichKeyText)
            }
            Toggle(isOn: $state.weatherOverlayOnPhotos) {
                Text("SHOW WEATHER OVERLAY")
                    .font(Theme.mono(20 * uiScale, weight: .medium))
            }
        }
    }

    private var tickerSection: some View {
        section("NOW PLAYING TICKER (OPTIONAL)", tint: Color(white: 0.55)) {
            if let remote = state.remoteConfig?.media_players, !remote.isEmpty {
                managedField("HA MEDIA PLAYER ENTITIES", values: remote)
            } else {
                field("HA MEDIA PLAYER ENTITIES (COMMA-SEPARATED)",
                      placeholder: "media_player.living_room, media_player.kitchen", text: $mediaPlayersText)
                suggestionControl("mediaplayers", suggestions: mediaPlayerSuggestions, listText: $mediaPlayersText,
                                  buttonTitle: "SUGGEST MEDIA PLAYERS") {
                    await state.suggestMediaPlayers(urlString: haURLText, token: haTokenText)
                } assign: { mediaPlayerSuggestions = $0 }
            }
            caption("A news-style black bar along the bottom of every channel: what's playing on these media players on the left (speakers playing the same thing collapse to one), weather and clock on the right. Turn it on while watching — hold SELECT on the remote (or press LEFT/RIGHT); the ticker button on iPhone. It stays on while you zap, until you turn it off the same way.")
        }
    }

    private var syncSection: some View {
        section("SYNC", tint: Theme.dimText) {
            Toggle(isOn: $state.iCloudSyncEnabled) {
                Text("SYNC SETTINGS VIA ICLOUD")
                    .font(Theme.mono(20 * uiScale, weight: .medium))
            }
            caption("Shares these settings (including the Home Assistant token) across your devices through your own iCloud account.")
        }
    }

    private var backupSection: some View {
        section("BACKUP & RESET", tint: Color(white: 0.42)) {
            caption("BACK UP sends every on-device setting (tokens included) to the screencap add-on, which keeps one backup file under its /data folder — so Home Assistant's own backups include it. Add-on-managed lists already live in HA and are covered there. RESTORE pulls that file back and applies it.")
            HStack(spacing: 16) {
                Button(backupBusy ? "WORKING..." : "BACK UP TO ADD-ON") {
                    guard !backupBusy else { return }
                    backupBusy = true
                    Task {
                        backupStatus = await state.backupSettingsToAddon()
                        backupBusy = false
                    }
                }
                .font(Theme.mono(19 * uiScale))
                confirmButton("RESTORE FROM ADD-ON", id: "restore") {
                    guard !backupBusy else { return }
                    backupBusy = true
                    Task {
                        backupStatus = await state.restoreSettingsFromAddon()
                        loadFields()
                        backupBusy = false
                    }
                }
            }
            if let backupStatus {
                Text(backupStatus)
                    .font(Theme.mono(17 * uiScale, weight: .medium))
                    .foregroundColor(backupStatus.contains("✓") ? Theme.onAir : Theme.accent)
            }
            caption("RESET wipes the app back to first-run — handy for testing a restore. THIS DEVICE keeps the iCloud copy (a synced device re-inherits it on relaunch); EVERYWHERE also clears iCloud so all devices start fresh.")
            HStack(spacing: 16) {
                confirmButton("RESET THIS DEVICE", id: "resetLocal") {
                    state.resetAllSettings(includeCloud: false)
                    loadFields()
                    backupStatus = "RESET ✓ — BACK TO FIRST-RUN"
                }
                confirmButton("RESET EVERYWHERE (+ICLOUD)", id: "resetAll") {
                    state.resetAllSettings(includeCloud: true)
                    loadFields()
                    backupStatus = "RESET ✓ — DEVICE AND ICLOUD CLEARED"
                }
            }
        }
    }

    /// Destructive buttons take two presses: the first arms (label flips
    /// to PRESS AGAIN), disarming itself after 4 seconds untouched.
    private func confirmButton(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(armedAction == id ? "PRESS AGAIN TO CONFIRM" : title) {
            if armedAction == id {
                armedAction = nil
                action()
            } else {
                armedAction = id
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    if armedAction == id { armedAction = nil }
                }
            }
        }
        .font(Theme.mono(19 * uiScale))
        .foregroundColor(armedAction == id ? Theme.accent : nil)
    }

    // MARK: - Album picker

    @ViewBuilder
    private var albumPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                Button(loadingAlbums ? "LOADING ALBUMS..." : "CHOOSE ALBUM") {
                    guard !loadingAlbums else { return }
                    loadingAlbums = true
                    albumStatus = nil
                    Task { await loadAlbums() }
                }
                .font(Theme.mono(19 * uiScale))
                Text("SHOWING: \(state.immichAlbumId.isEmpty ? "FAVORITES" : state.immichAlbumName.uppercased())")
                    .font(Theme.mono(17 * uiScale, weight: .medium))
                    .foregroundColor(Theme.dimText)
                if let albumStatus {
                    Text(albumStatus)
                        .font(Theme.mono(17 * uiScale, weight: .medium))
                        .foregroundColor(Theme.accent)
                }
            }
            if !albums.isEmpty {
                albumRow(id: "", name: "FAVORITES (DEFAULT)", count: nil, thumb: nil)
                ForEach(albums.prefix(25)) { album in
                    albumRow(id: album.id, name: album.albumName.uppercased(),
                             count: album.assetCount, thumb: albumThumbs[album.id])
                }
                if albums.count > 25 {
                    caption("Showing the 25 largest albums.")
                }
            }
        }
    }

    private func albumRow(id: String, name: String, count: Int?, thumb: UIImage?) -> some View {
        let selected = state.immichAlbumId == id
        return Button {
            state.immichAlbumId = id
            state.immichAlbumName = id.isEmpty ? "" : name.capitalized
            Task { await state.reload() } // refresh the guide's channel summary
        } label: {
            HStack(spacing: 14) {
                Group {
                    if let thumb {
                        Image(uiImage: thumb)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ZStack {
                            Color(white: 0.15)
                            Image(systemName: id.isEmpty ? "heart.fill" : "photo")
                                .font(.system(size: 18 * uiScale))
                                .foregroundColor(Theme.dimText)
                        }
                    }
                }
                .frame(width: 52 * uiScale, height: 52 * uiScale)
                .clipped()
                .cornerRadius(6)
                Text(name)
                    .font(Theme.mono(19 * uiScale, weight: .medium))
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(Theme.mono(17 * uiScale, weight: .medium))
                        .foregroundColor(Theme.dimText)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .foregroundColor(Theme.onAir)
                }
            }
        }
    }

    private func loadAlbums() async {
        defer { loadingAlbums = false }
        guard let client = ImmichClient(urlString: immichURLText, apiKey: immichKeyText) else {
            albumStatus = "ENTER THE URL AND API KEY FIRST"
            return
        }
        do {
            let fetched = try await client.fetchAlbums().filter { $0.assetCount > 0 }
            albums = fetched
            albumStatus = fetched.isEmpty ? "NO ALBUMS FOUND" : nil
            // Thumbnails for the visible rows, best-effort.
            for album in fetched.prefix(25) {
                guard let assetId = album.albumThumbnailAssetId, albumThumbs[album.id] == nil else { continue }
                if let (data, response) = try? await URLSession.shared.data(for: client.thumbnailRequest(assetId: assetId)),
                   (response as? HTTPURLResponse)?.statusCode == 200,
                   let image = UIImage(data: data) {
                    albumThumbs[album.id] = image
                }
            }
        } catch {
            albumStatus = "CAN'T LOAD ALBUMS — DOES THE KEY HAVE album.read?"
        }
    }

    // MARK: - Entity suggestions

    /// A SUGGEST button + tappable rows that add/remove entity ids from a
    /// comma-separated field. Rows show a checkmark once included.
    private func suggestionControl(_ key: String,
                                   suggestions: [AppState.SuggestedEntity],
                                   listText: Binding<String>,
                                   buttonTitle: String,
                                   load: @escaping () async -> [AppState.SuggestedEntity],
                                   assign: @escaping ([AppState.SuggestedEntity]) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Button(suggesting.contains(key) ? "SEARCHING..." : buttonTitle) {
                    guard !suggesting.contains(key) else { return }
                    suggesting.insert(key)
                    Task {
                        assign(await load())
                        suggesting.remove(key)
                    }
                }
                .font(Theme.mono(19 * uiScale))
                if suggestions.isEmpty, !suggesting.contains(key) {
                    Text("USES THE HOME ASSISTANT URL AND TOKEN")
                        .font(Theme.mono(15 * uiScale, weight: .medium))
                        .foregroundColor(Theme.dimText)
                }
            }
            ForEach(suggestions) { suggestion in
                let included = entityList(listText.wrappedValue).contains(suggestion.id)
                Button {
                    toggleEntity(suggestion.id, in: listText)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: included ? "checkmark.circle.fill" : "plus.circle")
                            .foregroundColor(included ? Theme.onAir : Theme.dimText)
                        Text(suggestion.id)
                            .font(Theme.mono(18 * uiScale, weight: .medium))
                            .lineLimit(1)
                        Text(suggestion.detail)
                            .font(Theme.mono(16 * uiScale, weight: .medium))
                            .foregroundColor(Theme.dimText)
                        Spacer()
                    }
                }
            }
        }
    }

    private func entityList(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func toggleEntity(_ id: String, in text: Binding<String>) {
        var list = entityList(text.wrappedValue)
        if let index = list.firstIndex(of: id) {
            list.remove(at: index)
        } else {
            list.append(id)
        }
        text.wrappedValue = list.joined(separator: ", ")
    }

    // MARK: - Chrome

    @ViewBuilder
    private var unsavedBanner: some View {
        if hasUnsavedChanges {
            Text("● UNSAVED CHANGES — PRESS SAVE BELOW")
                .font(Theme.mono(19 * uiScale, weight: .medium))
                .foregroundColor(.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color(red: 0.95, green: 0.78, blue: 0.12))
                .cornerRadius(6)
        }
    }

    private var buttonRow: some View {
        VStack(spacing: 14) {
            unsavedBanner
            HStack(spacing: 24) {
                Button(testing ? "TESTING..." : "TEST") {
                    guard !testing else { return }
                    testing = true
                    testResult = nil
                    Task {
                        testResult = await state.testConnection(to: urlText)
                        testing = false
                    }
                }
                Button(hasUnsavedChanges ? "SAVE ●" : "SAVE") { save() }
                if !isFirstRun || state.isDemoMode {
                    Button("CANCEL") {
                        state.showSettings = false
                    }
                }
            }
            .font(Theme.mono(24 * uiScale))
        }
    }

    @ViewBuilder
    private var demoSection: some View {
        VStack(spacing: 14) {
            Rectangle()
                .fill(Color(white: 0.25))
                .frame(maxWidth: 700, maxHeight: 2)
            if state.isDemoMode {
                Button("EXIT DEMO") {
                    state.exitDemo()
                }
                .font(Theme.mono(24 * uiScale))
                Text("Clears the sample channels and returns to setup.")
                    .font(.system(size: 18 * uiScale))
                    .foregroundColor(Theme.dimText)
            } else {
                Button("TRY THE DEMO") {
                    state.startDemo()
                }
                .font(Theme.mono(24 * uiScale))
                Text("No Tunarr server? Explore the guide with sample channels and test-pattern video.")
                    .font(.system(size: 18 * uiScale))
                    .foregroundColor(Theme.dimText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.top, 8)
    }

    private var aboutSection: some View {
        VStack(spacing: 6) {
            Text("BASIC CABLE \(Self.versionString)")
                .font(Theme.mono(17 * uiScale, weight: .medium))
                .foregroundColor(Theme.dimText)
            Text("MIT-LICENSED OPEN SOURCE — GITHUB.COM/DBDMDBDMDBDM/BASIC-CABLE")
                .font(Theme.mono(15 * uiScale, weight: .medium))
                .foregroundColor(Theme.dimText)
            Text("WEATHER DATA BY OPEN-METEO.COM (CC BY 4.0), OR YOUR HA WEATHER ENTITY IF SET")
                .font(Theme.mono(15 * uiScale, weight: .medium))
                .foregroundColor(Theme.dimText)
            #if os(iOS)
            Link("ENJOYING IT? BUY ME A COFFEE",
                 destination: URL(string: "https://buymeacoffee.com/dbdmdbdmdbdm")!)
                .font(Theme.mono(15 * uiScale, weight: .medium))
                .foregroundColor(Color(red: 0.95, green: 0.78, blue: 0.12))
            #else
            // No browser on tvOS — just show the address.
            Text("ENJOYING IT? BUYMEACOFFEE.COM/DBDMDBDMDBDM")
                .font(Theme.mono(15 * uiScale, weight: .medium))
                .foregroundColor(Color(red: 0.95, green: 0.78, blue: 0.12))
            #endif
        }
        .padding(.top, 24)
        .multilineTextAlignment(.center)
    }

    private static var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        // Commit stamped at build time — lets anyone match this binary to
        // the exact source on GitHub (see VERIFYING.md in the repo).
        if let commit = Bundle.main.object(forInfoDictionaryKey: "GitCommit") as? String {
            return "V\(version) (\(build)) · \(commit.uppercased())"
        }
        return "V\(version) (\(build))"
    }

    private func save() {
        if state.isDemoMode {
            // Connecting a real server replaces the demo.
            state.exitDemo(returnToSetup: false)
        }
        state.serverURLString = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.manualLocation = locationText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.haURLString = haURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.haToken = haTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.haSensorEntities = haSensorsText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.haWeatherEntity = haWeatherText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.haCameraEntities = haCamerasText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.dashImageURLString = dashURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.immichURLString = immichURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.immichAPIKey = immichKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.mediaPlayerEntities = mediaPlayersText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.showSettings = false
        Task {
            await state.reload()
            await state.refreshWeather(force: true)
        }
    }

    /// Shown wherever the add-on's app config takes precedence.
    @ViewBuilder
    /// A setting the add-on currently manages: shown read-only and greyed
    /// so it's obvious the app isn't using the local value, with a pointer
    /// to where it's actually edited.
    private func managedField(_ label: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("🔒 \(label) — MANAGED BY THE ADD-ON")
                .font(Theme.mono(18 * uiScale))
                .foregroundColor(Theme.onAir)
            Text(values.isEmpty ? "—" : values.joined(separator: ", "))
                .font(Theme.mono(20 * uiScale, weight: .medium))
                .foregroundColor(Theme.dimText)
                .opacity(0.55)
            Text("Edit in Home Assistant → BASIC CABLE in the sidebar. Turn off the add-on's app-config switch to edit on-device instead.")
                .font(.system(size: 15 * uiScale))
                .foregroundColor(Theme.dimText)
                .opacity(0.7)
        }
        .frame(maxWidth: 1000, alignment: .leading)
    }

    /// A TEST button + result line + optional preview image for one
    /// integration section. Tests run against the current field text,
    /// like the Tunarr TEST button, so nothing needs saving first.
    private func testControl(_ key: String,
                             run: @escaping () async -> AppState.IntegrationTestResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Button(integrationTesting.contains(key) ? "TESTING..." : "TEST") {
                    guard !integrationTesting.contains(key) else { return }
                    integrationTesting.insert(key)
                    integrationResults[key] = nil
                    Task {
                        integrationResults[key] = await run()
                        integrationTesting.remove(key)
                    }
                }
                .font(Theme.mono(19 * uiScale))
                if let result = integrationResults[key] {
                    Text(result.message)
                        .font(Theme.mono(17 * uiScale, weight: .medium))
                        .foregroundColor(result.isSuccess ? Theme.onAir : Theme.accent)
                        .lineLimit(2)
                }
            }
            if let preview = integrationResults[key]?.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200 * uiScale)
                    .cornerRadius(6)
            }
        }
    }

    /// Show/hide state for one camera in the grid. Applied immediately
    /// (like the iCloud toggle) rather than on SAVE.
    private func cameraVisibilityBinding(_ entityId: String) -> Binding<Bool> {
        Binding(
            get: { !state.hiddenCameraIds.contains(entityId) },
            set: { show in
                if show {
                    state.hiddenCameraIds.remove(entityId)
                } else {
                    state.hiddenCameraIds.insert(entityId)
                }
            }
        )
    }

    // MARK: - Building blocks

    /// One settings section as a card: the channel's guide color tints the
    /// whole background and border, so sections read as distinct blocks.
    private func section<Content: View>(_ title: String, tint: Color,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 22 * uiScale) {
            HStack(spacing: 12 * uiScale) {
                Rectangle()
                    .fill(tint)
                    .frame(width: 16 * uiScale, height: 16 * uiScale)
                Text(title)
                    .font(Theme.mono(24 * uiScale))
                    .foregroundColor(.white)
                Spacer(minLength: 0)
            }
            content()
        }
        .padding(28 * uiScale)
        .frame(maxWidth: 1080)
        .background(RoundedRectangle(cornerRadius: 14).fill(tint.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.35), lineWidth: 2))
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 17 * uiScale))
            .foregroundColor(Theme.dimText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(Theme.mono(18 * uiScale))
                .foregroundColor(Theme.dimText)
            TextField(placeholder, text: text)
                .font(Theme.mono(24 * uiScale, weight: .medium))
        }
        .frame(maxWidth: 1000)
    }
}
