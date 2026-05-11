import Foundation
import os
import Combine
#if canImport(IOBluetooth)
import IOBluetooth
#endif

#if canImport(IOBluetooth)

/// Bluetooth Classic + RFCOMM, replacing the BlueZ/dbus-next-based implementation
/// in src/server/bluetooth/.
///
/// macOS uses IOBluetooth (not CoreBluetooth) for Classic / SPP / RFCOMM. CoreBluetooth
/// is BLE-only and the Car Thing speaks Classic Bluetooth + RFCOMM (SPP, UUID
/// 00001101-0000-1000-8000-00805F9B34FB).
///
/// IOBluetooth's APIs are objc-style and require an NSObject-derived delegate, so
/// the actual delegate plumbing is in `BluetoothDelegateBridge` below.
@MainActor
final class BluetoothService: ObservableObject {
    private let log = Log.make(for: "BluetoothService")

    @Published private(set) var status: BTAdapterStatus = BTAdapterStatus(powered: false, discovering: false)
    @Published private(set) var devices: [BTDeviceInfo] = []
    @Published private(set) var connections: [BTConnection] = []
    @Published private(set) var pendingPin: BTPairingPin? = nil
    @Published var lastError: String? = nil

    /// Optional RPC manager. When set, every RFCOMM channel that opens is
    /// attached to it and inbound bytes are forwarded for msgpack decoding.
    weak var rpcManager: RPCManager?

    private var bridge: BluetoothDelegateBridge!
    private var inquiry: IOBluetoothDeviceInquiry?
    /// Map of (address, channelID) → channel. We can have multiple channels
    /// open to the same device simultaneously — the Pi connector keeps one
    /// inbound (ch 1) and one outbound (ch 2). Keying by address alone would
    /// lose the first channel when the second one opens.
    private var activeChannels: [String: IOBluetoothRFCOMMChannel] = [:]
    private func channelKey(address: String, id: BluetoothRFCOMMChannelID) -> String {
        "\(address)#\(id)"
    }
    private var pairing: IOBluetoothDevicePair?
    private let server = RFCOMMServer()

    /// Channel number our SPP SDP record was published on (system-assigned).
    /// Surfaced so it can be displayed for debugging.
    var serverChannel: BluetoothRFCOMMChannelID { server.registeredChannel }

    /// Why SDP publication failed, if it did. Shown in the Dashboard banner.
    var serverError: String? { server.lastRegistrationError }

    /// Re-attempt SPP publication. Bound to the Dashboard banner's "Republish" button.
    func republishSPPService() {
        startSPPServer()
        // Force a @Published refresh so the banner re-renders.
        objectWillChange.send()
    }

