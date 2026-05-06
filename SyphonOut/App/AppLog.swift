import Foundation
import os.log

/// Centralized application logger.
///
/// Records every event into:
/// 1. The system unified log (`os.log` via `Logger`) — for `log stream`, Console.app, etc.
/// 2. An in-memory ring buffer — for the in-app Log Viewer window.
///
/// Posts `.appLogAppended` whenever a new entry is added so live observers can update.
///
/// Thread-safe: all mutations go through a dedicated serial queue.
final class AppLog {

    static let shared = AppLog()

    // MARK: - Types

    enum Level: String {
        case debug = "DBG"
        case info  = "INF"
        case warn  = "WRN"
        case error = "ERR"
    }

    struct Entry {
        let timestamp: Date
        let level:     Level
        let category:  String
        let message:   String

        /// "[23:15:04.123] [INF] [VDManager] message"
        var formatted: String {
            let ts = AppLog.timestampFormatter.string(from: timestamp)
            return "[\(ts)] [\(level.rawValue)] [\(category)] \(message)"
        }
    }

    // MARK: - Storage

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private let maxEntries = 5000
    private var buffer: [Entry] = []
    private let queue = DispatchQueue(label: "com.syphonout.AppLog", qos: .utility)
    private var loggerCache: [String: Logger] = [:]

    private init() {
        buffer.reserveCapacity(maxEntries)
    }

    // MARK: - Public API

    func debug(_ message: String, category: String = "App") { log(.debug, message, category: category) }
    func info(_ message: String,  category: String = "App") { log(.info,  message, category: category) }
    func warn(_ message: String,  category: String = "App") { log(.warn,  message, category: category) }
    func error(_ message: String, category: String = "App") { log(.error, message, category: category) }

    /// Snapshot of the current ring buffer.
    var entries: [Entry] {
        queue.sync { buffer }
    }

    func clear() {
        queue.async { [weak self] in
            self?.buffer.removeAll(keepingCapacity: true)
        }
    }

    /// Returns a single multi-line string of all entries (optionally filtered by category substring).
    func formattedDump(filter: String? = nil) -> String {
        let snap = entries
        let lines: [String]
        if let filter, !filter.isEmpty {
            lines = snap.filter { $0.category.localizedCaseInsensitiveContains(filter) }
                        .map { $0.formatted }
        } else {
            lines = snap.map { $0.formatted }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Internal

    private func log(_ level: Level, _ message: String, category: String) {
        let entry = Entry(timestamp: Date(),
                          level: level,
                          category: category,
                          message: message)

        // Mirror to os.log (synchronously is fine — Logger is itself async).
        let osLogger = osLogger(for: category)
        switch level {
        case .debug: osLogger.debug("\(message, privacy: .public)")
        case .info:  osLogger.info("\(message, privacy: .public)")
        case .warn:  osLogger.warning("\(message, privacy: .public)")
        case .error: osLogger.error("\(message, privacy: .public)")
        }

        // Append to ring buffer + notify (off the calling thread to avoid contention).
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(entry)
            if self.buffer.count > self.maxEntries {
                self.buffer.removeFirst(self.buffer.count - self.maxEntries)
            }
            // Notify on main so UI observers can update directly.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .appLogAppended,
                    object: nil,
                    userInfo: ["entry": entry]
                )
            }
        }
    }

    private func osLogger(for category: String) -> Logger {
        // We don't synchronise this cache — worst case we make duplicate Logger
        // instances which is harmless. The cache is only an allocation hint.
        if let l = loggerCache[category] { return l }
        let l = Logger(subsystem: "com.syphonout.SyphonOut", category: category)
        loggerCache[category] = l
        return l
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let appLogAppended = Notification.Name("AppLogAppended")
}
