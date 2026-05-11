import Foundation
import os
#if canImport(AppKit)
import AppKit
#endif

/// Reads Spotify's currently-playing track via AppleScript, talking directly to
/// the running Spotify.app. This is the only way to get track metadata on
/// macOS 14.4+ where MediaRemote reads are gated to system-signed processes.
///
/// Requires Spotify to be running locally. The first call triggers the macOS
/// Automation permission prompt ("Nocturne-Mac wants to control Spotify"); if
/// the user denies it, all subsequent reads return nil and the access state
/// reflects `.permissionDenied`.
@MainActor
final class SpotifyAppleScriptReader {
    enum AccessState: Equatable {
        case unknown          // haven't tried yet
        case notRunning       // Spotify.app isn't open
        case permissionDenied // Automation permission denied (errno -1743)
        case otherError(Int)  // some other AppleScript error
        case ok               // last call succeeded; have data
        case noTrack          // succeeded but no current track
    }

    private let log = Log.make(for: "SpotifyAppleScriptReader")
    private var cachedScript: NSAppleScript?
    private(set) var accessState: AccessState = .unknown

    private static let scriptSource = """
    on snapshot()
        try
            if application "Spotify" is not running then return ""
        on error
            return ""
        end try

        tell application "Spotify"
            try
                set isPlaying to player state is playing
                set tk to current track
                set theName to (name of tk) as string
                set theArtist to (artist of tk) as string
                set theAlbum to (album of tk) as string
                set theDuration to (duration of tk) as integer  -- ms
                set thePosition to (player position * 1000) as integer  -- s → ms
                set artUrl to ""
                try
                    set artUrl to (artwork url of tk) as string
                end try
                return (theName & "\\t" & theArtist & "\\t" & theAlbum & "\\t" & ¬
                        theDuration & "\\t" & thePosition & "\\t" & ¬
                        (isPlaying as text) & "\\t" & artUrl)
            on error
                return ""
            end try
        end tell
    end snapshot

    return snapshot()
    """