    init() {
        bridge = BluetoothDelegateBridge(service: self)
        refreshAdapterStatus()
        loadPairedDevices()
        startSPPServer()
        // Try to reconnect to any already-paired Car Things at launch — but
        // ONLY to devices that look like Car Things. We can't blindly RFCOMM
        // every paired device (AirPods, keyboards, etc.); that would queue up
        // dozens of failed channel-opens.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let candidates = devices.filter { d in
                d.paired && !d.connected && Self.looksLikeCarThing(name: d.name)
            }
            log.info("Launch auto-connect: \(candidates.count, privacy: .public) Car-Thing-shaped paired device(s) / \(self.devices.count, privacy: .public) total")
            for d in candidates {
                log.info("Auto-connecting to \(d.address, privacy: .public) (\(d.name, privacy: .public))")
                connect(address: d.address)
            }
        }
    }

    /// Register the macOS side as an SPP RFCOMM server. The Car Thing's nocturned
    /// daemon dials INTO this — it's the primary connection path (auto-connect
    /// outbound to Car Thing channel 2 is a fallback).
    private func startSPPServer() {
        server.onIncomingChannel = { [weak self] channel in
            guard let self else { return }
            // Attach our delegate so we get data/close callbacks.
            channel.setDelegate(self.bridge)
            self.handleChannelOpened(channel)
        }
        let ok = server.register(serviceName: "Nocturne Connector")
        if !ok {
            // On modern macOS this is the *expected* path — SDP publication is
            // locked down. The outbound RFCOMM connect after pairing is enough.
            log.info("SDP publish unavailable; running outbound-only.")
        } else {
            // Clear any previous registration-related error.
            if lastError?.contains("SPP") == true || lastError?.contains("Bluetooth is off") == true {
                lastError = nil
            }
        }
    }

    // MARK: - Status

    func refreshAdapterStatus() {
        let powered = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        status.powered = powered
    }

    /// Heuristic for whether a paired device's name suggests it's a Car Thing.
    /// nocturned and Spotify's official firmware both advertise names containing
    /// "Nocturne" or "Car Thing" — anything else is almost certainly an AirPods
    /// / keyboard / etc. and should not be RFCOMM-probed.
    static func looksLikeCarThing(name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("nocturne") || lower.contains("car thing") || lower.contains("carthing")
    }

    /// Surface previously-paired Car Things so the user can reconnect without re-scanning.
    /// Triggered at launch and on each scan kickoff.
    func loadPairedDevices() {
        guard let list = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            log.info("loadPairedDevices: pairedDevices() returned nil")
            return
        }
        log.info("loadPairedDevices: found \(list.count, privacy: .public) paired device(s)")
        for device in list {
            ingest(device: device)
        }
    }

    // MARK: - Discovery

    func startScan() {
        stopScan()
        loadPairedDevices()
        let inq = IOBluetoothDeviceInquiry(delegate: bridge)
        inq?.inquiryLength = 15
        inq?.updateNewDeviceNames = true
        let rc = inq?.start() ?? kIOReturnError
        if rc == kIOReturnSuccess {
            status.discovering = true
            inquiry = inq
            log.info("Bluetooth inquiry started")
        } else {
            lastError = "Failed to start Bluetooth inquiry (\(rc))"
            log.error("inquiry start failed: \(rc, privacy: .public)")
        }
    }

    func stopScan() {
        if let inq = inquiry {
            _ = inq.stop()
            inquiry = nil
        }
        status.discovering = false
    }

    // MARK: - Pairing

    func pair(address: String) {
        guard let device = IOBluetoothDevice(addressString: address) else {
            lastError = "Unknown device \(address)"
            return
        }
        let pair = IOBluetoothDevicePair(device: device)
        pair?.delegate = bridge
        let rc = pair?.start() ?? kIOReturnError
        if rc != kIOReturnSuccess {
            lastError = "Failed to begin pairing (\(rc))"
            log.error("pair start failed: \(rc, privacy: .public)")
            return
        }
        pairing = pair
    }

    func confirmPairing() {
        // macOS pairing dialogs handle confirmation in the OS UI for numeric
        // comparison flows. For passkey/PIN entry we surface via pendingPin and
        // the user types it on the Car Thing — there is nothing to "accept" here.
        pendingPin = nil
    }

    func rejectPairing() {
        pendingPin = nil
        pairing?.stop()
        pairing = nil
    }

    func unpair(address: String) {
        // IOBluetooth doesn't expose a programmatic unpair API; the system manages
        // bond state. Best we can do is drop our RFCOMM channel.
        disconnect(address: address)
        if let idx = devices.firstIndex(where: { $0.address == address }) {
            devices[idx].paired = false
            devices[idx].connected = false
        }
        log.info("Unpair requested for \(address, privacy: .public); user may need to remove the device in System Settings → Bluetooth")
    }

    func trust(address: String) {
        // macOS has no separate "trust" concept — pairing implies trust.
        log.info("trust(\(address, privacy: .public)) noop on macOS")
    }

    // MARK: - RFCOMM connection

    func connect(address: String, channel: BluetoothRFCOMMChannelID? = nil) {
        // Guard against parallel connect attempts to the same address — those
        // race on `outboundChannelContinuation` and leak. If one's already in
        // flight, drop the new call instead of stomping the slot.
        if inFlightConnects.contains(address) {
            log.info("connect(\(address, privacy: .public)) skipped — already in flight")
            return
        }
        guard let device = IOBluetoothDevice(addressString: address) else {
            lastError = "Unknown device \(address)"
            return
        }
        lastError = nil
        let chDesc = channel.map(String.init) ?? "auto"
        log.info("connect(\(address, privacy: .public), channel: \(chDesc, privacy: .public))")

        inFlightConnects.insert(address)
        Task.detached { [weak self] in
            guard let self else { return }
            await self.openRFCOMM(device: device, requestedChannel: channel)
            await MainActor.run { self.inFlightConnects.remove(address) }
        }
    }

    /// Addresses currently mid-connect — used to drop duplicate `connect()`
    /// invocations that would otherwise stomp the continuation slot.
    private var inFlightConnects = Set<String>()

    /// Continuation that the delegate signals when an outbound RFCOMM channel
    /// finishes opening (success or failure). Only one outbound attempt is in
    /// flight at a time so a single continuation slot is enough.
    private var outboundChannelContinuation: CheckedContinuation<IOReturn, Never>?
    private var outboundContinuationID: UUID?

    fileprivate func reportOutboundOpenComplete(status: IOReturn) {
        guard let waiter = outboundChannelContinuation else { return }
        outboundChannelContinuation = nil
        outboundContinuationID = nil
        waiter.resume(returning: status)
    }

    private func openRFCOMM(device: IOBluetoothDevice, requestedChannel: BluetoothRFCOMMChannelID?) async {
        let addr = device.addressString ?? "?"

        // Make sure baseband is up. On macOS the system normally brings the ACL
        // back up on demand when openRFCOMMChannelAsync runs, but doing it first
        // gives clearer error reporting if the link can't be established.
        if !device.isConnected() {
            let r = device.openConnection()
            log.info("openConnection(\(addr, privacy: .public)) -> \(r, privacy: .public)")
            if r != kIOReturnSuccess {
                await MainActor.run {
                    self.lastError = "Couldn't open baseband to \(addr) (status \(r)). Is the Car Thing on and in range?"
                }
                return
            }
        }

        // Discover the SPP channel via SDP. macOS's performSDPQuery is async — we
        // kick it off and poll briefly for the service record to populate.
        let sppUUID = IOBluetoothSDPUUID.uuid16(UInt16(kBluetoothSDPUUID16ServiceClassSerialPort.rawValue))
        let sdpStatus = device.performSDPQuery(nil)
        log.info("performSDPQuery(\(addr, privacy: .public)) -> \(sdpStatus, privacy: .public)")
        var record: IOBluetoothSDPServiceRecord? = device.getServiceRecord(for: sppUUID)
        for _ in 0..<15 {
            if record != nil { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
            record = device.getServiceRecord(for: sppUUID)
        }

        // Build ordered candidate channels: hint, then SDP-discovered, then common fallbacks.
        // Skip channel 1 — that's the channel our own SDP record advertised, and
        // the Car Thing dials INTO it (we don't want to also try to dial OUT to
        // ourselves; it causes a "no known channel" warning).
        var candidates: [BluetoothRFCOMMChannelID] = []
        if let requested = requestedChannel { candidates.append(requested) }
        if let record {
            var ch: BluetoothRFCOMMChannelID = 0
            if record.getRFCOMMChannelID(&ch) == kIOReturnSuccess,
               !candidates.contains(ch),
               ch != server.registeredChannel {
                candidates.append(ch)
            }
        }
        for fallback: BluetoothRFCOMMChannelID in [2, 3]
            where !candidates.contains(fallback) && fallback != server.registeredChannel {
            candidates.append(fallback)
        }
        log.info("RFCOMM candidate channels for \(addr, privacy: .public): \(candidates, privacy: .public)")

        // Try each candidate sequentially. openRFCOMMChannelAsync queues the open;
        // the real success/failure shows up via rfcommChannelOpenComplete on the
        // delegate. We await that callback before trying the next channel.
        for ch in candidates {
            // Bail out early if a parallel path already established a channel.
            let key = channelKey(address: addr, id: ch)
            if activeChannels[key] != nil {
                log.info("Channel \(ch, privacy: .public) skipped — already connected to \(addr, privacy: .public)")
                return
            }
            var channel: IOBluetoothRFCOMMChannel?
            let queueResult = device.openRFCOMMChannelAsync(&channel, withChannelID: ch, delegate: bridge)
            log.info("openRFCOMMChannelAsync(\(addr, privacy: .public), ch \(ch, privacy: .public)) queued -> \(queueResult, privacy: .public)")
            if queueResult != kIOReturnSuccess {
                continue
            }

            // Wait for the delegate callback; cap at 6 seconds per attempt.
            // The in-flight guard above ensures we're the only outbound for
            // this address, so a stomped continuation slot would mean a
            // genuine bug — resume the prior waiter as aborted instead of
            // leaking it.
            let openStatus: IOReturn = await withCheckedContinuation { cont in
                if let stale = self.outboundChannelContinuation {
                    self.log.warning("Pre-existing continuation found — aborting it")
                    stale.resume(returning: kIOReturnAborted)
                }
                self.outboundChannelContinuation = cont
                let attemptID = UUID()
                self.outboundContinuationID = attemptID
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 6 * 1_000_000_000)
                    // Only fire the timeout if our continuation is still active.
                    if self.outboundContinuationID == attemptID,
                       let waiter = self.outboundChannelContinuation {
                        waiter.resume(returning: kIOReturnTimeout)
                        self.outboundChannelContinuation = nil
                        self.outboundContinuationID = nil
                    }
                }
            }
            log.info("RFCOMM open(\(addr, privacy: .public), ch \(ch, privacy: .public)) result: \(openStatus, privacy: .public)")
            if openStatus == kIOReturnSuccess {
                // handleChannelOpened on the delegate path already cached the channel.
                return
            }
        }

        await MainActor.run {
            self.lastError = "RFCOMM open failed on \(addr) — tried channels \(candidates). Check that the Car Thing is running Nocturne firmware and not connected elsewhere."
        }
    }

    func disconnect(address: String) {
        // Close every channel keyed by this address.
        let keysToClose = activeChannels.keys.filter { $0.hasPrefix("\(address)#") }
        for key in keysToClose {
            activeChannels[key]?.close()
            activeChannels.removeValue(forKey: key)
        }
        connections.removeAll { $0.address == address }
        if let idx = devices.firstIndex(where: { $0.address == address }) {
            devices[idx].connected = false
        }
    }

    // MARK: - Delegate-driven updates (called by BluetoothDelegateBridge)

    fileprivate func ingest(device: IOBluetoothDevice) {
        let address = device.addressString ?? ""
        let info = BTDeviceInfo(
            address: address,
            name: device.name ?? device.nameOrAddress ?? address,
            paired: device.isPaired(),
            connected: device.isConnected(),
            trusted: device.isPaired(),
            rssi: device.rawRSSI() != 0 ? Int(device.rawRSSI()) : nil
        )
        if let idx = devices.firstIndex(where: { $0.address == address }) {
            devices[idx] = info
        } else {
            devices.append(info)
        }
    }

    fileprivate func handleInquiryComplete() {
        status.discovering = false
        inquiry = nil
    }

    fileprivate func handlePIN(pin: String, address: String, name: String) {
        pendingPin = BTPairingPin(address: address, name: name, pin: pin)
    }

    fileprivate func handlePairCompleted(address: String, success: Bool) {
        pendingPin = nil
        if success {
            if let idx = devices.firstIndex(where: { $0.address == address }) {
                devices[idx].paired = true
            }
            // Auto-connect RFCOMM shortly after pairing. Don't hardcode a channel —
            // openRFCOMM tries SDP-discovered first, then falls back to 2/1/3.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
                connect(address: address)
            }
        } else {
            log.warning("Pair failed for \(address, privacy: .public)")
        }
    }

    fileprivate func handleChannelOpened(_ channel: IOBluetoothRFCOMMChannel) {
        guard let device = channel.getDevice(), let address = device.addressString else { return }
        let chID = channel.getID()
        let key = channelKey(address: address, id: chID)

        // Deduplicate: the same channel can arrive via both the channel-open
        // notification AND the RFCOMM open-complete delegate. We only want to
        // surface it once.
        if activeChannels[key] != nil {
            return
        }

        log.info("RFCOMM channel opened: \(address, privacy: .public) ch=\(chID, privacy: .public)")
        channel.setDelegate(bridge)
        activeChannels[key] = channel

        // Channel 1 (our SDP-advertised inbound) gets a non-base64 wire format
        // from the Car Thing — we can't parse it as Nocturne RPC. Whenever an
        // inbound channel 1 lands, immediately open the outbound channel 2 in
        // parallel, which IS base64-newline framed Nocturne RPC. RPC traffic
        // will then flow over channel 2 and the inbound channel 1 stays open
        // but unused (closing it would tear down the bond).
        if chID == server.registeredChannel,
           activeChannels[channelKey(address: address, id: 2)] == nil {
            log.info("Inbound ch=\(chID, privacy: .public) detected; opening outbound ch 2 for RPC")
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000)
                connect(address: address, channel: 2)
            }
        }

        let devicePath = "rfcomm-\(chID == 1 ? "server" : "client"):\(address)"
        let conn = BTConnection(
            devicePath: devicePath,
            address: address,
            name: device.name
        )
        if !connections.contains(where: { $0.devicePath == conn.devicePath }) {
            connections.append(conn)
        }
        if let idx = devices.firstIndex(where: { $0.address == address }) {
            devices[idx].connected = true
        }
        lastError = nil

        // Hand the channel to the RPC manager — but ONLY for outbound channels
        // (ch != serverChannel). The inbound channel 1 from the Car Thing uses
        // a different wire format we can't parse; if we attach it we just spam
        // the log with "Invalid base64 line" errors.
        if chID != server.registeredChannel {
            rpcManager?.attach(channel: channel, address: address)
        }
    }

    /// Forward inbound RFCOMM bytes from the delegate to the RPC manager. Only
    /// outbound-channel bytes get forwarded (see `handleChannelOpened`).
    fileprivate func handleChannelData(_ channel: IOBluetoothRFCOMMChannel, data: Data) {
        guard let device = channel.getDevice(), let address = device.addressString else { return }
        if channel.getID() == server.registeredChannel {
            return  // Drop inbound-ch1 bytes — wrong wire format.
        }
        rpcManager?.ingest(data, channel: channel, address: address)
    }

    fileprivate func handleChannelClosed(_ channel: IOBluetoothRFCOMMChannel) {
        guard let address = channel.getDevice()?.addressString else { return }
        let chID = channel.getID()
        activeChannels.removeValue(forKey: channelKey(address: address, id: chID))
        rpcManager?.detach(channel: channel, address: address)
        log.info("RFCOMM channel closed: \(address, privacy: .public) ch=\(chID, privacy: .public)")

        // Only mark the device as disconnected when ALL channels to it are gone.
        let stillConnected = activeChannels.keys.contains(where: { $0.hasPrefix("\(address)#") })
        if !stillConnected {
            connections.removeAll { $0.address == address }
            if let idx = devices.firstIndex(where: { $0.address == address }) {
                devices[idx].connected = false
            }
        } else {
            // At least one channel remains — just drop this specific devicePath entry.
            let devicePath = "rfcomm-\(chID == 1 ? "server" : "client"):\(address)"
            connections.removeAll { $0.devicePath == devicePath }
        }
    }
}

