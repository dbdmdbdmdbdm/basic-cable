import SwiftUI

struct InfoPanelView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = state.displayedEntry,
               let channel = state.channel(withId: entry.channelId) {
                header(channel: channel)
                Text(entry.title)
                    .font(Theme.mono(38))
                    .foregroundColor(Theme.panelText)
                    .lineLimit(1)

                HStack(spacing: 14) {
                    Text(entry.isSynthetic
                        ? "ALL DAY"
                        : "\(Theme.timeFormatter.string(from: entry.start)) - \(Theme.timeFormatter.string(from: entry.stop))")
                        .font(Theme.mono(24, weight: .medium))
                        .foregroundColor(Theme.panelText)
                    if let episodeLabel = entry.episodeLabel {
                        badge(episodeLabel)
                    }
                    if let year = entry.year {
                        badge(String(year))
                    }
                }

                if !entry.isSynthetic, entry.airs(at: state.now) {
                    progressRow(for: entry)
                }

                if let subtitle = entry.subtitle {
                    Text(subtitle)
                        .font(Theme.mono(22, weight: .medium))
                        .foregroundColor(Theme.dimText)
                        .lineLimit(1)
                }

                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 19))
                        .foregroundColor(Theme.dimText)
                        .lineLimit(2)
                }
            } else if let error = state.loadError {
                Text("NO SIGNAL")
                    .font(Theme.mono(38))
                    .foregroundColor(Theme.accent)
                Text(error)
                    .font(Theme.mono(20, weight: .medium))
                    .foregroundColor(Theme.dimText)
            } else {
                Text("BASIC CABLE")
                    .font(Theme.mono(38))
                    .foregroundColor(Theme.panelText)
                Text("LOADING GUIDE...")
                    .font(Theme.mono(20, weight: .medium))
                    .foregroundColor(Theme.dimText)
            }

            Spacer(minLength: 0)
            ControlClusterView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func header(channel: Channel) -> some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 5, height: 22)
            ChannelLogoView(channel: channel, size: 30)
            Text("\(channel.number)  \(channel.name.uppercased())")
                .font(Theme.mono(24))
                .foregroundColor(Theme.panelText)
            if let tuned = state.tunedChannel, tuned.id == channel.id {
                Text("● ON NOW")
                    .font(Theme.mono(18, weight: .medium))
                    .foregroundColor(Theme.onAir)
            }
        }
    }

    private func progressRow(for entry: GuideEntry) -> some View {
        let total = entry.stop.timeIntervalSince(entry.start)
        let fraction = total > 0
            ? min(max(state.now.timeIntervalSince(entry.start) / total, 0), 1)
            : 0
        let minutesLeft = max(0, Int(ceil(entry.stop.timeIntervalSince(state.now) / 60)))

        return HStack(spacing: 14) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(white: 0.25))
                    .frame(width: 360, height: 8)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.onAir)
                    .frame(width: 360 * fraction, height: 8)
            }
            Text("\(minutesLeft) MIN LEFT")
                .font(Theme.mono(18, weight: .medium))
                .foregroundColor(Theme.dimText)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(18))
            .foregroundColor(.black)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(white: 0.8))
            .cornerRadius(4)
    }
}

struct ControlClusterView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            // Channel zapping lives on the remote in fullscreen; the mini
            // player is the fullscreen affordance. Settings is all that's left.
            controlButton("SETTINGS", systemImage: "gearshape") { state.showSettings = true }
        }
    }

    private func controlButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ControlButtonLabel(label: label, systemImage: systemImage)
        }
        .buttonStyle(RetroCellButtonStyle())
    }
}

struct ControlButtonLabel: View {
    @Environment(\.isFocused) private var isFocused
    let label: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .bold))
            Text(label)
                .font(Theme.mono(16))
        }
        .foregroundColor(.white)
        .frame(width: 128, height: 72)
        .background(isFocused ? Color(white: 0.32) : Theme.controlBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isFocused ? Color.white : Color.clear, lineWidth: 3)
        )
        .cornerRadius(6)
    }
}

/// Passthrough button style so cells render their own focus treatment
/// instead of tvOS's default lift/shadow card effect.
struct RetroCellButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
