import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var bluetooth: BluetoothService
    @EnvironmentObject var spotify: SpotifyService
    @EnvironmentObject var nowPlaying: NowPlayingService
    @State private var selectedDevice: ConnectedDevice? = nil

    private var connectedDevices: [ConnectedDevice] {
        bluetooth.connections.map {
            ConnectedDevice(id: $0.devicePath, address: $0.address, info: nil)
        }
    }

    /// Paired Car Things that haven't (yet) opened an RFCOMM channel.
    /// Surfacing these makes the gap between "BT paired" and "Nocturne connected"
    /// visible to the user — instead of a flat "No Car Thing connected" message.
    private var pendingDevices: [BTDeviceInfo] {
        let activeAddresses = Set(bluetooth.connections.map(\.address))
        return bluetooth.devices.filter { $0.paired && !activeAddresses.contains($0.address) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dashboard")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    Text("Monitor and manage your connected Car Thing devices.")
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button(action: {
                    bluetooth.refreshAdapterStatus()
                    Task { await nowPlaying.refreshOnce() }
                }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
            }

            // Always render the Now Playing card — Spotify Web OAuth isn't
            // required when we bridge through the local Spotify.app, and the
            // card surfaces the Automation-permission status either way.
            NowPlayingCard()

            // Banner that prompts the user to link a Spotify Web account so
            // play/pause + volume work over the Web API (the Car Thing won't
            // route play/pause through our RPC otherwise).
            SpotifyLinkBanner()

            // Service-listening banner — confirms the SPP SDP record is up so the
            // Car Thing can dial in.
            ServerStatusCard()

            if connectedDevices.isEmpty && pendingDevices.isEmpty {
                Card {
                    VStack(spacing: 10) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 28))
                            .frame(width: 56, height: 56)
                            .background(Theme.hover, in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(Theme.muted)
                        Text("No Car Thing connected")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(Theme.fg)
                        Text("Connect your Car Thing via Bluetooth to start managing playback and settings.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 380)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                }
            } else if connectedDevices.isEmpty {
                // Paired but no RFCOMM channel yet — most common state right after
                // pairing for the first time.
                VStack(spacing: 10) {
                    ForEach(pendingDevices) { device in
                        pendingDeviceCard(for: device)
                    }
                    if let err = bluetooth.lastError {
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.destructive)
                            .padding(.horizontal, 4)
                    }
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(connectedDevices) { device in
                        Card {
                            HStack(spacing: 14) {
                                Image(systemName: "tv")
                                    .frame(width: 40, height: 40)
                                    .background(Theme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                                    .foregroundStyle(Theme.success)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.info?.device ?? "Nocturne Car Thing")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(Theme.fg)
                                    Text(device.info?.version.map { "Firmware \($0)" } ?? "Connected via Bluetooth")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                PillBadge(text: "Connected")
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Theme.muted)
                            }
                        }
                        .onTapGesture { selectedDevice = device }
                    }
                }
            }
        }
        .sheet(item: $selectedDevice) { device in
            DeviceInfoSheet(device: device) { selectedDevice = nil }
        }
        .padding(.bottom, 24)
    }

    /// Renders the per-device row in the "paired but not connected" state.
    /// Branches on `BluetoothService.peerConnectability` so a Car Thing whose
    /// `nocturned` is refusing every RFCOMM channel gets an actionable message
    /// (open Nocturne on the device or run the phone app) instead of an
    /// indefinite "waiting…" spinner.
    @ViewBuilder
    private func pendingDeviceCard(for device: BTDeviceInfo) -> some View {
        let state = bluetooth.peerConnectability[device.address] ?? .unknown
        Card {
            HStack(spacing: 14) {
                Image(systemName: state.icon)
                    .frame(width: 40, height: 40)
                    .background(state.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(state.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.fg)
                    Text(state.headline)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(state.actionLabel) {
                    bluetooth.connect(address: device.address, userInitiated: true)
                }
                .buttonStyle(PrimaryButtonStyle(prominent: state.actionProminent))
            }
        }
    }
}

private extension BluetoothService.PeerConnectability {
    var icon: String {
        switch self {
        case .rejecting:  return "exclamationmark.triangle.fill"
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .connected:  return "checkmark.circle.fill"
        case .unknown:    return "hourglass"
        }
    }
    var tint: SwiftUI.Color {
        switch self {
        case .rejecting:  return Theme.destructive
        case .connecting: return Theme.accent
        case .connected:  return Theme.success
        case .unknown:    return Theme.accent
        }
    }
    var headline: String {
        switch self {
        case .rejecting:
            return "Car Thing is refusing the connection. Open Nocturne on its touchscreen and pick this Mac, or start the Nocturne Companion phone app — nocturned only opens its RFCOMM gate when one of those wakes it."
        case .connecting:
            return "Opening RFCOMM channel…"
        case .connected:
            return "Connected"
        case .unknown:
            return "Paired — waiting for the Car Thing to open an RFCOMM channel"
        }
    }
    var actionLabel: String {
        if case .rejecting = self { return "Try again" }
        return "Retry"
    }
    var actionProminent: Bool {
        if case .rejecting = self { return true }
        return false
    }
}

private struct DeviceInfoSheet: View {
    let device: ConnectedDevice
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(device.info?.device ?? "Nocturne Car Thing")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
            }
            if let info = device.info {
                VStack(spacing: 8) {
                    DeviceInfoRow(label: "Firmware", value: info.version)
                    DeviceInfoRow(label: "Full Version", value: info.fullVersion)
                    DeviceInfoRow(label: "Build Date", value: info.buildDate)
                    DeviceInfoRow(label: "Git Hash", value: info.gitHash, monospaced: true)
                    DeviceInfoRow(label: "Serial Number", value: info.serialNumber, monospaced: true)
                }
            } else {
                Text("No device info available")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(Theme.bg)
    }
}

private struct DeviceInfoRow: View {
    let label: String
    let value: String?
    var monospaced: Bool = false

    var body: some View {
        if let value, !value.isEmpty {
            HStack {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Text(value)
                    .font(.system(size: monospaced ? 11 : 12, design: monospaced ? .monospaced : .default))
                    .foregroundStyle(Theme.fg)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
