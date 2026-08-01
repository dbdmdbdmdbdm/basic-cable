import Foundation
import MediaPlayer
import UIKit

/// Feeds the system now-playing center (MPNowPlayingInfoCenter) with rich
/// metadata for the tuned channel. MediaRemote exposes this over the network,
/// so it's exactly what the Home Assistant Apple TV integration (pyatv) shows:
/// title, channel, artwork, and program progress. A raw AVPlayerLayer player
/// publishes playback STATE automatically but no metadata — without this,
/// network observers see "Basic Cable, playing" and nothing else.
@MainActor
final class NowPlayingReporter {
    /// Everything one info-center stamp needs, resolved by the caller
    /// (mix variants already collapsed to their family identity).
    struct Snapshot {
        let channelId: String
        let channelNumber: Int
        let channelName: String
        let genre: String?
        let iconURL: URL?
        let entry: GuideEntry?
        let isPaused: Bool
        let now: Date
    }

    private var artwork: [String: MPMediaItemArtwork] = [:]
    /// Channel ids whose logo fetch already ran — success or not — so a
    /// missing/broken icon isn't re-fetched on every 15s refresh.
    private var artworkAttempted: Set<String> = []
    private var currentChannelId: String?

    func clear() {
        currentChannelId = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func update(_ snapshot: Snapshot) {
        var info: [String: Any] = [
            MPNowPlayingInfoPropertyMediaType: NSNumber(value: MPNowPlayingInfoMediaType.video.rawValue),
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isPaused ? 0.0 : 1.0,
            MPNowPlayingInfoPropertyServiceIdentifier: "basic-cable",
            MPMediaItemPropertyArtist: "CH \(snapshot.channelNumber) · \(snapshot.channelName.uppercased())",
        ]
        if let genre = snapshot.genre, !genre.isEmpty {
            info[MPMediaItemPropertyGenre] = genre
        }
        if let entry = snapshot.entry {
            info[MPMediaItemPropertyTitle] = entry.title
            // Album line carries the secondary facts: episode title, S/E
            // label, year — whatever the program has.
            let details = [entry.subtitle, entry.episodeLabel, entry.year.map(String.init)]
                .compactMap { $0 }.filter { !$0.isEmpty }
            info[MPMediaItemPropertyAlbumTitle] = details.isEmpty
                ? "Basic Cable" : details.joined(separator: " · ")
            info[MPNowPlayingInfoPropertyExternalContentIdentifier] = entry.id
            // Progress = the program's position in its schedule slot, not the
            // HLS buffer — the channel is linear, so wall clock is truth.
            let duration = entry.stop.timeIntervalSince(entry.start)
            if duration > 0, !entry.isSynthetic {
                let elapsed = min(max(snapshot.now.timeIntervalSince(entry.start), 0), duration)
                info[MPMediaItemPropertyPlaybackDuration] = duration
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
            } else {
                info[MPNowPlayingInfoPropertyIsLiveStream] = true
            }
        } else {
            info[MPMediaItemPropertyTitle] = snapshot.channelName
            info[MPMediaItemPropertyAlbumTitle] = "Basic Cable"
            info[MPNowPlayingInfoPropertyIsLiveStream] = true
        }
        if let art = artwork[snapshot.channelId] {
            info[MPMediaItemPropertyArtwork] = art
        } else if let url = snapshot.iconURL {
            fetchArtwork(for: snapshot.channelId, url: url)
        }
        currentChannelId = snapshot.channelId
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// External play/pause/zap — Control Center, HomePod, and MediaRemote
    /// clients like Home Assistant. Next/previous track map to channel
    /// up/down, so HA's skip buttons surf the dial. In-app Siri remote
    /// presses still go through SwiftUI's onPlayPauseCommand, not here.
    func configureCommands(toggle: @escaping () -> Void,
                           next: @escaping () -> Void,
                           previous: @escaping () -> Void) {
        let center = MPRemoteCommandCenter.shared()
        for command in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand] {
            command.isEnabled = true
            command.addTarget { _ in
                Task { @MainActor in toggle() }
                return .success
            }
        }
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { _ in
            Task { @MainActor in next() }
            return .success
        }
        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { _ in
            Task { @MainActor in previous() }
            return .success
        }
    }

    /// Downloads and caches the channel logo, then stamps it onto the live
    /// info if that channel is still the one on screen.
    private func fetchArtwork(for channelId: String, url: URL) {
        guard !artworkAttempted.contains(channelId) else { return }
        artworkAttempted.insert(channelId)
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            let art = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            guard let self else { return }
            self.artwork[channelId] = art
            if self.currentChannelId == channelId,
               var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
                info[MPMediaItemPropertyArtwork] = art
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}
