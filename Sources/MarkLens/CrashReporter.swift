import MetricKit
import Foundation

// Receives MXDiagnosticPayload the launch *after* a crash and writes
// the JSON to ~/Library/Application Support/MarkLens/CrashReports/.
// Logs are plain JSON — inspect with any text editor or forward to a
// server in a future release.

final class CrashReporter: NSObject, MXMetricManagerSubscriber {
    nonisolated(unsafe) static let shared = CrashReporter()

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads where !(payload.crashDiagnostics ?? []).isEmpty {
            persistPayload(payload)
        }
    }

    private func persistPayload(_ payload: MXDiagnosticPayload) {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("MarkLens/CrashReports", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let ts = ISO8601DateFormatter().string(from: payload.timeStampBegin)
        let file = dir.appendingPathComponent("crash-\(ts).json")
        guard !fm.fileExists(atPath: file.path) else { return }
        try? payload.jsonRepresentation().write(to: file)
    }
}
