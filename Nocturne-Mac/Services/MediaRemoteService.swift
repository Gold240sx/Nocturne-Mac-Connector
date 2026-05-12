import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif
#if canImport(MediaRemoteAdapter)
import MediaRemoteAdapter
#endif

/// macOS Now Playing reader.
///
/// On macOS 14.4+ Apple gated `MRMediaRemoteGetNowPlayingInfo` so direct calls
/// from third-party apps return an empty dict ("Operation not permitted").
/// The MediaRemoteAdapter Swift package works around this by bridging through
/// the system's entitled `/usr/bin/perl` interpreter — Perl loads a C dylib
/// via `DynaLoader` that calls MediaRemote.framework, and the resulting
/// `TrackInfo` JSON is streamed back to us over a pipe.
///
/// If the package isn't linked (e.g. building offline before package resolve),
/// this whole class compiles to a no-op stub via `#if canImport(...)`.
@MainActor
final class MediaRemoteService {
    enum AccessState: Equatable {
        case unknown
        case unavailable       // package not linked / Perl bridge failed to start
        case ok                // track info received at least once this session
        case empty             // listener started but nothing playing
        case denied            // bridge couldn't talk to MediaRemote
    }

    private let log = Log.make(for: "MediaRemoteService")

    typealias UpdateHandler = (NowPlayingState) -> Void
    var onUpdate: UpdateHandler?

    private(set) var accessState: AccessState = .unknown

    #if canImport(MediaRemoteAdapter)
    private let controller = MediaController()
    #endif

    /// Whether the underlying bridge is available. `true` once we've successfully
    /// imported MediaRemoteAdapter; doesn't guarantee data will flow.
    var isAvailable: Bool {
        #if canImport(MediaRemoteAdapter)
        return true
        #else
        return false
        #endif
    }

    init() {
        #if canImport(MediaRemoteAdapter)
        log.info("MediaRemoteAdapter ready (Perl-bridged MRMediaRemote)")
        controller.onTrackInfoReceived = { [weak self] info in
            Task { @MainActor in self?.handle(trackInfo: info) }
        }
        controller.onListenerTerminated = { [weak self] in
            Task { @MainActor in
                self?.accessState = .unavailable
                self?.log.warning("MediaRemote listener process exited")
            }
        }
        controller.onDecodingError = { [weak self] err, data in
            Task { @MainActor in
                self?.log.warning("MediaRemote JSON decode failed: \(err.localizedDescription, privacy: .public)")
            }
        }
        #else
        accessState = .unavailable
        log.warning("MediaRemoteAdapter not linked — add the SPM package")
        #endif
    }

    /// Start the background listener (Perl process). Call once at app launch;
    /// `onUpdate` will fire whenever the system's Now Playing source changes.
    func start() {
        #if canImport(MediaRemoteAdapter)
        controller.startListening()
        #endif
    }

    /// One-shot fetch (used by `NowPlayingService.refreshOnce()`).
    /// Fire-and-forget — the push listener also delivers track changes via
    /// `onTrackInfoReceived`, so we don't need to wait for this to complete.
    /// (The MediaController callback can fire more than once, which would
    /// double-resume a continuation; avoid that by not using one.)
    func refresh() async {
        #if canImport(MediaRemoteAdapter)
        controller.getTrackInfo { [weak self] info in
            Task { @MainActor [weak self] in self?.handle(trackInfo: info) }
        }
        #endif
    }

    // MARK: - Transport (routed through the Perl bridge)

    func play() {
        #if canImport(MediaRemoteAdapter)
        controller.play()
        #endif
    }

    func pause() {
        #if canImport(MediaRemoteAdapter)
        controller.pause()
        #endif
    }

    func togglePlayPause() {
        #if canImport(MediaRemoteAdapter)
        controller.togglePlayPause()
        #endif
    }

    func next() {
        #if canImport(MediaRemoteAdapter)
        controller.nextTrack()
        #endif
    }

    func previous() {
        #if canImport(MediaRemoteAdapter)
        controller.previousTrack()
        #endif
    }

    // MARK: - Translation

    #if canImport(MediaRemoteAdapter)
    private func handle(trackInfo: TrackInfo?) {
        guard let info = trackInfo?.payload else {
            // nil payload = "no media playing"
            accessState = .empty
            onUpdate?(.empty)
            return
        }
        let durationMs: Int? = info.durationMicros.map { Int($0 / 1000) }
        let progressMs: Int? = info.currentElapsedTime.map { Int($0 * 1000) }

        // The bridge gives us artwork bytes already decoded as NSImage. For the
        // Car Thing payload we need a URL, so we hand off an in-memory base64
        // data URL when artwork was returned.
        var artURL: URL? = nil
        if let b64 = info.artworkDataBase64 {
            let mime = info.artworkMimeType ?? "image/jpeg"
            artURL = URL(string: "data:\(mime);base64,\(b64)")
        }

        let state = NowPlayingState(
            isPlaying: info.isPlaying ?? false,
            trackName: info.title,
            artistName: info.artist,
            albumName: info.album,
            albumArtURL: artURL,
            deviceName: info.applicationName,
            progressMs: progressMs,
            durationMs: durationMs,
            canSeek: info.title != nil,
            canSkipNext: info.title != nil,
            canSkipPrev: info.title != nil
        )

        accessState = (info.title?.isEmpty ?? true) ? .empty : .ok
        // Per-update logging is firehose-loud during debugging — comment out
        // when you don't need to confirm MediaRemote is wired up.
        // if let title = info.title, !title.isEmpty {
        //     let app = info.applicationName ?? "?"
        //     log.info("MediaRemote: title=\(title, privacy: .public) app=\(app, privacy: .public) playing=\(info.isPlaying ?? false, privacy: .public)")
        // }
        onUpdate?(state)
    }
    #endif
}
