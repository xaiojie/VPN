import Foundation
import OSLog

public enum LogCategory: String, Codable {
    case ui
    case core
    case system
    case subscription
}

public final class AppLogger {
    public static let shared = AppLogger()
    private let store = LogStore()

    public func logger(category: LogCategory) -> Logger {
        Logger(subsystem: "com.tahoeproxy", category: category.rawValue)
    }

    public func record(_ message: String, level: LogLevel = .info, category: LogCategory) {
        store.append(.init(date: Date(), level: level, category: category, message: message))
    }

    public func entries(limit: Int = 2000) -> [LogEntry] {
        store.entries(limit: limit)
    }
}

public enum LogLevel: String, Codable, CaseIterable {
    case info
    case warning
    case error
}

public struct LogEntry: Codable, Identifiable {
    public let id = UUID()
    public let date: Date
    public let level: LogLevel
    public let category: LogCategory
    public let message: String
}

public final class LogStore {
    private let queue = DispatchQueue(label: "log.store")
    private var buffer: [LogEntry] = []
    private let capacity = 2000

    func append(_ entry: LogEntry) {
        queue.async {
            self.buffer.append(entry)
            if self.buffer.count > self.capacity {
                self.buffer.removeFirst(self.buffer.count - self.capacity)
            }
        }
    }

    func entries(limit: Int) -> [LogEntry] {
        queue.sync {
            Array(buffer.suffix(limit))
        }
    }
}
