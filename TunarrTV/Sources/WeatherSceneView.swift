import SwiftUI

/// Retro "Local on the 8s" style weather display, shown in place of video
/// when the synthetic weather channel is tuned. Cycles through pages.
struct WeatherSceneView: View {
    @EnvironmentObject var state: AppState
    var compact = false
    /// Extra shrink factor for small screens (iOS).
    var scale: CGFloat = 1

    @State private var page = 0
    // @State so the timer survives re-renders (a fresh publisher each render
    // would reset the 8s countdown every time AppState ticks).
    @State private var cycle = Timer.publish(every: 8, on: .main, in: .common).autoconnect()

    // Font scale for the small preview box vs fullscreen.
    private var s: CGFloat { (compact ? 0.52 : 1.0) * scale }

    private var pageCount: Int {
        state.weatherData.houseSensors.isEmpty ? 2 : 3
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.01, green: 0.03, blue: 0.20),
                    Color(red: 0.06, green: 0.14, blue: 0.45),
                ],
                startPoint: .top, endPoint: .bottom
            )

            if state.weatherData.hasForecast {
                VStack(spacing: 0) {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    tickerBar
                }
            } else {
                VStack(spacing: 12 * s) {
                    Image(systemName: "cloud.sun.fill")
                        .font(.system(size: 60 * s))
                        .foregroundColor(.yellow)
                    Text("WEATHER UNAVAILABLE")
                        .font(Theme.mono(30 * s))
                        .foregroundColor(.white)
                    Text("SET LOCATION OR HOME ASSISTANT IN SETTINGS")
                        .font(Theme.mono(18 * s, weight: .medium))
                        .foregroundColor(Color(white: 0.7))
                }
            }
        }
        .onReceive(cycle) { _ in
            withAnimation(.easeInOut(duration: 0.5)) {
                page = (page + 1) % pageCount
            }
        }
        .task { await state.refreshWeather() }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case 0: currentConditions
        case 1: forecast
        default: aroundTheHouse
        }
    }

    // MARK: - Page 1: current conditions

    private var currentConditions: some View {
        VStack(spacing: 18 * s) {
            pageHeader("CURRENT CONDITIONS")
            if let current = state.weatherData.current {
                HStack(spacing: 48 * s) {
                    VStack(spacing: 8 * s) {
                        Image(systemName: WMO.symbol(current.code))
                            .font(.system(size: 96 * s))
                            .foregroundColor(.yellow)
                        Text(WMO.description(current.code))
                            .font(Theme.mono(26 * s))
                            .foregroundColor(.white)
                    }
                    VStack(alignment: .leading, spacing: 10 * s) {
                        Text("\(Int(current.temperature.rounded()))°")
                            .font(Theme.mono(120 * s))
                            .foregroundColor(.white)
                        detailRow("FEELS LIKE", "\(Int(current.feelsLike.rounded()))°")
                        detailRow("HUMIDITY", "\(current.humidity)%")
                        detailRow("WIND", "\(WMO.compass(current.windDirection)) \(Int(current.windSpeed.rounded())) MPH")
                    }
                }
            }
        }
        .padding(30 * s)
    }

    // MARK: - Page 2: extended forecast

    private var forecast: some View {
        VStack(spacing: 20 * s) {
            pageHeader("EXTENDED FORECAST")
            HStack(spacing: 14 * s) {
                ForEach(state.weatherData.days.prefix(compact ? 5 : 7)) { day in
                    VStack(spacing: 10 * s) {
                        Text(Self.dayFormatter.string(from: day.date).uppercased())
                            .font(Theme.mono(22 * s))
                            .foregroundColor(.yellow)
                        Image(systemName: WMO.symbol(day.code))
                            .font(.system(size: 40 * s))
                            .foregroundColor(.white)
                        Text("\(Int(day.high.rounded()))°")
                            .font(Theme.mono(28 * s))
                            .foregroundColor(.white)
                        Text("\(Int(day.low.rounded()))°")
                            .font(Theme.mono(22 * s, weight: .medium))
                            .foregroundColor(Color(white: 0.65))
                        if day.precipChance >= 20 {
                            Text("\(day.precipChance)%")
                                .font(Theme.mono(17 * s, weight: .medium))
                                .foregroundColor(Color(red: 0.4, green: 0.75, blue: 1.0))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16 * s)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8 * s)
                }
            }
            .padding(.horizontal, 30 * s)
        }
        .padding(30 * s)
    }

    // MARK: - Page 3: Home Assistant sensors

    private var aroundTheHouse: some View {
        VStack(spacing: 18 * s) {
            pageHeader("AROUND THE HOUSE")
            VStack(spacing: 12 * s) {
                ForEach(state.weatherData.houseSensors) { sensor in
                    HStack {
                        Text(sensor.name)
                            .font(Theme.mono(26 * s, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                        Text(sensor.value.uppercased())
                            .font(Theme.mono(30 * s))
                            .foregroundColor(.yellow)
                    }
                    .padding(.horizontal, 24 * s)
                    .padding(.vertical, 10 * s)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(8 * s)
                }
            }
            .frame(maxWidth: 900 * s)
        }
        .padding(30 * s)
    }

    // MARK: - Chrome

    private func pageHeader(_ title: String) -> some View {
        Text(title)
            .font(Theme.mono(26 * s))
            .foregroundColor(.yellow)
            .padding(.horizontal, 20 * s)
            .padding(.vertical, 6 * s)
            .overlay(
                Rectangle()
                    .frame(height: 2)
                    .foregroundColor(.yellow),
                alignment: .bottom
            )
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 12 * s) {
            Text(label)
                .font(Theme.mono(20 * s, weight: .medium))
                .foregroundColor(Color(white: 0.65))
            Text(value)
                .font(Theme.mono(22 * s))
                .foregroundColor(.white)
        }
    }

    private var tickerBar: some View {
        HStack {
            // Attribution required by Open-Meteo's CC BY 4.0 license.
            Text("LOCAL FORECAST · WEATHER DATA BY OPEN-METEO.COM")
                .font(Theme.mono(18 * s))
                .foregroundColor(.black)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer()
            Text(Theme.timeWithPeriodFormatter.string(from: state.now).uppercased())
                .font(Theme.mono(18 * s))
                .foregroundColor(.black)
        }
        .padding(.horizontal, 24 * s)
        .padding(.vertical, 8 * s)
        .background(Color(red: 0.95, green: 0.78, blue: 0.12))
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()
}
