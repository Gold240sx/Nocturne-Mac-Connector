import SwiftUI

/// Connection-mode banner.
///
/// On older macOS (≤ 14.3) we can publish an SPP SDP record and the Car Thing
/// dials *into* the Mac on the assigned RFCOMM channel. On macOS 14.4+ / 15+ /
/// Tahoe, Apple gated `IOBluetoothSDPServiceRecord.publishedServiceRecord(with:)`
/// — for third-party apps it always returns nil. In that case we run in
/// outbound-only mode (Mac dials *into* the Car Thing on channel 2 after
/// pairing). Either path is fine; we show which one we're in.
struct ServerStatusCard: View {
    @EnvironmentObject var bluetooth: BluetoothService

    var body: some View {
        let listening = bluetooth.serverChannel > 0
        Card {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: listening
                      ? "antenna.radiowaves.left.and.right.circle.fill"
                      : "arrow.up.right.circle.fill")
                    .font(.system(size: 18))
                    .frame(width: 36, height: 36)
                    .background(Theme.accent.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 9))
                    .foregroundStyle(Theme.accent)

                VStack(alignment: .leading, spacing: 4) {
                    Text(listening
                         ? "Listening for Car Thing on RFCOMM channel \(bluetooth.serverChannel)"
                         : "Outbound-only mode")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.fg)

                    Text(listening
                         ? "Once paired, the Car Thing's nocturned daemon dials in."
                         : "Pair the Car Thing; the Mac will dial out to it on RFCOMM channel 2 within a few seconds — same path the Pi connector uses after pairing.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
        }
    }
}
