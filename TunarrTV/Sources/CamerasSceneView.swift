import SwiftUI
import AVFoundation

// MARK: - HA camera stream API

/// Fetches a tokenized HLS URL for a camera entity over the Home Assistant
/// websocket API (`camera/stream`). The returned URL embeds its own access
/// token in the path, so AVPlayer can play it with no auth headers — and HA
/// proxies the camera's own stream, so there's no transcode load.
enum HACameraStream {
    enum StreamError: Error {
        case badURL
        case authFailed
        case requestFailed(String)
    }

    static func fetchStreamURL(haURLString: String, token: String, entityId: String) async throws -> URL {
        let trimmed = haURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let baseURL = URL(string: trimmed) else { throw StreamError.badURL }
        components.scheme = scheme == "https" ? "wss" : "ws"
        components.path = "/api/websocket"
        guard let wsURL = components.url else { throw StreamError.badURL }

        var request = URLRequest(url: wsURL)
        request.timeoutInterval = 10
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        func receive() async throws -> [String: Any] {
            let data: Data
            switch try await socket.receive() {
            case .string(let text): data = Data(text.utf8)
            case .data(let raw): data = raw
            @unknown default: data = Data()
            }
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        }
        func send(_ payload: [String: Any]) async throws {
            let data = try JSONSerialization.data(withJSONObject: payload)
            try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        }

        // Handshake: auth_required → auth → auth_ok.
        _ = try await receive()
        try await send(["type": "auth", "access_token": token])
        guard try await receive()["type"] as? String == "auth_ok" else {
            throw StreamError.authFailed
        }

        try await send(["id": 1, "type": "camera/stream", "entity_id": entityId])
        // Skip any unrelated frames until our result arrives.
        for _ in 0..<10 {
            let reply = try await receive()
            guard reply["id"] as? Int == 1, reply["type"] as? String == "result" else { continue }
            guard reply["success"] as? Bool == true,
                  let result = reply["result"] as? [String: Any],
                  let path = result["url"] as? String,
                  let url = URL(string: path, relativeTo: baseURL) else {
                let message = ((reply["error"] as? [String: Any])?["message"] as? String) ?? "STREAM UNAVAILABLE"
                throw StreamError.requestFailed(message)
            }
            return url.absoluteURL
        }
        throw StreamError.requestFailed("NO RESPONSE")
    }
}

/// "camera.front_door" → "FRONT DOOR"
enum CameraName {
    static func display(_ entityId: String) -> String {
        let raw = entityId.split(separator: ".").last.map(String.init) ?? entityId
        return raw.replacingOccurrences(of: "_", with: " ").uppercased()
    }
}

// MARK: - Cameras channel

/// A bank of live security-camera feeds in one grid — every visible camera
/// plays full-motion HLS at once, retro CCTV monitor style. Which cameras
/// show is toggled per-camera in Settings.
struct CamerasSceneView: View {
    @EnvironmentObject var state: AppState
    var compact = false

