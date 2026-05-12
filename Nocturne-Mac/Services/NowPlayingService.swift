import Foundation
import os
import Combine
import SwiftUI

/// Surfaces "what's playing right now" plus transport controls to the UI.
///
/// macOS 14.4+ blocks `MRMediaRemoteGetNowPlayingInfo` for third-party
/// processes ("Operation not permitted"), so we read directly from the running
/// Spotify.app via AppleScript instead. The send-command path of MediaRemote
/// still works (transport is unrestricted), but we use the same AppleScript
/// channel for symmetry — Spotify's `playpause/next track/previous track`
/// commands are reliable and route to the local Spotify instance.
///
/// The Spotify Web API polling has been disabled by user request to avoid the
/// 429 rate-limit storm it caused.
@MainActor
final class NowPlayingService: ObservableObject {
    private let log = Log.make(for: "NowPlayingService")
    private let spotify: SpotifyService

    @Published private(set) var state: NowPlayingState = .empty
    @Published private(set) var source: Source = .none
    @Published private(set) var spotifyAccessState: SpotifyAccess = .unknown
    @Published private(set) var mediaRemoteAccessState: MediaRemoteAccess = .unknown
    @Published var lastError: String? = nil

    enum MediaRemoteAccess: Equatable {
        case unknown, unavailable, ok, empty, denied

        var headline: String? {
            switch self {
            case .unknown: return nil
            case .ok: return "MediaRemote: returning Now Playing data"
            case .empty: return "MediaRemote: empty response"
            case .denied: return "MediaRemote: blocked by macOS"
            case .unavailable: return "MediaRemote framework not loadable"
            }
        }

        var shortBadge: (String, SwiftUI.Color) {
            switch self {
            case .unknown:    return ("…",      Theme.muted)
            case .ok:         return ("OK",     Theme.success)
            case .empty:      return ("empty",  Theme.muted)
            case .denied:     return ("blocked", Theme.destructive)
            case .unavailable: return ("n/a",   Theme.destructive)
            }
        }
    }

    enum Source: String { case none, mediaRemote, spotifyApp }
    enum SpotifyAccess: Equatable {
        case unknown
        case notRunning
        case permissionDenied
        case otherError(Int)
        case ok
        case noTrack

        var headline: String? {
            switch self {
            case .unknown, .ok: return nil
            case .notRunning: return "Spotify isn't running"
            case .noTrack: return "Spotify is idle"
            case .permissionDenied: return "Automation permission denied"
            case .otherError(let code): return "AppleScript error (\(code))"
            }
        }

        var detail: String? {
            switch self {
            case .unknown, .ok: return nil
            case .notRunning: return "Open Spotify and play something — the Car Thing will mirror it."
            case .noTrack: return "Hit play in Spotify to push the track to the Car Thing."
            case .permissionDenied:
                return "Grant Automation permission so Nocturne-Mac can read what's playing. System Settings → Privacy & Security → Automation → Nocturne-Mac → Spotify."
            case .otherError: return "An unexpected AppleScript error occurred — check Console.app for details."
            }
        }

        var shortBadge: (String, SwiftUI.Color) {
            switch self {
            case .unknown:            return ("…",         Theme.muted)
            case .notRunning:         return ("off",       Theme.muted)
            case .permissionDenied:   return ("denied",    Theme.destructive)
            case .otherError:         return ("error",     Theme.destructive)
            case .ok:                 return ("OK",        Theme.success)
            case .noTrack:            return ("idle",      Theme.muted)
            }
        }
    }

    /// Open the System Settings → Automation pane (called from the Now Playing
    /// card's "Fix permission" button when access is denied).
    func openAutomationSettings() {
        #if os(macOS)
        local.openAutomationSettings()
        #endif
    }

