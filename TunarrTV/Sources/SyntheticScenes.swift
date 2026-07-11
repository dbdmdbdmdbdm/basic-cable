import SwiftUI

/// Dispatches to the right client-rendered scene for the tuned synthetic
/// channel. Used everywhere a video player would otherwise go.
struct SyntheticChannelView: View {
    @EnvironmentObject var state: AppState
    var compact = false
    var scale: CGFloat = 1

    var body: some View {
        if state.isWeatherTuned {
            WeatherSceneView(compact: compact, scale: scale)
        } else if state.isDashboardTuned {
            DashboardSceneView(compact: compact, url: state.tunedDashboardURL)
        } else if state.isPhotosTuned {
            PhotoSceneView(compact: compact)
        } else if state.isCamerasTuned {
            CamerasSceneView(compact: compact)
        }
    }
}

/// Corner badge with current conditions, togglable onto the photos and
/// cameras channels. Hidden until a forecast has loaded.
struct WeatherOverlayBadge: View {
    @EnvironmentObject var state: AppState
    var compact = false

    var body: some View {
        if let current = state.weatherData.current {
            HStack(spacing: compact ? 5 : 10) {
                Image(systemName: WMO.symbol(current.code))
                    .symbolRenderingMode(.multicolor)
                Text("\(Int(current.temperature.rounded()))° \(WMO.description(current.code))")
            }
            .font(Theme.mono(compact ? 11 : 22, weight: .medium))
            .foregroundColor(.white.opacity(0.92))
            .padding(.horizontal, compact ? 8 : 16)
            .padding(.vertical, compact ? 4 : 9)
            .background(Color.black.opacity(0.55))
            .cornerRadius(6)
            .padding(compact ? 8 : 28)
        }
    }
}

// MARK: - HA Dashboard channel

/// Shows the latest snapshot from an ha-screencap companion server (a small
/// container that renders a Home Assistant dashboard in headless Chromium —
/// tvOS has no web engine, so the pixels have to come from elsewhere).
struct DashboardSceneView: View {
    @EnvironmentObject var state: AppState
    var compact = false
    var url: URL?

    @State private var image: UIImage?
    @State private var status = "CONNECTING TO DASHBOARD..."
    @State private var consecutiveFailures = 0

    private static let refreshSeconds: UInt64 = 10

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "house.fill")
                        .font(.system(size: compact ? 30 : 54))
                        .foregroundColor(Theme.dimText)
                    Text(status)
                        .font(Theme.mono(compact ? 14 : 24))
                        .foregroundColor(Theme.dimText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            if consecutiveFailures >= 3, image != nil {
                VStack {
                    HStack {
                        Spacer()
                        Text("SIGNAL LOST — RETRYING")
                            .font(Theme.mono(compact ? 11 : 17))
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Theme.accent.opacity(0.85))
                            .cornerRadius(6)
                            .padding(compact ? 8 : 24)
                    }
                    Spacer()
                }
            }
        }
        // Keyed on the URL so zapping between dashboard channels restarts
        // the fetch loop against the right snapshot (and drops the old frame).
        .task(id: url) {
            image = nil
            consecutiveFailures = 0
            await run()
        }
    }

    private func run() async {
        guard let baseURL = url else {
            status = "SET THE DASHBOARD SNAPSHOT URL IN SETTINGS"
            return
        }
        while !Task.isCancelled {
            // Cache-bust so intermediaries never serve a stale frame.
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
            var items = components?.queryItems ?? []
            items.removeAll { $0.name == "t" }
            items.append(URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970))))
            components?.queryItems = items
            var request = URLRequest(url: components?.url ?? baseURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 8

            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let fetched = UIImage(data: data) {
                image = fetched
                consecutiveFailures = 0
            } else {
                consecutiveFailures += 1
                if image == nil {
                    status = "CAN'T REACH THE SNAPSHOT SERVER\nCHECK THE URL IN SETTINGS"
                }
            }
            try? await Task.sleep(nanoseconds: Self.refreshSeconds * 1_000_000_000)
        }
    }
}

// MARK: - Photos channel

/// Slideshow of Immich favorites: crossfaded, with a slow Ken Burns drift
/// and a retro date stamp. Rotation is a seasonal weighted shuffle (photos
/// from this time of year in past years surface more often), and two
/// portraits share the screen side by side instead of pillarboxing one.
struct PhotoSceneView: View {
    @EnvironmentObject var state: AppState
    var compact = false

    struct Pane: Equatable {
        let image: UIImage
        let date: String?
    }

    @State private var panes: [Pane] = []
    @State private var slideIndex = 0
    @State private var status = "LOADING FAVORITES..."