    var body: some View {
        let cameras = state.visibleCameraIds
        GeometryReader { geo in
            ZStack {
                Color.black
                if state.haClient == nil {
                    message("SET THE HOME ASSISTANT URL AND TOKEN IN SETTINGS")
                } else if state.cameraEntityIds.isEmpty {
                    message("ADD CAMERA ENTITIES IN SETTINGS")
                } else if cameras.isEmpty {
                    message("ALL CAMERAS HIDDEN — TOGGLE THEM ON IN SETTINGS")
                } else if !compact, cameras.count >= 2, let focus = state.cameraSpotlight {
                    spotlight(cameras, focus: focus, in: geo.size)
                } else {
                    grid(cameras, in: geo.size)
                }
                // The badge is redundant (and overlaps) when a spare slot
                // already shows the weather monitor — or when the ticker
                // is on with its own weather readout.
                if state.weatherOverlayOnCameras, !cameras.isEmpty,
                   !showsWeatherTile(cameras.count), !state.tickerEnabled {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            WeatherOverlayBadge(compact: compact)
                        }
                    }
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: compact ? 30 : 54))
                .foregroundColor(Theme.dimText)
            Text(text)
                .font(Theme.mono(compact ? 14 : 24))
                .foregroundColor(Theme.dimText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func grid(_ cameras: [String], in size: CGSize) -> some View {
        let columns = cameras.count == 1 ? 1 : (cameras.count <= 4 ? 2 : 3)
        let rows = Int(ceil(Double(cameras.count) / Double(columns)))
        let slots = rows * columns
        let tileWidth = size.width / CGFloat(columns)
        let tileHeight = size.height / CGFloat(rows)
        return VStack(spacing: 0) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        Group {
                            if index < cameras.count {
                                CameraTileView(entityId: cameras[index], index: index, compact: compact)
                            } else if index == slots - 1, state.weatherData.current != nil {
                                // The bank's spare monitor shows the weather
                                // instead of sitting dead.
                                WeatherTileView(compact: compact)
                            } else {
                                deadMonitor
                            }
                        }
                        .frame(width: tileWidth, height: tileHeight)
                    }
                }
            }
        }
    }

    /// Spotlight: the focused camera fills most of the screen with the others
    /// stacked as a filmstrip down the side. Every camera keeps a stable
    /// identity (its entity id), so changing focus only re-frames the existing
    /// players — no teardown and no re-buffering when you switch cameras.
    private func spotlight(_ cameras: [String], focus rawFocus: Int, in size: CGSize) -> some View {
        let focus = min(max(rawFocus, 0), cameras.count - 1)
        let stripWidth = min(max(size.width * 0.2, 160), 360)
        let bigWidth = size.width - stripWidth
        let others = cameras.indices.filter { $0 != focus }
        let slotHeight = size.height / CGFloat(max(others.count, 1))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(cameras.enumerated()), id: \.element) { index, entityId in
                let isFocus = index == focus
                let stripSlot = others.firstIndex(of: index) ?? 0
                CameraTileView(entityId: entityId, index: index, compact: !isFocus)
                    .frame(width: isFocus ? bigWidth : stripWidth,
                           height: isFocus ? size.height : slotHeight)
                    .position(
                        x: isFocus ? bigWidth / 2 : bigWidth + stripWidth / 2,
                        y: isFocus ? size.height / 2 : slotHeight * (CGFloat(stripSlot) + 0.5)
                    )
            }
        }
        .animation(.easeInOut(duration: 0.28), value: focus)
    }

    private func showsWeatherTile(_ count: Int) -> Bool {
        let columns = count == 1 ? 1 : (count <= 4 ? 2 : 3)
        let rows = Int(ceil(Double(count) / Double(columns)))
        return rows * columns > count && state.weatherData.current != nil
    }

    private var deadMonitor: some View {
        ZStack {
            Color.black
            Text("NO INPUT")
                .font(Theme.mono(compact ? 10 : 18))
                .foregroundColor(Color(white: 0.25))
        }
        .border(Color(white: 0.18), width: 1)
    }
}

/// One monitor in the bank: fetches its HLS URL over the HA websocket,
/// plays muted, and re-requests a fresh stream if playback dies or stalls
/// (HA reaps idle HLS sessions; a stale token means a dead item).
private struct CameraTileView: View {
    @EnvironmentObject var state: AppState
    let entityId: String
    let index: Int
    var compact = false

    @State private var player: AVPlayer?
    @State private var status = "CONNECTING..."

