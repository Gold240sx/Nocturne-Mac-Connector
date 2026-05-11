import Foundation
import os

/// Mirrors src/server/utils/logger.ts. Use Logger.make(for: "…") instead of bare print().
enum Log {
    static func make(for subsystem: String) -> os.Logger {
        os.Logger(subsystem: "com.usenocturne.connector.mac", category: subsystem)
    }
}
