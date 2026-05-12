import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Banner that nudges the user to complete the Spotify device-authorization
/// flow so the Web API proxy unlocks. Visible on the Dashboard when the
/// Spotify Web token is missing or expired.
///
/// Without this token, the Car Thing's play/pause buttons silently no-op
/// (the firmware tries them via Spotify Connect first; without Web auth on
/// our side, that path falls through to nothing). With it, RPCManager routes
/// transport calls through `api.spotify.com/v1/me/player/*` and play/pause
/// + volume work end-to-end.
struct SpotifyLinkBanner: View {
    @EnvironmentObject var spotify: SpotifyService
    @State private var lastError: String?

    var body: some View {
        Group {
            switch spotify.authState {
            case .linked(let displayName):
                Card {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 18))
                            .frame(width: 36, height: 36)
                            .background(Theme.success.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(Theme.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Spotify linked")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.fg)
                            Text(displayName ?? "Web API transport active")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("Disconnect") {
                            Task { await spotify.disconnect() }
                        }
                        .buttonStyle(PrimaryButtonStyle(prominent: false))
                    }
                }
            case .polling(_, _, let verificationURI, _):
                Card {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "hourglass")
                            .font(.system(size: 18))
                            .frame(width: 36, height: 36)
                            .background(Theme.accent.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 9))
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Authorize on Spotify")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.fg)
                            Text("Sign in on the Spotify page that just opened in your browser.")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        VStack(spacing: 4) {
                            Button("Reopen page") {
                                #if canImport(AppKit)
                                if let url = URL(string: verificationURI) {
                                    NSWorkspace.shared.open(url)
                                }
                                #endif
                            }
                            .buttonStyle(PrimaryButtonStyle(prominent: false))
                            Button("Cancel") { spotify.cancelAuthorization() }
                                .buttonStyle(PrimaryButtonStyle(prominent: false))
                        }
                    }
                }
            case .loading:
                Card {
                    HStack(spacing: 12) {
                        ProgressView().controlSize(.small)
                        Text("Starting Spotify authorization…")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            case .idle, .skipped:
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 18))
                                .frame(width: 36, height: 36)
                                .background(Theme.accent.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 9))
                                .foregroundStyle(Theme.accent)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Link Spotify for play/pause + volume")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.fg)
                                Text("Without this, the Car Thing's transport buttons can't route through us — only skip works.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Button("Link Spotify") {
                                lastError = nil
                                Task {
                                    do {
                                        try await spotify.startDeviceAuthorization()
                                    } catch {
                                        lastError = error.localizedDescription
                                    }
                                }
                            }
                            .buttonStyle(PrimaryButtonStyle(prominent: true))
                        }
                        if let err = lastError {
                            HStack(alignment: .top, spacing: 8) {
                                Text(err)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Theme.destructive)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Button {
                                    #if canImport(AppKit)
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(err, forType: .string)
                                    #endif
                                } label: {
                                    Label("Copy", systemImage: "doc.on.doc")
                                        .labelStyle(.iconOnly)
                                }
                                .buttonStyle(PrimaryButtonStyle(prominent: false))
                                .help("Copy error to clipboard")
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.destructive.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Theme.destructive.opacity(0.25), lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }
}
