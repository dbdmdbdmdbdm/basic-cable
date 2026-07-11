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

    @State private var showAllSections = false

    /// First-run keeps the form to just the Tunarr URL — unless the user
    /// already runs standalone (built-in channels, no Tunarr).
    private var isFirstRun: Bool {
        state.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !state.hasStandaloneConfig
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                Text(isFirstRun ? "CONNECT TO TUNARR" : "SETTINGS")
                    .font(Theme.mono(38 * uiScale))
                    .foregroundColor(.white)

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
                    sectionHeader("WEATHER CHANNEL — \(WeatherChannel.number)", tint: Theme.cellWeather)
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
                                    locationText = locationText.isEmpty ? "" : locationText
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
                    .frame(maxWidth: 1000, alignment: .leading)
                    field("HOME ASSISTANT URL (OPTIONAL)",
                          placeholder: "http://homeassistant.local:8123", text: $haURLText)
                    field("HOME ASSISTANT LONG-LIVED TOKEN",
                          placeholder: "eyJhbGciOi...", text: $haTokenText)
                    field("HA SENSOR ENTITIES (COMMA-SEPARATED)",
                          placeholder: "sensor.outdoor_temp, sensor.pool_temp", text: $haSensorsText)
                    testControl("ha") {
                        await state.testHomeAssistant(urlString: haURLText, token: haTokenText,
                                                      sensorEntities: haSensorsText)
                    }

                    sectionHeader("SECURITY CAMERAS CHANNEL — \(CamerasChannel.number) (OPTIONAL)", tint: Theme.cellCameras)
                    field("HA CAMERA ENTITIES (COMMA-SEPARATED)",
                          placeholder: "camera.front_door, camera.backyard", text: $haCamerasText)
                    Text("Shows all cameras live in one grid as channel \(CamerasChannel.number). Uses the Home Assistant URL and token above — streams come straight from HA, full motion.")
                        .font(.system(size: 17 * uiScale))
                        .foregroundColor(Theme.dimText)
                        .frame(maxWidth: 1000, alignment: .leading)
                    testControl("cameras") {
                        await state.testCameras(urlString: haURLText, token: haTokenText,
                                                cameraEntities: haCamerasText)
                    }
                    Toggle(isOn: $state.weatherOverlayOnCameras) {
                        Text("SHOW WEATHER OVERLAY")
                            .font(Theme.mono(20 * uiScale, weight: .medium))
                    }
                    .frame(maxWidth: 1000)
                    if !state.cameraEntityIds.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(state.cameraEntityIds, id: \.self) { entityId in
                                Toggle(isOn: cameraVisibilityBinding(entityId)) {
                                    Text("SHOW \(CameraName.display(entityId))")
                                        .font(Theme.mono(20 * uiScale, weight: .medium))
                                }
                            }
                        }
                        .frame(maxWidth: 1000)
                        Text("Toggles apply immediately — hidden cameras stay in the list above.")
                            .font(.system(size: 17 * uiScale))
                            .foregroundColor(Theme.dimText)
                            .frame(maxWidth: 1000, alignment: .leading)
                    }

                    sectionHeader("HOME DASHBOARD CHANNEL — \(HADashboardChannel.number) (OPTIONAL)", tint: Theme.cellDashboard)
                    field("SNAPSHOT URLS (COMMA-SEPARATED, OPTIONAL NAME=URL)",
                          placeholder: "http://192.168.1.100:8090/latest.png, Kitchen=http://…/latest/1.png",
                          text: $dashURLText)
                    Text("Each URL becomes its own channel — the first is \(HADashboardChannel.number), extras count down from 996. Name them like \"Kitchen=http://…\". Just the server address works too (/latest.png is assumed). Snapshots come from the ha-screencap companion (Home Assistant add-on or Docker container — see the GitHub README).")
                        .font(.system(size: 17 * uiScale))
                        .foregroundColor(Theme.dimText)
                        .frame(maxWidth: 1000, alignment: .leading)
                    testControl("dashboard") {
                        await state.testDashboard(urlString: dashURLText)
                    }

                    sectionHeader("PHOTOS CHANNEL — \(PhotosChannel.number) (OPTIONAL)", tint: Theme.cellPhotos)
                    field("IMMICH URL",
                          placeholder: "http://192.168.1.100:2283", text: $immichURLText)
                    field("IMMICH API KEY",
                          placeholder: "create one in Immich under Account Settings > API Keys", text: $immichKeyText)
                    Text("Shows a slideshow of your Immich favorites as channel \(PhotosChannel.number). Create the key in Immich under Account Settings → API Keys — it only needs the asset.read and asset.view permissions (nothing else, and never write access).")
                        .font(.system(size: 17 * uiScale))
                        .foregroundColor(Theme.dimText)
                        .frame(maxWidth: 1000, alignment: .leading)
                    testControl("photos") {
                        await state.testImmich(urlString: immichURLText, apiKey: immichKeyText)
                    }
                    Toggle(isOn: $state.weatherOverlayOnPhotos) {
                        Text("SHOW WEATHER OVERLAY")
                            .font(Theme.mono(20 * uiScale, weight: .medium))
                    }
                    .frame(maxWidth: 1000)

                    sectionHeader("SYNC")
                    Toggle(isOn: $state.iCloudSyncEnabled) {
                        Text("SYNC SETTINGS VIA ICLOUD")
                            .font(Theme.mono(20 * uiScale, weight: .medium))
                    }
                    .frame(maxWidth: 1000)
                    Text("Shares these settings (including the Home Assistant token) across your devices through your own iCloud account.")
                        .font(.system(size: 17 * uiScale))
                        .foregroundColor(Theme.dimText)
                        .frame(maxWidth: 1000, alignment: .leading)
                }

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
                    Button("SAVE") { save() }
                    if !isFirstRun || state.isDemoMode {
                        Button("CANCEL") {
                            state.showSettings = false
                        }
                    }
                }
                .font(Theme.mono(24 * uiScale))

                if isFirstRun {
                    demoSection
                }

                aboutSection
            }
            .padding(60 * uiScale)
        }
        .onAppear {
            urlText = state.serverURLString
            locationText = state.manualLocation
            haURLText = state.haURLString
            haTokenText = state.haToken
            haSensorsText = state.haSensorEntities
            haCamerasText = state.haCameraEntities
            dashURLText = state.dashImageURLString
            immichURLText = state.immichURLString
            immichKeyText = state.immichAPIKey
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
            Text("WEATHER DATA BY OPEN-METEO.COM (CC BY 4.0)")
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
        state.haCameraEntities = haCamerasText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.dashImageURLString = dashURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.immichURLString = immichURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.immichAPIKey = immichKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.showSettings = false
        Task {
            await state.reload()
            await state.refreshWeather(force: true)
        }
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
        .frame(maxWidth: 1000, alignment: .leading)
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

    /// Section break: a rule across the settings column, then the title
    /// with a color chip matching the channel's guide-cell color — so the
    /// sections read as distinct blocks instead of one long form.
    private func sectionHeader(_ title: String, tint: Color = Theme.dimText) -> some View {
        VStack(alignment: .leading, spacing: 16 * uiScale) {
            Rectangle()
                .fill(Color(white: 0.24))
                .frame(height: 2)
            HStack(spacing: 12 * uiScale) {
                Rectangle()
                    .fill(tint)
                    .frame(width: 16 * uiScale, height: 16 * uiScale)
                Text(title)
                    .font(Theme.mono(24 * uiScale))
                    .foregroundColor(.white)
            }
        }
        .frame(maxWidth: 1000, alignment: .leading)
        .padding(.top, 30 * uiScale)
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
