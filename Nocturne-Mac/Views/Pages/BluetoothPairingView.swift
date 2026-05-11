import SwiftUI

struct BluetoothPairingView: View {
    @EnvironmentObject var bluetooth: BluetoothService
    @State private var showPinSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Bluetooth")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.fg)
                    Text("Pair and manage your Car Thing connection.")
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Button(action: scan) {
                    Label(bluetooth.status.discovering ? "Scanning..." : "Scan for Devices",
                          systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle(prominent: false))
                .disabled(!bluetooth.status.powered || bluetooth.status.discovering)
            }

            if !bluetooth.connections.isEmpty {
                section("Active Connections") {
                    VStack(spacing: 10) {
                        ForEach(bluetooth.connections) { conn in
                            Card {
                                HStack(spacing: 12) {
                                    Image(systemName: "wave.3.right")
                                        .frame(width: 32, height: 32)
                                        .background(Theme.success.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                                        .foregroundStyle(Theme.success)
                                    Text(conn.name ?? "Car Thing")
                                        .foregroundStyle(Theme.fg)
                                        .font(.system(size: 14, weight: .medium))
                                    Spacer()
                                    PillBadge(text: "Connected")
                                }
                            }
                        }
                    }
                }
            }

            section("Available Devices") {
                if bluetooth.devices.isEmpty {
                    Card {
                        VStack(spacing: 8) {
                            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                                .font(.system(size: 32))
                                .foregroundStyle(Theme.muted)
                            Text("No devices yet")
                                .foregroundStyle(Theme.secondary)
                            Text("Make sure your Car Thing is in pairing mode and tap Scan above.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(bluetooth.devices) { device in
                            BluetoothRow(
                                device: device,
                                onPair: { bluetooth.pair(address: device.address); bluetooth.trust(address: device.address) },
                                onUnpair: { bluetooth.unpair(address: device.address) },
                                onConnect: { bluetooth.connect(address: device.address) }
                            )
                        }
                    }
                }
            }

            if let err = bluetooth.lastError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.destructive)
            }
        }
        .padding(.bottom, 24)
        .onChange(of: bluetooth.pendingPin) { _, new in
            showPinSheet = (new != nil)
        }
        .sheet(isPresented: $showPinSheet) {
            PairingPinSheet(
                pin: bluetooth.pendingPin,
                onConfirm: { bluetooth.confirmPairing(); showPinSheet = false },
                onReject: { bluetooth.rejectPairing(); showPinSheet = false }
            )
        }
    }

    private func scan() { bluetooth.startScan() }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .tracking(2)
                .foregroundStyle(Theme.muted)
            content()
        }
    }
}

private struct BluetoothRow: View {
    let device: BTDeviceInfo
    let onPair: () -> Void
    let onUnpair: () -> Void
    let onConnect: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .frame(width: 32, height: 32)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1))
                    .foregroundStyle(Theme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.fg)
                    Text(device.address)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                if device.connected {
                    PillBadge(text: "Connected")
                } else if device.paired {
                    Button("Connect", action: onConnect)
                        .buttonStyle(PrimaryButtonStyle(prominent: false))
                    Button("Unpair", action: onUnpair)
                        .buttonStyle(PrimaryButtonStyle(prominent: false))
                } else {
                    Button("Pair", action: onPair)
                        .buttonStyle(PrimaryButtonStyle(prominent: true))
                }
            }
        }
    }
}

private struct PairingPinSheet: View {
    let pin: BTPairingPin?
    let onConfirm: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Bluetooth Pairing Request")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.fg)
            Text("Confirm that this PIN matches the one shown on \(pin?.name ?? pin?.address ?? "your device")")
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary)
            Text(pin?.pin ?? "")
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .tracking(6)
                .foregroundStyle(Theme.fg)
                .padding(.vertical, 12)
            HStack {
                Button("Reject", action: onReject)
                    .buttonStyle(PrimaryButtonStyle(prominent: false))
                Spacer()
                Button("Confirm", action: onConfirm)
                    .buttonStyle(PrimaryButtonStyle(prominent: true))
            }
        }
        .padding(28)
        .frame(width: 360)
        .background(Theme.bg)
    }
}