    var isAvailable: Bool {
        #if canImport(AppKit)
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == "com.spotify.client"
        }
        #else
        return false
        #endif
    }

    /// Open the macOS System Settings pane where the user can flip Automation
    /// for this app on. Called when we detect permission denial.
    func openAutomationSettings() {
        #if canImport(AppKit)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    /// Runs the AppleScript and returns a parsed `NowPlayingState`, or nil if
    /// Spotify isn't running, Automation permission was denied, or there's no
    /// current track. `accessState` is always updated.
    func snapshot() -> NowPlayingState? {
        guard isAvailable else {
            accessState = .notRunning
            return nil
        }

        if cachedScript == nil {
            cachedScript = NSAppleScript(source: Self.scriptSource)
        }
        guard let script = cachedScript else { return nil }

        var errorInfo: NSDictionary?
        let descriptor = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? ""
            if code == -1743 || code == -600 {
                accessState = .permissionDenied
                log.warning("AppleScript Automation denied (code \(code, privacy: .public)). Grant in System Settings → Privacy & Security → Automation → Nocturne-Mac → Spotify.")
            } else if code != 0 {
                accessState = .otherError(code)
                log.warning("AppleScript error \(code, privacy: .public): \(msg, privacy: .public)")
            }
            return nil
        }

        let raw = descriptor.stringValue ?? ""
        if raw.isEmpty {
            accessState = .noTrack
            return nil
        }

        let parts = raw.components(separatedBy: "\t")
        guard parts.count >= 6 else {
            accessState = .noTrack
            return nil
        }

        let name = parts[0]
        let artist = parts[1]
        let album = parts[2]
        let durationMs = Int(parts[3]) ?? 0
        let positionMs = Int(parts[4]) ?? 0
        let isPlaying = parts[5].lowercased() == "true"
        let artURL = parts.count > 6 ? URL(string: parts[6]) : nil

        accessState = .ok
        return NowPlayingState(
            isPlaying: isPlaying,
            trackName: name.isEmpty ? nil : name,
            artistName: artist.isEmpty ? nil : artist,
            albumName: album.isEmpty ? nil : album,
            albumArtURL: artURL,
            deviceName: "Spotify",
            progressMs: positionMs > 0 ? positionMs : nil,
            durationMs: durationMs > 0 ? durationMs : nil,
            canSeek: !name.isEmpty,
            canSkipNext: !name.isEmpty,
            canSkipPrev: !name.isEmpty
        )
    }

    /// Sends a transport command via AppleScript. Spotify exposes `playpause`,
    /// `next track`, `previous track`.
    func send(command: TransportCommand) {
        guard isAvailable else { return }
        let cmd: String
        switch command {
        case .playPause: cmd = "playpause"
        case .next: cmd = "next track"
        case .previous: cmd = "previous track"
        case .play: cmd = "play"
        case .pause: cmd = "pause"
        }
        let src = """
        tell application "Spotify"
            try
                \(cmd)
            end try
        end tell
        """
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: src)
        _ = script?.executeAndReturnError(&errorInfo)
    }

    enum TransportCommand {
        case playPause, play, pause, next, previous
    }

    /// Set Spotify's playback volume (0–100). Uses Spotify's AppleScript
    /// `sound volume` property — same Automation permission as everything else
    /// in this reader.
    func setVolume(percent: Int) {
        guard isAvailable else {
            log.warning("setVolume(\(percent)) skipped — Spotify isn't running")
            return
        }
        let src = """
        tell application "Spotify"
            set sound volume to \(percent)
        end tell
        """
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: src)
        _ = script?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            let msg = (errorInfo[NSAppleScript.errorMessage] as? String) ?? ""
            log.warning("setVolume(\(percent)) failed code=\(code) msg=\(msg)")
        }
    }

    /// Toggle Spotify shuffle on/off.
    func setShuffle(_ on: Bool) {
        guard isAvailable else { return }
        let src = """
        tell application "Spotify"
            set shuffling to \(on ? "true" : "false")
        end tell
        """
        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            log.warning("setShuffle(\(on)) failed code=\(code)")
        }
    }

    /// Set Spotify repeat mode. Accepts the Car Thing's strings: "off",
    /// "context" (repeat all), "track" (repeat one).
    func setRepeat(mode: String) {
        guard isAvailable else { return }
        let m = mode.lowercased()
        let body: String
        switch m {
        case "track", "one", "single":
            body = "set repeating to true\nset repeating track to true"
        case "context", "all", "playlist":
            body = "set repeating to true\nset repeating track to false"
        default:
            body = "set repeating to false"
        }
        let src = """
        tell application "Spotify"
            \(body)
        end tell
        """
        var errorInfo: NSDictionary?
        _ = NSAppleScript(source: src)?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            log.warning("setRepeat(\(mode)) failed code=\(code)")
        }
    }

    /// Explicitly trigger the macOS Automation TCC prompt for Spotify.
    /// Useful when the implicit first-run prompt was missed or dismissed and
    /// macOS now caches the denial. We just run a harmless AppleScript against
    /// Spotify — that's the same trigger the OS uses, but it'll re-prompt if
    /// the user hasn't been asked yet, or open the privacy pane otherwise.
    @discardableResult
    func requestAutomationPermission() -> Bool {
        // The most reliable way to surface the TCC prompt is to make a real
        // Apple Events call. If the user already denied it, this will fail
        // with -1743 again and we'll open System Settings as a fallback.
        let src = """
        tell application "Spotify"
            return name
        end tell
        """
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: src)
        _ = script?.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? 0
            log.info("requestAutomationPermission: AppleScript code=\(code)")
            if code == -1743 || code == -600 {
                accessState = .permissionDenied
                openAutomationSettings()
                return false
            }
        }
        accessState = .ok
        return true
    }

    /// Seek to a position in the current track (milliseconds from start).
    func seek(positionMs: Int) {
        guard isAvailable else { return }
        let seconds = Double(positionMs) / 1000.0
        let src = """
        tell application "Spotify"
            try
                set player position to \(seconds)
            end try
        end tell
        """
        var errorInfo: NSDictionary?
        let script = NSAppleScript(source: src)
        _ = script?.executeAndReturnError(&errorInfo)
    }
}
