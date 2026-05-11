import Foundation

/// `device.info` payload returned over RPC by the Car Thing.
struct CarThingInfo: Equatable {
    var device: String?
    var version: String?
    var fullVersion: String?
    var buildDate: String?
    var gitHash: String?
    var serialNumber: String?
}

/// One connected Car Thing as surfaced by the dashboard.
struct ConnectedDevice: Identifiable, Equatable {
    let id: String
    let address: String
    var info: CarThingInfo?
}

/// /api/info equivalent.
struct ConnectorInfo: Equatable {
    let version: String
    let osVersion: String
}
