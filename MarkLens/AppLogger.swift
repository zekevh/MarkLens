import Foundation
import OSLog

enum AppLogger {
    nonisolated(unsafe) private static let subsystem = Bundle.main.bundleIdentifier ?? "io.zvh.marklens"
    nonisolated(unsafe) private static let queue = DispatchQueue(label: "MarkLens.AppLogger", qos: .utility)

    nonisolated static func debug(_ message: String, category: String = "App") {
        write(level: "DEBUG", message: message, category: category)
    }

    nonisolated static func info(_ message: String, category: String = "App") {
        write(level: "INFO", message: message, category: category)
    }

    nonisolated static func error(_ message: String, category: String = "App") {
        write(level: "ERROR", message: message, category: category)
    }

    nonisolated private static func write(level: String, message: String, category: String) {
        let logger = Logger(subsystem: subsystem, category: category)
        logger.log("\(level, privacy: .public) \(message, privacy: .public)")

        let line = "[\(timestamp())] [\(level)] [\(category)] \(message)\n"
        queue.async {
            appendToFile(line)
        }
    }

    nonisolated private static func appendToFile(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        let url = logFileURL()
        let fm = FileManager.default

        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Avoid recursive logging on file write failures.
        }
    }

    nonisolated private static func logFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return support
            .appendingPathComponent("MarkLens/Logs", isDirectory: true)
            .appendingPathComponent("app.log")
    }

    nonisolated private static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