// MARK: - NSObject delegate bridge

/// IOBluetooth's APIs require an NSObject-derived delegate; this class fulfills the
/// various protocols and forwards events back to the @MainActor BluetoothService.
final class BluetoothDelegateBridge: NSObject, IOBluetoothDeviceInquiryDelegate, IOBluetoothDevicePairDelegate, IOBluetoothRFCOMMChannelDelegate {
    weak var service: BluetoothService?

    init(service: BluetoothService) {
        self.service = service
        super.init()
    }

    // Discovery

    func deviceInquiryDeviceFound(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!) {
        Task { @MainActor in self.service?.ingest(device: device) }
    }

    func deviceInquiryDeviceNameUpdated(_ sender: IOBluetoothDeviceInquiry!, device: IOBluetoothDevice!, devicesRemaining: UInt32) {
        Task { @MainActor in self.service?.ingest(device: device) }
    }

    func deviceInquiryComplete(_ sender: IOBluetoothDeviceInquiry!, error: IOReturn, aborted: Bool) {
        Task { @MainActor in self.service?.handleInquiryComplete() }
    }

    // Pairing

    func devicePairingStarted(_ sender: Any!) {}

    func devicePairingConnecting(_ sender: Any!) {}

    func devicePairingPINCodeRequest(_ sender: Any!) {
        // The Car Thing initiates with a fixed PIN; you may need to type it on the device.
        // We don't have a UI to enter a PIN here; surface as a notice and let user retry if needed.
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        let pair = sender as? IOBluetoothDevicePair
        let device = pair?.device()
        let pin = String(format: "%06u", numericValue)
        let address = device?.addressString ?? ""
        let name = device?.name ?? address
        Task { @MainActor in self.service?.handlePIN(pin: pin, address: address, name: name) }
        // Auto-accept the numeric confirmation; matches the original "confirm" route.
        pair?.replyUserConfirmation(true)
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        let pair = sender as? IOBluetoothDevicePair
        let device = pair?.device()
        let pin = String(format: "%06u", passkey)
        let address = device?.addressString ?? ""
        let name = device?.name ?? address
        Task { @MainActor in self.service?.handlePIN(pin: pin, address: address, name: name) }
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        let pair = sender as? IOBluetoothDevicePair
        let address = pair?.device()?.addressString ?? ""
        let success = (error == kIOReturnSuccess)
        Task { @MainActor in self.service?.handlePairCompleted(address: address, success: success) }
    }

