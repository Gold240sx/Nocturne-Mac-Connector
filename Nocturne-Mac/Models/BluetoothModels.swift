import Foundation

/// Mirrors the BluetoothDevice shape exposed by the original BlueZ adapter.
struct BTDeviceInfo: Identifiable, Equatable {
    let address: String
    var name: String
    var paired: Bool
    var connected: Bool
    var trusted: Bool
    var rssi: Int?

    var id: String { address }

    var displayName: String {
        name.isEmpty ? address : name
    }
}

/// "Pending PIN" handshake — equivalent to PairingPinEvent.
struct BTPairingPin: Equatable {
    let address: String
    let name: String
    let pin: String
}

/// Adapter / hardware state.
struct BTAdapterStatus: Equatable {
    var powered: Bool
    var discovering: Bool
}

/// A connected Car Thing.
struct BTConnection: Identifiable, Equatable {
    let devicePath: String
    let address: String
    var name: String?

    var id: String { devicePath }
}
