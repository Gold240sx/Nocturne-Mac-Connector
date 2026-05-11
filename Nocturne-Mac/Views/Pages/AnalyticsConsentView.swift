import SwiftUI

struct AnalyticsConsentView: View {
    @EnvironmentObject var analytics: AnalyticsService

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Analytics")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Theme.fg)
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Help improve Nocturne by sharing anonymous usage data. You can change this anytime in Settings.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondary)
                    Toggle("Enable analytics", isOn: Binding(
                        get: { analytics.isEnabled },
                        set: { analytics.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .foregroundStyle(Theme.fg)
                }
            }
            .frame(maxWidth: 560)
        }
    }
}