    // RFCOMM

    func rfcommChannelOpenComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, status error: IOReturn) {
        // Signal the outbound waiter regardless of success/failure so it can
        // move to the next candidate channel on error.
        Task { @MainActor in self.service?.reportOutboundOpenComplete(status: error) }
        guard error == kIOReturnSuccess, let rfcommChannel else { return }
        Task { @MainActor in self.service?.handleChannelOpened(rfcommChannel) }
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {
        guard let rfcommChannel else { return }
        Task { @MainActor in self.service?.handleChannelClosed(rfcommChannel) }
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!, data dataPointer: UnsafeMutableRawPointer!, length dataLength: Int) {
        guard let rfcommChannel, let dataPointer, dataLength > 0 else { return }
        // Copy out of the IOBluetooth-owned buffer immediately; the pointer is
        // only valid for the duration of this callback.
        let data = Data(bytes: dataPointer, count: dataLength)
        Task { @MainActor in self.service?.handleChannelData(rfcommChannel, data: data) }
    }

    func rfcommChannelWriteComplete(_ rfcommChannel: IOBluetoothRFCOMMChannel!, refcon: UnsafeMutableRawPointer!, status error: IOReturn) {}

    func rfcommChannelControlSignalsChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}

    func rfcommChannelFlowControlChanged(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}

    func rfcommChannelQueueSpaceAvailable(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
}

#else

// Non-macOS stub so referenced @StateObjects still compile if Xcode is mistakenly
// pointed at an iOS destination. The app only runs on macOS 14+.
@MainActor
final class BluetoothService: ObservableObject {
    @Published private(set) var status = BTAdapterStatus(powered: false, discovering: false)
    @Published private(set) var devices: [BTDeviceInfo] = []
    @Published private(set) var connections: [BTConnection] = []
    @Published private(set) var pendingPin: BTPairingPin? = nil
    @Published var lastError: String? = "Bluetooth is only available on macOS."

    func refreshAdapterStatus() {}
    func startScan() {}
    func stopScan() {}
    func pair(address: String) {}
    func confirmPairing() {}
    func rejectPairing() {}
    func unpair(address: String) {}
    func trust(address: String) {}
    func connect(address: String, channel: UInt8? = nil) {}
    func disconnect(address: String) {}
}

#endif
