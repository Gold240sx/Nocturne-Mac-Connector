import Foundation

/// Snapshot of the Spotify "current playback" endpoint.
/// Mirrors a small subset of GET /v1/me/player.
struct NowPlayingState: Equatable {
    var isPlaying: Bool
    var trackName: String?
    var artistName: String?
    var albumName: String?
    var albumArtURL: URL?
    var deviceName: String?
    var progressMs: Int?
    var durationMs: Int?
    var canSeek: Bool
    var canSkipNext: Bool
    var canSkipPrev: Bool

    static let empty = NowPlayingState(
        isPlaying: false,
        trackName: nil,
        artistName: nil,
        albumName: nil,
        albumArtURL: nil,
        deviceName: nil,
        progressMs: nil,
        durationMs: nil,
        canSeek: false,
        canSkipNext: false,
        canSkipPrev: false
    )
}

// MARK: - Raw API DTOs

struct SpotifyPlayerStateDTO: Decodable {
    let is_playing: Bool?
    let progress_ms: Int?
    let item: SpotifyItem?
    let device: SpotifyDeviceDTO?
    let actions: SpotifyActions?
}

struct SpotifyItem: Decodable {
    let name: String?
    let duration_ms: Int?
    let album: SpotifyAlbum?
    let artists: [SpotifyArtist]?
}

struct SpotifyAlbum: Decodable {
    let name: String?
    let images: [SpotifyImage]?
}

struct SpotifyImage: Decodable {
    let url: String?
    let width: Int?
    let height: Int?
}

struct SpotifyArtist: Decodable {
    let name: String?
}

struct SpotifyDeviceDTO: Decodable {
    let name: String?
    let id: String?
    let is_active: Bool?
}

struct SpotifyActions: Decodable {
    let disallows: [String: Bool]?
}
