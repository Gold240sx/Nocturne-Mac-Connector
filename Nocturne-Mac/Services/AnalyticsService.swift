import Foundation
import os
import Combine

/// Lightweight analytics toggle. The original analytics-service.ts also batches
/// events to Supabase; here we just track the local preference and expose hooks
/// for events if you want to wire them up.
@MainActor
final class AnalyticsService: ObservableObject {
    private let log = Log.make(for: "AnalyticsService")
    private let store = SessionStore.shared

    @Published var isEnabled: Bool

    init() {
        self.isEnabled = SessionStore.shared.analyticsEnabled
    }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        store.analyticsEnabled = enabled
        log.info("Analytics enabled = \(enabled, privacy: .public)")
    }
}
