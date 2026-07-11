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
    @State private var testResult: String?
    @State private var testing = false
    @State private var locating = false
    @State private var locationStatus: String?

    private var isFirstRun: Bool {
        state.serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                }

                field("TUNARR SERVER URL", placeholder: "http://192.168.1.100:8000", text: $urlText)

                if let testResult {
                    Text(testResult)
                        .font(Theme.mono(22 * uiScale))
                        .foregroundColor(testResult.hasPrefix("OK") ? Theme.onAir : Theme.accent)
                }

                if !isFirstRun {
                    sectionHeader("WEATHER CHANNEL")
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
                    if !isFirstRun {
                        Button("CANCEL") {
                            state.showSettings = false
                        }
                    }
                }
                .font(Theme.mono(24 * uiScale))
            }
            .padding(60 * uiScale)
        }
        .onAppear {
            urlText = state.serverURLString
            locationText = state.manualLocation
            haURLText = state.haURLString
            haTokenText = state.haToken
            haSensorsText = state.haSensorEntities
        }
    }

    private func save() {
        state.serverURLString = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.manualLocation = locationText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.haURLString = haURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.haToken = haTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.haSensorEntities = haSensorsText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.showSettings = false
        Task {
            await state.reload()
            await state.refreshWeather(force: true)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.mono(24 * uiScale))
            .foregroundColor(Theme.dimText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
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