    private static let secondsPerPhoto: UInt64 = 12

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if !panes.isEmpty {
                    HStack(spacing: panes.count > 1 ? 4 : 0) {
                        ForEach(Array(panes.enumerated()), id: \.offset) { index, pane in
                            ZStack(alignment: .bottomLeading) {
                                KenBurnsImage(image: pane.image,
                                              zoomIn: (slideIndex + index).isMultiple(of: 2))
                                    .frame(width: (geo.size.width - CGFloat(panes.count > 1 ? 4 : 0)) / CGFloat(panes.count),
                                           height: geo.size.height)
                                    .clipped()
                                if let date = pane.date, !compact {
                                    Text(date)
                                        .font(Theme.mono(20, weight: .medium))
                                        .foregroundColor(.white.opacity(0.85))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(Color.black.opacity(0.45))
                                        .cornerRadius(6)
                                        .padding(28)
                                        // Sit above the ticker bar instead
                                        // of under it.
                                        .padding(.bottom, state.tickerEnabled ? 56 : 0)
                                }
                            }
                        }
                    }
                    .id(slideIndex)
                    .transition(.opacity)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: compact ? 30 : 54))
                            .foregroundColor(Theme.dimText)
                        Text(status)
                            .font(Theme.mono(compact ? 14 : 24))
                            .foregroundColor(Theme.dimText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                }
                // The badge stands down when the ticker is on — it already
                // shows the weather along the bottom.
                if state.weatherOverlayOnPhotos, !panes.isEmpty, !state.tickerEnabled {
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
        .animation(.easeInOut(duration: 1.2), value: slideIndex)
        // Restart the slideshow when the chosen album changes in settings.
        .task(id: state.immichAlbumId) {
            panes = []
            status = "LOADING PHOTOS..."
            await run()
        }
    }

    private func run() async {
        guard let client = state.immichClient else {
            status = "SET THE IMMICH URL AND API KEY IN SETTINGS"
            return
        }
        var assets: [ImmichAsset]
        do {
            assets = try await (state.immichAlbumId.isEmpty
                ? client.fetchFavorites()
                : client.fetchAlbumAssets(albumId: state.immichAlbumId))
        } catch {
            status = "CAN'T REACH IMMICH\nCHECK THE URL AND API KEY IN SETTINGS"
            return
        }
        guard !assets.isEmpty else {
            status = state.immichAlbumId.isEmpty
                ? "NO FAVORITES IN IMMICH YET"
                : "THAT ALBUM HAS NO PHOTOS"
            return
        }

        func download(_ asset: ImmichAsset) async -> Pane? {
            guard let (data, response) = try? await URLSession.shared.data(for: client.imageRequest(for: asset)),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { return nil }
            return Pane(image: image, date: asset.displayDate)
        }

        var queue: [ImmichAsset] = []
        while !Task.isCancelled {
            // Refill with a fresh weighted shuffle each pass so long
            // sessions don't loop verbatim.
            if queue.isEmpty { queue = ImmichAsset.seasonalShuffle(assets) }
            let asset = queue.removeFirst()

            // A portrait brings the next portrait in the queue along so
            // the pair fills the screen together.
            var picked = [asset]
            if asset.isPortrait, let mate = queue.firstIndex(where: { $0.isPortrait }) {
                picked.append(queue.remove(at: mate))
            }

            // Deleted/broken assets drop out; a surviving solo portrait
            // still shows by itself.
            var next: [Pane] = []
            for candidate in picked {
                if let pane = await download(candidate) { next.append(pane) }
            }
            guard !next.isEmpty else { continue }

            panes = next
            slideIndex += 1
            try? await Task.sleep(nanoseconds: Self.secondsPerPhoto * 1_000_000_000)
        }
    }
}

/// One slideshow frame: fills the container and slowly drifts between 1.0x
/// and 1.08x. Owns its animation state so crossfading instances (via .id)
/// don't disturb each other.
private struct KenBurnsImage: View {
    let image: UIImage
    let zoomIn: Bool
    @State private var animating = false

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .scaleEffect(animating ? (zoomIn ? 1.08 : 1.0) : (zoomIn ? 1.0 : 1.08))
            .onAppear {
                withAnimation(.linear(duration: Double(PhotoSceneView.secondsPerPhotoForZoom))) {
                    animating = true
                }
            }
    }
}

extension PhotoSceneView {
    /// Zoom runs slightly past the display time so motion never visibly stops.
    static var secondsPerPhotoForZoom: UInt64 { secondsPerPhoto + 3 }
}
