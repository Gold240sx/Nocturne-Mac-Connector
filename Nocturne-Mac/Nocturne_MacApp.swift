import SwiftUI

@main
struct Nocturne_MacApp: App {
    @StateObject private var auth = AuthService()
    @StateObject private var spotify: SpotifyService
    @StateObject private var bluetooth = BluetoothService()
    @StateObject private var analytics = AnalyticsService()
    @StateObject private var nowPlaying: NowPlayingService
    @StateObject private var rpc: RPCManager

    init() {
        let spotify = SpotifyService()
        let now = NowPlayingService(spotify: spotify)
        let rpcManager = RPCManager(spotify: spotify, nowPlaying: now)
        _spotify = StateObject(wrappedValue: spotify)
        _nowPlaying = StateObject(wrappedValue: now)
        _rpc = StateObject(wrappedValue: rpcManager)
    }

    var body: some Scene {
        WindowGroup("Nocturne Connector") {
            rootContent
                .frame(minWidth: 900, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            EmptyView()
        }
    }

    private var rootContent: some View {
        RootView()
            .environmentObject(auth)
            .environmentObject(spotify)
            .environmentObject(bluetooth)
            .environmentObject(analytics)
            .environmentObject(nowPlaying)
            .environmentObject(rpc)
            .task {
                // Hook the RPC manager into the Bluetooth service so RFCOMM
                // channels are bridged into the msgpack RPC layer.
                bluetooth.rpcManager = rpc
                await auth.initialize()
                await spotify.bootstrap()
            }
    }
}