    /// Trigger the macOS TCC prompt asking the user to allow this app to
    /// control Spotify. Effective when the implicit prompt didn't fire or was
    /// dismissed; uses `AEDeterminePermissionToAutomateTarget(askUserIfNeeded:
    /// true)` under the hood.
    func requestSpotifyAutomationAccess() {
        #if os(macOS)
        _ = local.requestAutomationPermission()
        Task { @MainActor in await refreshOnce() }
        #endif
    }

    private var pollTask: Task<Void, Never>?
    #if os(macOS)
    private let media = MediaRemoteService()
    private let local = SpotifyAppleScriptReader()
    #endif

    init(spotify: SpotifyService) {
        self.spotify = spotify
        #if os(macOS)
        // Hook MediaRemote update callbacks before kicking off polling. Any
        // populated CFDictionary from MRMediaRemoteGetNowPlayingInfo will
        // immediately update the state and take precedence over AppleScript.
        media.onUpdate = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if newState.trackName != nil {
                    var merged = newState
                    // While the override window is active, keep the user's
                    // just-pressed isPlaying value even if MediaRemote is
                    // still serving a stale snapshot.
                    if let until = self.playStateOverrideUntil, until > Date() {
                        merged.isPlaying = self.state.isPlaying
                    } else {
                        self.playStateOverrideUntil = nil
                    }
                    self.state = merged
                    self.source = .mediaRemote
                    self.lastError = nil
                }
            }
        }
        if media.isAvailable {
            media.start()  // register distributed notifications + initial fetch
        }
        // Proactively trigger the macOS Automation TCC registration for
        // Spotify shortly after launch. The Automation pane in System
        // Settings only lists apps that have *declared* an intent to
        // automate another app via `AEDeterminePermissionToAutomateTarget`
        // (there is no "+" button to add manually) — without this, the
        // user can't find the toggle to grant the permission that's
        // required for setVolume / seek / shuffle / repeat to work.
        Task { @MainActor [weak self] in
            // Wait a beat so the app window is on-screen before the system
            // shows the consent dialog — surfacing it before any UI is up
            // looks broken to the user.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            _ = self?.local.requestAutomationPermission()
        }
        #endif
        startPolling()
    }

    // MARK: - Polling (AppleScript → Spotify.app)

    private func startPolling() {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshOnce()
                try? await Task.sleep(nanoseconds: 2 * 1_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshOnce() async {
        #if os(macOS)
        // Primary path: MRMediaRemoteGetNowPlayingInfo. If MediaRemote returned
        // a populated dict, the onUpdate handler already wrote state; we just
        // need to refresh it again here.
        if media.isAvailable {
            await media.refresh()
            mediaRemoteAccessState = Self.bridge(media.accessState)
            if case .ok = media.accessState {
                // MediaRemote produced data — done. AppleScript not needed.
                return
            }
        } else {
            mediaRemoteAccessState = .unavailable
        }

        // Fallback: read Spotify via AppleScript. Only matters when MediaRemote
        // is gated (macOS 14.4+ default behavior for third-party apps).
        let snap = local.snapshot()
        spotifyAccessState = Self.bridge(local.accessState)

        if let snap {
            state = snap
            source = .spotifyApp
            lastError = nil
            return
        }
        if source != .mediaRemote {
            state = .empty
            source = .none
            lastError = spotifyAccessState.detail
        }
        #endif
    }

    #if os(macOS)
    private static func bridge(_ reader: SpotifyAppleScriptReader.AccessState) -> SpotifyAccess {
        switch reader {
        case .unknown: return .unknown
        case .notRunning: return .notRunning
        case .permissionDenied: return .permissionDenied
        case .otherError(let c): return .otherError(c)
        case .ok: return .ok
        case .noTrack: return .noTrack
        }
    }
    private static func bridge(_ state: MediaRemoteService.AccessState) -> MediaRemoteAccess {
        switch state {
        case .unknown: return .unknown
        case .unavailable: return .unavailable
        case .ok: return .ok
        case .empty: return .empty
        case .denied: return .denied
        }
    }
    #endif


    // MARK: - Transport
    //
    // Route through MediaRemoteService (which uses the MediaRemoteAdapter Perl
    // bridge — works regardless of macOS version). Falls back to AppleScript
    // when MediaRemote can't be loaded.

    func play() async {
        #if os(macOS)
        if media.isAvailable {
            media.play()
        } else {
            local.send(command: .play)
        }
        // Optimistic local state — the Perl bridge will push the real state
        // shortly, but we want the next broadcast to reflect the user's intent
        // immediately so the Car Thing UI is responsive.
        state.isPlaying = true
        #endif
    }

    func pause() async {
        #if os(macOS)
        if media.isAvailable {
            media.pause()
        } else {
            local.send(command: .pause)
        }
        state.isPlaying = false
        #endif
    }

    func togglePlayPause() async {
        #if os(macOS)
        if media.isAvailable {
            media.togglePlayPause()
        } else {
            local.send(command: .playPause)
        }
        state.isPlaying.toggle()
        #endif
    }

    func next() async {
        #if os(macOS)
        if media.isAvailable {
            media.next()
        } else {
            local.send(command: .next)
        }
        #endif
    }

    func previous() async {
        #if os(macOS)
        if media.isAvailable {
            media.previous()
        } else {
            local.send(command: .previous)
        }
        #endif
    }

    /// Set the local Spotify.app's volume (0–100). The MediaRemoteAdapter Perl
    /// bridge doesn't expose a per-source volume setter, so we always go through
    /// Spotify's AppleScript here (requires the same Automation permission).
    func setVolume(percent: Int) {
        #if os(macOS)
        let clamped = max(0, min(100, percent))
        lastKnownVolume = clamped
        local.setVolume(percent: clamped)
        #endif
    }

    /// Increment or decrement Spotify's volume by `delta`. Used for the Car
    /// Thing's hardware +/- buttons that send `media.control.volumeUp/Down`.
    func bumpVolume(by delta: Int) {
        let next = max(0, min(100, lastKnownVolume + delta))
        setVolume(percent: next)
    }

    /// Seek to a position (milliseconds from track start).
    func seek(positionMs: Int) {
        #if os(macOS)
        local.seek(positionMs: positionMs)
        #endif
    }

    /// Set shuffle on/off via Spotify AppleScript (`set shuffling to …`).
    func setShuffle(_ on: Bool) {
        #if os(macOS)
        local.setShuffle(on)
        #endif
    }

    /// Set repeat mode. The Car Thing typically sends `"context"`, `"track"`
    /// or `"off"` — Spotify's AppleScript dictionary maps these to a single
    /// boolean `repeating`; `"track"` we map to `repeating + single`.
    func setRepeat(mode: String) {
        #if os(macOS)
        local.setRepeat(mode: mode)
        #endif
    }

    /// Best-effort tracking of the last volume we asked Spotify to set. Used by
    /// `bumpVolume(by:)` since AppleScript-read-of-current-volume needs the
    /// same Automation permission that may not be granted yet.
    private var lastKnownVolume: Int = 50

    /// Force the `state.isPlaying` flag to a known value AND mark this as an
    /// intentional override so the next MediaRemote push within ~750ms can't
    /// stomp it. Used by RPCManager right after a transport RPC so the Car
    /// Thing sees the new state before MediaRemote's polling has caught up.
    func overrideIsPlaying(_ value: Bool) {
        var next = state
        next.isPlaying = value
        state = next  // full struct reassignment guarantees @Published fires
        playStateOverrideUntil = Date().addingTimeInterval(0.75)
    }

    /// When non-nil, MediaRemote pushes that would change `isPlaying` are
    /// ignored until this date passes. Stops a stale Perl-bridge snapshot
    /// from flipping the user's just-pressed pause back to "playing".
    fileprivate var playStateOverrideUntil: Date? = nil
}
