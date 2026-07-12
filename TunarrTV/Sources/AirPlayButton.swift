#if os(iOS)
import SwiftUI
import AVKit

/// The system AirPlay route picker, styled to match the retro control chips.
/// Tapping it opens Apple's route sheet; AVPlayer then mirrors/hands off the
/// current stream to the chosen Apple TV / AirPlay 2 receiver. No third-party
/// SDK and no extra permission — this is Apple's own control.
struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = .white
    var activeTint: UIColor = UIColor(red: 0.30, green: 0.85, blue: 0.45, alpha: 1) // Theme.onAir

    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = tint
        picker.activeTintColor = activeTint
        picker.prioritizesVideoDevices = true
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint
        uiView.activeTintColor = activeTint
    }
}
#endif
