import SwiftUI

struct NowPlayingCard: View {
    @EnvironmentObject var nowPlaying: NowPlayingService

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                // Diagnostic strip — both read sources and which one's live.
                accessDiagnosticStrip
                if let headline = nowPlaying.spotifyAccessState.headline,
                   nowPlaying.spotifyAccessState != .ok,
                   nowPlaying.spotifyAccessState != .unknown {
                    accessBanner(
                        headline: headline,
                        detail: nowPlaying.spotifyAccessState.detail ?? "",
                        showFixButton: nowPlaying.spotifyAccessState == .permissionDenied
                    )
                }
                HStack(alignment: .top, spacing: 14) {
                    artwork
                    VStack(alignment: .leading, spacing: 6) {
                        if let track = nowPlaying.state.trackName {
                            Text(track)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(Theme.fg)
                                .lineLimit(1)
                            Text(nowPlaying.state.artistName ?? "")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                            if let album = nowPlaying.state.albumName {
                                Text(album)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                            }
                        } else {
                            Text("Nothing playing")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Theme.fg)
                            Text(nowPlaying.lastError ?? "Start playback on a Spotify device to see it here.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                    if let device = nowPlaying.state.deviceName {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Playing on")
                                .font(.system(size: 10, weight: .medium))
                                .tracking(1.2)
                                .foregroundStyle(Theme.muted)
                            Text(device)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.fg)
                                .lineLimit(1)
                        }
                    }
                }

                if let progress = nowPlaying.state.progressMs,
                   let duration = nowPlaying.state.durationMs, duration > 0 {
                    ProgressView(value: Double(progress), total: Double(duration))
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                    HStack {
                        Text(format(ms: progress))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Text(format(ms: duration))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.muted)
                    }
                }

                HStack(spacing: 8) {
                    transportButton("backward.fill",
                                    enabled: nowPlaying.state.canSkipPrev,
                                    action: { Task { await nowPlaying.previous() } })
                    transportButton(nowPlaying.state.isPlaying ? "pause.fill" : "play.fill",
                                    enabled: true,
                                    prominent: true,
                                    action: { Task { await nowPlaying.togglePlayPause() } })
                    transportButton("forward.fill",
                                    enabled: nowPlaying.state.canSkipNext,
                                    action: { Task { await nowPlaying.next() } })
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        let size: CGFloat = 72
        if let url = nowPlaying.state.albumArtURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                case .failure:
                    placeholderArt
                case .empty:
                    placeholderArt
                @unknown default:
                    placeholderArt
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            placeholderArt
                .frame(width: size, height: size)
        }
    }

    private var placeholderArt: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Theme.inset)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.muted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.line, lineWidth: 1)
            )
    }

    @ViewBuilder
    private func transportButton(_ systemName: String, enabled: Bool, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 38, height: 38)
        }
        .buttonStyle(PrimaryButtonStyle(prominent: prominent))
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.5)
    }

    private func format(ms: Int) -> String {
        let totalSeconds = ms / 1000
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    /// Tiny one-line status strip showing which read sources are active.
    /// Lets you see at a glance whether MRMediaRemoteGetNowPlayingInfo is
    /// returning data on this Mac or if we're falling back to AppleScript.
    @ViewBuilder
    private var accessDiagnosticStrip: some View {
        HStack(spacing: 12) {
            sourceChip(label: "MediaRemote",
                       state: nowPlaying.mediaRemoteAccessState.shortBadge,
                       isLive: nowPlaying.source == .mediaRemote)
            sourceChip(label: "Spotify.app",
                       state: nowPlaying.spotifyAccessState.shortBadge,
                       isLive: nowPlaying.source == .spotifyApp)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func sourceChip(label: String, state: (String, Color), isLive: Bool) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(state.1)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 10, weight: isLive ? .semibold : .regular))
                .foregroundStyle(isLive ? Theme.fg : Theme.muted)
            Text(state.0)
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
        }
    }

    /// Inline banner that explains why we can't read Spotify state. Offers a
    /// "Fix Permission" button when the cause is automation-permission denial.
    @ViewBuilder
    private func accessBanner(headline: String, detail: String, showFixButton: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: showFixButton ? "lock.shield" : "info.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(showFixButton ? Theme.destructive : Theme.muted)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if showFixButton {
                VStack(spacing: 6) {
                    Button("Grant Access") {
                        nowPlaying.requestSpotifyAutomationAccess()
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: true))
                    Button("Open Settings") {
                        nowPlaying.openAutomationSettings()
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill((showFixButton ? Theme.destructive : Theme.muted).opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke((showFixButton ? Theme.destructive : Theme.muted).opacity(0.25), lineWidth: 1)
        )
    }
}
