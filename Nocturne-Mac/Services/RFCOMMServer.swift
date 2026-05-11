import Foundation
import os
#if canImport(IOBluetooth)
import IOBluetooth

/// Registers an SDP record for the Serial Port Profile (SPP, UUID 0x1101) on the
/// local macOS Bluetooth controller and listens for incoming RFCOMM channel opens.
///
/// This mirrors what the Pi connector does in `src/server/bluetooth/rfcomm-server.ts`
/// — it advertises the SPP service via BlueZ's ProfileManager, then waits for the
/// Car Thing's `nocturned` daemon to dial in.
///
/// The macOS equivalent is `IOBluetoothSDPServiceRecord.publishedServiceRecord(with:)`
/// to publish the SDP record, then
/// `IOBluetoothRFCOMMChannel.register(forChannelOpenNotifications:...)` to
/// accept the inbound channel.
@MainActor
final class RFCOMMServer {
    private let log = Log.make(for: "RFCOMMServer")

    typealias IncomingChannelHandler = (IOBluetoothRFCOMMChannel) -> Void
    var onIncomingChannel: IncomingChannelHandler?

    private(set) var registeredChannel: BluetoothRFCOMMChannelID = 0
    private(set) var lastRegistrationError: String? = nil
    private var serviceRecord: IOBluetoothSDPServiceRecord?
    private var notification: IOBluetoothUserNotification?
    private var bridge: RFCOMMServerBridge!

    init() {
        bridge = RFCOMMServerBridge(owner: self)
    }

    /// Adds the SPP service record system-wide. Returns true if registration
    /// succeeded. Safe to call repeatedly — re-publishes if a prior attempt failed.
    @discardableResult
    func register(serviceName: String = "Nocturne Connector") -> Bool {
        if serviceRecord != nil && registeredChannel > 0 { return true }

        // Sanity-check the controller is up before we ask it to publish anything.
        guard let controller = IOBluetoothHostController.default() else {
            let msg = "No Bluetooth controller available"
            lastRegistrationError = msg
            log.error("\(msg, privacy: .public)")
            return false
        }
        if controller.powerState != kBluetoothHCIPowerStateON {
            let msg = "Bluetooth is off — toggle it on in System Settings"
            lastRegistrationError = msg
            log.error("\(msg, privacy: .public)")
            return false
        }

        // SDP record for SPP. IOBluetoothSDPDataElement.h documents shortcut
        // formats: UUIDs can be NSData of length 2/4/16, numbers can be NSNumber
        // directly, sequences can be NSArrays. We use the shortcut form because
        // the verbose DataElementType/Size/Value dictionaries have failed in the
        // wild even on signed bundles.
        let sppUUID = Data([0x11, 0x01])         // SerialPort
        let l2capUUID = Data([0x01, 0x00])       // L2CAP protocol
        let rfcommUUID = Data([0x00, 0x03])      // RFCOMM protocol
        let browseUUID = Data([0x10, 0x02])      // PublicBrowseGroup

        let sppDict: [String: Any] = [
            "0001 - ServiceClassIDList": [sppUUID],
            "0004 - ProtocolDescriptorList": [
                [l2capUUID],
                [rfcommUUID, NSNumber(value: 0)]  // 0 = let system assign channel
            ],
            "0005 - BrowseGroupList": [browseUUID],
            "0100 - ServiceName*": serviceName
        ]

        // Try the shortcut form first. If that returns nil, fall back to the
        // verbose form. Logs both attempts so we can see exactly what bluetoothd
        // accepted (vs. just "got nil").
        var record: IOBluetoothSDPServiceRecord? =
            IOBluetoothSDPServiceRecord.publishedServiceRecord(with: sppDict)

        if record == nil {
            log.warning("publishedServiceRecord(short-form) returned nil; retrying with verbose dict")
            let verbose: [String: Any] = [
                "0001 - ServiceClassIDList": [
                    ["DataElementType": NSNumber(value: 3),
                     "DataElementSize": NSNumber(value: 2),
                     "DataElementValue": NSNumber(value: 0x1101)]
                ],
                "0004 - ProtocolDescriptorList": [
                    [["DataElementType": NSNumber(value: 3),
                      "DataElementSize": NSNumber(value: 2),
                      "DataElementValue": NSNumber(value: 0x0100)]],
                    [["DataElementType": NSNumber(value: 3),
                      "DataElementSize": NSNumber(value: 2),
                      "DataElementValue": NSNumber(value: 0x0003)],
                     ["DataElementType": NSNumber(value: 1),
                      "DataElementSize": NSNumber(value: 1),
                      "DataElementValue": NSNumber(value: 0)]]
                ],
                "0100 - ServiceName*": serviceName
            ]
            record = IOBluetoothSDPServiceRecord.publishedServiceRecord(with: verbose)
        }

        guard let record else {
            // Both formats failed. We'll still register for channel-open
            // notifications below so the Car Thing CAN reach us if it dials a
            // common channel directly.
            let msg = "SDP publish unavailable on this macOS. Falling back to channel-open listener (no SDP record)."
            lastRegistrationError = msg
            log.info("\(msg, privacy: .public)")
            registerChannelListenerWithoutSDP()
            return false
        }

        // After publication, ask the record back which channel the system assigned.
        var channel: BluetoothRFCOMMChannelID = 0
        let chStatus = record.getRFCOMMChannelID(&channel)
        if chStatus != kIOReturnSuccess || channel == 0 {
            let msg = "SDP record published but no RFCOMM channel assigned (status \(chStatus))."
            lastRegistrationError = msg
            log.error("\(msg, privacy: .public)")
            record.remove()
            serviceRecord = nil
            return false
        }
        registeredChannel = channel
        log.info("SDP record published for \(serviceName, privacy: .public); RFCOMM channel = \(channel, privacy: .public)")

        // Listen for inbound RFCOMM channel opens on the assigned channel.
        notification = IOBluetoothRFCOMMChannel.register(
            forChannelOpenNotifications: bridge,
            selector: #selector(RFCOMMServerBridge.rfcommChannelOpened(_:channel:)),
            withChannelID: channel,
            direction: kIOBluetoothUserNotificationChannelDirectionIncoming
        )
        if notification == nil {
            let msg = "Service published on channel \(channel), but channel-open notification registration failed."
            lastRegistrationError = msg
            log.warning("\(msg, privacy: .public)")
        } else {
            lastRegistrationError = nil
        }

        return true
    }

