#if os(iOS)
import SwiftUI

/// Cast control for the fullscreen player: opens a device picker and casts the
/// tuned channel's HLS stream to a Chromecast on the LAN. Sits beside the
/// AirPlay button. Only meaningful for live Tunarr channels — synthetic
/// channels (weather/photos/cameras/dashboards) render on-device.
struct CastButton: View {
    @ObservedObject var controller: CastController
    let streamURL: URL?
    let title: String
    @State private var showPicker = false

    private var activeColor: Color { Color(red: 0.30, green: 0.85, blue: 0.45) } // Theme.onAir

    var body: some View {
        Button {
            controller.startDiscovery()
            showPicker = true
        } label: {
            Image(systemName: controller.isCasting ? "tv.fill" : "tv")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(controller.isCasting ? activeColor : .white)
                .frame(width: 48, height: 48)
                .background(Color.black.opacity(0.6))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showPicker) {
            CastPickerSheet(controller: controller, streamURL: streamURL, title: title)
                .onDisappear { if !controller.isCasting { controller.stopDiscovery() } }
        }
    }
}

private struct CastPickerSheet: View {
    @ObservedObject var controller: CastController
    let streamURL: URL?
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if controller.isCasting {
                    Section {
                        Button(controller.isPaused ? "Resume" : "Pause") { controller.togglePlayPause() }
                        Button("Stop Casting", role: .destructive) { controller.stopCasting() }
                    } header: {
                        if case let .casting(name) = controller.status {
                            Text("Casting to \(name.uppercased())")
                        }
                    }
                }

                Section("Chromecast Devices") {
                    if controller.devices.isEmpty {
                        Label("Searching…", systemImage: "magnifyingglass")
                            .foregroundColor(.secondary)
                    }
                    ForEach(controller.devices) { device in
                        Button {
                            guard let url = streamURL else { return }
                            controller.cast(to: device, url: url, title: title)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "tv")
                                Text(device.name)
                                Spacer()
                                if case let .casting(name) = controller.status, name == device.name {
                                    Image(systemName: "wifi").foregroundColor(.green)
                                }
                            }
                        }
                        .disabled(streamURL == nil)
                    }
                }

                if streamURL == nil {
                    Text("Tune to a live channel to cast — weather, photos, cameras and dashboards render on this device.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Cast")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }
}
#endif