    var body: some View {
        ZStack {
            Color.black
            if let player {
                PlayerLayerView(player: player, gravity: .resizeAspectFill)
            } else {
                Text(status)
                    .font(Theme.mono(compact ? 10 : 18))
                    .foregroundColor(Theme.dimText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
            }
            overlay
        }
        .border(Color(white: 0.18), width: 1)
        .task(id: entityId) { await run() }
    }

    private var overlay: some View {
        let fontSize: CGFloat = compact ? 9 : 17
        return VStack {
            HStack(alignment: .top) {
                Text("CAM \(index + 1) · \(CameraName.display(entityId))")
                    .font(Theme.mono(fontSize, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black, radius: 0, x: 1, y: 1)
                    .lineLimit(1)
                Spacer()
                if player != nil {
                    RecordingDot(size: compact ? 5 : 9, fontSize: fontSize)
                }
            }
            Spacer()
            HStack {
                if player != nil {
                    TimestampView(fontSize: fontSize)
                }
                Spacer()
            }
        }
        .padding(compact ? 5 : 12)
    }

    private func run() async {
        // Tear down when the camera list changes out from under us.
        defer {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
        }
        while !Task.isCancelled {
            guard let ha = state.haClient else {
                status = "NOT CONFIGURED"
                return
            }
            do {
                let url = try await HACameraStream.fetchStreamURL(
                    haURLString: ha.baseURL.absoluteString, token: ha.token, entityId: entityId)
                guard !Task.isCancelled else { return }
                let item = AVPlayerItem(url: url)
                // Join fast: don't wait for a deep buffer before first frame
                // (matches tune() — HA serves LL-HLS, so this is seconds).
                item.preferredForwardBufferDuration = 2
                let player = self.player ?? AVPlayer()
                player.isMuted = true
                player.replaceCurrentItem(with: item)
                player.playImmediately(atRate: 1.0)
                self.player = player
                await monitor(item, on: player)
            } catch {
                player?.replaceCurrentItem(with: nil)
                player = nil
                status = "NO SIGNAL"
            }
            // Back off briefly, then request a fresh stream session.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    /// Returns when the item fails or playback freezes (~20s with no time
    /// advancing) — either way the caller re-requests a fresh stream URL.
    private func monitor(_ item: AVPlayerItem, on player: AVPlayer) async {
        var lastTime = CMTime.invalid
        var stagnantTicks = 0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if item.status == .failed { return }
            let time = item.currentTime()
            if time == lastTime {
                stagnantTicks += 1
                if stagnantTicks >= 5 { return }
            } else {
                stagnantTicks = 0
                lastTime = time
            }
            _ = player // keep a strong reference alive for the loop's duration
        }
    }
}

/// The weather channel, monitor-bank edition: fills a spare grid slot with
/// current conditions and a short forecast, styled like the other monitors.
private struct WeatherTileView: View {
    @EnvironmentObject var state: AppState
    var compact = false

    var body: some View {
        ZStack {
            // Deep weather-channel blue so it reads as its own feed.
            Color(red: 0.05, green: 0.08, blue: 0.20)
            if let current = state.weatherData.current {
                VStack(spacing: compact ? 3 : 12) {
                    HStack(spacing: compact ? 6 : 16) {
                        Image(systemName: WMO.symbol(current.code))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: compact ? 16 : 46))
                        Text("\(Int(current.temperature.rounded()))°")
                            .font(Theme.mono(compact ? 24 : 64))
                            .foregroundColor(.white)
                    }
                    Text(WMO.description(current.code))
                        .font(Theme.mono(compact ? 9 : 20, weight: .medium))
                        .foregroundColor(Color(white: 0.85))
                    if let today = state.weatherData.days.first {
                        Text("HI \(Int(today.high.rounded()))°  LO \(Int(today.low.rounded()))°")
                            .font(Theme.mono(compact ? 8 : 17, weight: .medium))
                            .foregroundColor(Color(white: 0.65))
                    }
                    if !compact {
                        HStack(spacing: 26) {
                            ForEach(state.weatherData.days.dropFirst().prefix(3)) { day in
                                VStack(spacing: 4) {
                                    Text(Self.dayName(day.date))
                                        .font(Theme.mono(14, weight: .medium))
                                        .foregroundColor(Color(white: 0.65))
                                    Image(systemName: WMO.symbol(day.code))
                                        .symbolRenderingMode(.multicolor)
                                        .font(.system(size: 18))
                                    Text("\(Int(day.high.rounded()))°")
                                        .font(Theme.mono(15, weight: .medium))
                                        .foregroundColor(.white)
                                }
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
            VStack {
                HStack {
                    Text("WX · LOCAL WEATHER")
                        .font(Theme.mono(compact ? 9 : 17, weight: .medium))
                        .foregroundColor(.white.opacity(0.9))
                        .shadow(color: .black, radius: 0, x: 1, y: 1)
                    Spacer()
                }
                Spacer()
            }
            .padding(compact ? 5 : 12)
        }
        .border(Color(white: 0.18), width: 1)
    }

    private static func dayName(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).uppercased()
    }
}

/// Classic CCTV "REC" indicator, blinking once a second.
private struct RecordingDot: View {
    let size: CGFloat
    let fontSize: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let on = Int(context.date.timeIntervalSince1970) % 2 == 0
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.red)
                    .frame(width: size, height: size)
                    .opacity(on ? 1 : 0.15)
                Text("REC")
                    .font(Theme.mono(fontSize, weight: .medium))
                    .foregroundColor(.white.opacity(0.9))
                    .shadow(color: .black, radius: 0, x: 1, y: 1)
            }
        }
    }
}

/// Burned-in date/time stamp, security-footage style.
private struct TimestampView: View {
    let fontSize: CGFloat

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd-yyyy  HH:mm:ss"
        return formatter
    }()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(Self.formatter.string(from: context.date))
                .font(Theme.mono(fontSize, weight: .medium))
                .foregroundColor(.white.opacity(0.9))
                .shadow(color: .black, radius: 0, x: 1, y: 1)
        }
    }
}