    /// Fallback used when publishedServiceRecord(with:) returns nil. Registers a
    /// channel-open notification listener for ANY incoming RFCOMM channel —
    /// works without publishing an SDP record. The Car Thing has to dial a
    /// channel directly (it can't discover one via SDP since we never
    /// published), so this only helps clients that probe common channels.
    private func registerChannelListenerWithoutSDP() {
        notification = IOBluetoothRFCOMMChannel.register(
            forChannelOpenNotifications: bridge,
            selector: #selector(RFCOMMServerBridge.rfcommChannelOpened(_:channel:))
        )
        if notification != nil {
            log.info("Registered channel-open listener (any channel, no SDP record)")
        } else {
            log.warning("Channel-open listener registration failed even without SDP")
        }
    }

    func unregister() {
        notification?.unregister()
        notification = nil
        if let record = serviceRecord {
            record.remove()
            serviceRecord = nil
        }
        registeredChannel = 0
    }

    fileprivate func handleIncomingChannel(_ channel: IOBluetoothRFCOMMChannel) {
        let device = channel.getDevice()
        let addr = device?.addressString ?? "?"
        let chID = channel.getID()
        log.info("Incoming RFCOMM from \(addr, privacy: .public) ch=\(chID, privacy: .public)")
        onIncomingChannel?(channel)
    }
}

/// IOBluetooth's channel-open registration uses a target + selector, so we need
/// an NSObject-derived bridge to receive the callback.
final class RFCOMMServerBridge: NSObject {
    weak var owner: RFCOMMServer?

    init(owner: RFCOMMServer) {
        self.owner = owner
        super.init()
    }

    @objc func rfcommChannelOpened(_ notification: IOBluetoothUserNotification, channel: IOBluetoothRFCOMMChannel) {
        Task { @MainActor [weak self] in
            self?.owner?.handleIncomingChannel(channel)
        }
    }
}

#endif
