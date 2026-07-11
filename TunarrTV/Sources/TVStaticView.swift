import SwiftUI
import CoreGraphics

/// Chunky analog-TV snow, shown while a channel tunes.
struct TVStaticView: View {
    @State private var frames: [Image] = []
    @State private var frameIndex = 0
    // @State so the timer survives re-renders (AppState ticks would
    // otherwise reset a plain `let` publisher).
    @State private var flicker = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            if frames.isEmpty {
                Color.black
            } else {
                frames[frameIndex % frames.count]
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(contentMode: .fill)
            }
            ScanlinesOverlay()
        }
        .clipped()
        .onAppear {
            if frames.isEmpty {
                frames = Self.noiseFrames()
            }
        }
        .onReceive(flicker) { _ in
            frameIndex &+= 1
        }
    }

    /// Pre-render a handful of grayscale noise frames; cycling them at
    /// ~12fps reads as static without per-frame pixel generation.
    private static func noiseFrames(count: Int = 6, width: Int = 320, height: Int = 180) -> [Image] {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        return (0..<count).compactMap { _ in
            var bytes = [UInt8](repeating: 0, count: width * height)
            for i in bytes.indices {
                bytes[i] = UInt8.random(in: 0...255)
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let cgImage = CGImage(
                      width: width, height: height,
                      bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                      space: colorSpace,
                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                      provider: provider, decode: nil,
                      shouldInterpolate: false, intent: .defaultIntent
                  ) else { return nil }
            return Image(decorative: cgImage, scale: 1)
        }
    }
}

/// Faint CRT scanlines layered over the snow.
struct ScanlinesOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let lineHeight: CGFloat = 3
            VStack(spacing: lineHeight) {
                ForEach(0..<(Int(geo.size.height / (lineHeight * 2)) + 1), id: \.self) { _ in
                    Color.black.opacity(0.18)
                        .frame(height: lineHeight)
                }
            }
        }
        .allowsHitTesting(false)
    }
}
