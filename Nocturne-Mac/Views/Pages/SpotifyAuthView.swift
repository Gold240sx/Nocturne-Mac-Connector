import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct SpotifyAuthView: View {
    @EnvironmentObject var spotify: SpotifyService
    var onLinked: (() -> Void)? = nil

    @State private var loading = false
    @State private var errorMessage: String? = nil
    @State private var wasLinked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spotify")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Text("Link your Spotify account to control playback on your Car Thing.")
                    .foregroundStyle(Theme.secondary)
            }

            switch spotify.authState {
            case .linked(let displayName):
                linkedCard(displayName: displayName)
            case .polling(_, let userCode, let verificationURI, _):
                pollingCard(userCode: userCode, verificationURI: verificationURI)
            case .loading:
                loadingCard()
            case .idle, .skipped:
                idleCard()
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.destructive)
            }
        }
        .onChange(of: spotify.authState) { _, newValue in
            let isLinked = newValue.isLinked
            if isLinked && !wasLinked { onLinked?() }
            wasLinked = isLinked
        }
        .onAppear {
            wasLinked = spotify.authState.isLinked
        }
    }

    private func linkedCard(displayName: String?) -> some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: "music.note")
                    .font(.system(size: 22))
                    .frame(width: 44, height: 44)
                    .background(Theme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 11))
                    .foregroundStyle(Theme.success)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connected to Spotify")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.fg)
                    Text(displayName ?? "Spotify User")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button("Disconnect") {
                    Task { await spotify.disconnect() }
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
        }
    }

    private func pollingCard(userCode: String, verificationURI: String) -> some View {
        Card {
            VStack(spacing: 14) {
                Text("Waiting for Spotify Authorization")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.fg)
                Text("A browser tab should have opened automatically. Sign in to Spotify there to finish linking.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Circle().frame(width: 6, height: 6).foregroundStyle(Theme.accent).opacity(0.6)
                    Text("Waiting for authorization...")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
                HStack(spacing: 8) {
                    Button("Reopen Spotify page") {
                        #if canImport(AppKit)
                        if let url = URL(string: verificationURI) {
                            NSWorkspace.shared.open(url)
                        }
                        #endif
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                    Button("Cancel") {
                        spotify.cancelAuthorization()
                    }
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func loadingCard() -> some View {
        Card {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small).tint(Theme.muted)
                Text("Starting authorization...")
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }

    private func idleCard() -> some View {
        Card {
            VStack(spacing: 14) {
                Image(systemName: "music.note")
                    .font(.system(size: 26))
                    .frame(width: 56, height: 56)
                    .background(Theme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(Theme.success)
                Text("Link your Spotify account")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Theme.fg)
                Text("Connect your Spotify account to enable playback control on your Car Thing.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                Button(loading ? "Starting..." : "Link Spotify") {
                    startAuth()
                }
                .buttonStyle(PrimaryButtonStyle(prominent: true))
                .disabled(loading)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private func startAuth() {
        loading = true
        errorMessage = nil
        Task {
            do {
                try await spotify.startDeviceAuthorization()
            } catch {
                errorMessage = error.localizedDescription
            }
            loading = false
        }
    }
}
