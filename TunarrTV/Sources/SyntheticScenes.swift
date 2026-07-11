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
            DashboardSceneView(compact: compact)
        } else if state.isPhotosTuned {
            PhotoSceneView(compact: compact)
        } else if state.isCamerasTuned {
            CamerasSceneView(compact: compact)
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
        .task { await run() }
    }

    private func run() async {
        guard let baseURL = state.dashImageURL else {
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

/// Slideshow of Immich favorites: shuffled, crossfaded, with a slow
/// Ken Burns drift and a retro date stamp.
struct PhotoSceneView: View {
    @EnvironmentObject var state: AppState
    var compact = false

    @State private var current: UIImage?
    @State private var currentDate: String?
    @State private var slideIndex = 0
    @State private var status = "LOADING FAVORITES..."

    private static let secondsPerPhoto: UInt64 = 12

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                if let current {
                    KenBurnsImage(image: current, zoomIn: slideIndex.isMultiple(of: 2))
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
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
                if let currentDate, current != nil, !compact {
                    VStack {
                        Spacer()
                        HStack {
                            Text(currentDate)
                                .font(Theme.mono(20, weight: .medium))
                                .foregroundColor(.white.opacity(0.85))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Color.black.opacity(0.45))
                                .cornerRadius(6)
                            Spacer()
                        }
                        .padding(28)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 1.2), value: slideIndex)
        .task { await run() }
    }

    private func run() async {
        guard let client = state.immichClient else {
            status = "SET THE IMMICH URL AND API KEY IN SETTINGS"
            return
        }
        var assets: [ImmichAsset]
        do {
            assets = try await client.fetchFavorites().shuffled()
        } catch {
            status = "CAN'T REACH IMMICH\nCHECK THE URL AND API KEY IN SETTINGS"
            return
        }
        guard !assets.isEmpty else {
            status = "NO FAVORITES IN IMMICH YET"
            return
        }
        var index = 0
        while !Task.isCancelled {
            let asset = assets[index % assets.count]
            index += 1
            // Reshuffle each full pass so long sessions don't loop verbatim.
            if index % assets.count == 0 { assets.shuffle() }
            guard let (data, response) = try? await URLSession.shared.data(for: client.imageRequest(for: asset)),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else {
                continue // deleted/broken asset — move on immediately
            }
            current = image
            currentDate = asset.displayDate
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
