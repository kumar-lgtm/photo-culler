import Foundation
import os

/// Opt-in timing instrumentation.
///
/// Exists because a benchmark on synthetic files said "opening a folder takes 94 ms" while a
/// real user said it took a long time. Rather than guess which of several plausible causes
/// applies to *their* folder, this records what actually happened on *their* machine with
/// *their* files.
///
/// Enable either way, then open the slow folder:
///
///     defaults write com.braveenkumar.photoculler diagnostics -bool YES
///     # or, when launching from a terminal:
///     PHOTOCULLER_DIAG=1 /Applications/PhotoCuller.app/Contents/MacOS/PhotoCuller
///
/// Writes `~/Library/Logs/PhotoCuller/diag.log` (and mirrors to stderr). Turn off with
/// `defaults write com.braveenkumar.photoculler diagnostics -bool NO`.
public enum Diag {

    public static let isEnabled: Bool = {
        if ProcessInfo.processInfo.environment["PHOTOCULLER_DIAG"] == "1" { return true }
        return UserDefaults.standard.bool(forKey: "diagnostics")
    }()

    private static let logger = Logger(subsystem: "com.braveenkumar.photoculler", category: "diag")
    private static let queue = DispatchQueue(label: "com.braveenkumar.photoculler.diag")
    private static let start = DispatchTime.now()

    private static let fileHandle: FileHandle? = {
        guard isEnabled else { return nil }
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/PhotoCuller", isDirectory: true)
        guard let dir else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("diag.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        _ = try? handle.seekToEnd()
        return handle
    }()

    public static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let text = message()
        let stamp = String(format: "%8.3fs", Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9)
        let line = "[\(stamp)] \(text)\n"
        logger.log("\(text, privacy: .public)")
        queue.async {
            FileHandle.standardError.write(Data(line.utf8))
            fileHandle?.write(Data(line.utf8))
        }
    }

    /// Times a synchronous block and logs the result.
    @discardableResult
    public static func measure<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let t0 = DispatchTime.now()
        let result = try body()
        log(String(format: "%@ — %.1f ms", label, elapsedMS(since: t0)))
        return result
    }

    public static func elapsedMS(since t0: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1_000_000
    }

    // MARK: - Decode accounting

    /// Aggregated decode stats, so a 5,000-photo folder produces a summary rather than
    /// 5,000 log lines.
    public actor DecodeStats {
        public static let shared = DecodeStats()

        private struct Bucket {
            var count = 0
            var totalMS = 0.0
            var maxMS = 0.0
            var bytes: Int64 = 0
        }
        private var buckets: [String: Bucket] = [:]
        private var reportScheduled = false

        func record(tier: String, ms: Double, pixels: Int) {
            guard Diag.isEnabled else { return }
            var bucket = buckets[tier] ?? Bucket()
            bucket.count += 1
            bucket.totalMS += ms
            bucket.maxMS = max(bucket.maxMS, ms)
            bucket.bytes += Int64(pixels) * 4
            buckets[tier] = bucket
            scheduleReport()
        }

        private func scheduleReport() {
            guard !reportScheduled else { return }
            reportScheduled = true
            // Inherits this actor's isolation, so `flush()` needs no hop.
            Task {
                try? await Task.sleep(for: .seconds(2))
                self.flush()
            }
        }

        public func flush() {
            reportScheduled = false
            guard !buckets.isEmpty else { return }
            for (tier, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
                Diag.log(String(format: "decode[%@]: %d images, %.0f ms total, %.1f ms avg, %.1f ms worst, %.0f MB decoded",
                                tier, bucket.count, bucket.totalMS,
                                bucket.totalMS / Double(bucket.count), bucket.maxMS,
                                Double(bucket.bytes) / 1_048_576))
            }
            buckets.removeAll()
        }
    }
}
