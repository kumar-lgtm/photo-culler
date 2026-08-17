import Foundation
import Catalog
import Sidecar
import Rename

/// Represents a single ingest job configuration.
public struct IngestJob: Sendable {
    public let sourceURL: URL
    public let primaryDestination: URL
    public let secondaryDestination: URL?
    public let metadataTemplate: MetadataTemplate?
    public let renameTemplate: String?
    public let recursive: Bool

    public init(
        sourceURL: URL,
        primaryDestination: URL,
        secondaryDestination: URL? = nil,
        metadataTemplate: MetadataTemplate? = nil,
        renameTemplate: String? = nil,
        recursive: Bool = true
    ) {
        self.sourceURL = sourceURL
        self.primaryDestination = primaryDestination
        self.secondaryDestination = secondaryDestination
        self.metadataTemplate = metadataTemplate
        self.renameTemplate = renameTemplate
        self.recursive = recursive
    }

    var destinations: [URL] {
        [primaryDestination] + (secondaryDestination.map { [$0] } ?? [])
    }
}

/// Progress report emitted during ingest.
public struct IngestProgress: Sendable {
    public let totalFiles: Int
    public let copiedFiles: Int
    public let currentFile: String
    public let bytesTotal: Int64
    public let bytesCopied: Int64

    public var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(copiedFiles) / Double(totalFiles)
    }

    public var isComplete: Bool { copiedFiles >= totalFiles }
}

/// Per-destination outcome, so a half-succeeded file is never reported as a clean failure.
public struct DestinationReport: Sendable {
    public let destination: URL
    public var copied: [URL] = []
    public var skipped: [URL] = []
    public var failed: [(url: URL, error: String)] = []

    public init(destination: URL) { self.destination = destination }
}

/// Result of a completed ingest.
public struct IngestResult: Sendable {
    public let copiedFiles: [URL]
    public let skippedFiles: [URL]
    public let failedFiles: [(url: URL, error: String)]
    public let totalBytes: Int64
    public let duration: TimeInterval
    /// One entry per destination, so backup completeness is visible rather than inferred.
    public let destinationReports: [DestinationReport]
    public let wasCancelled: Bool

    public init(copiedFiles: [URL], skippedFiles: [URL], failedFiles: [(url: URL, error: String)],
                totalBytes: Int64, duration: TimeInterval,
                destinationReports: [DestinationReport] = [], wasCancelled: Bool = false) {
        self.copiedFiles = copiedFiles
        self.skippedFiles = skippedFiles
        self.failedFiles = failedFiles
        self.totalBytes = totalBytes
        self.duration = duration
        self.destinationReports = destinationReports
        self.wasCancelled = wasCancelled
    }
}

public enum IngestError: Error, LocalizedError {
    /// The rename template maps two or more source files onto the same name.
    case duplicateDestinationNames(example: String, collidingCount: Int)
    case insufficientSpace(destination: URL, needed: Int64, available: Int64)
    case destinationUnwritable(URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .duplicateDestinationNames(let example, let count):
            return "This rename template gives \(count) files the same name (e.g. “\(example)”). "
                 + "Add a sequence token such as {Sequence(0001)} so every file gets a unique name."
        case .insufficientSpace(let destination, let needed, let available):
            let f = ByteCountFormatter()
            f.countStyle = .file
            return "Not enough space on \(destination.lastPathComponent): "
                 + "needs \(f.string(fromByteCount: needed)), \(f.string(fromByteCount: available)) free."
        case .destinationUnwritable(let url, let underlying):
            return "Can't write to \(url.lastPathComponent): \(underlying.localizedDescription)"
        }
    }
}

/// Handles simultaneous multi-destination file ingest from memory cards.
public actor IngestManager {

    private let sidecarManager = SidecarManager()
    private let renameFormatter = RenameFormatter()

    /// Supported media file extensions for ingest.
    private static let mediaExtensions = rawExtensions
        .union(jpegExtensions)
        .union(otherImageExtensions)
        .union(videoExtensions)

    public init() {}

    /// Runs the ingest job, copying files to primary and (optionally) secondary destinations.
    ///
    /// Each destination is evaluated **independently**: a file already present on the primary
    /// no longer causes the secondary to be skipped, which previously meant a failed backup
    /// could never be repaired by re-running the ingest. The two destination copies for a
    /// given file run concurrently — the "concurrent dual-destination" behaviour the docs
    /// have always described.
    public func run(job: IngestJob, progress: @Sendable (IngestProgress) -> Void) async throws -> IngestResult {
        let startTime = Date.now

        let sourceFiles = try discoverFiles(at: job.sourceURL, recursive: job.recursive)
        guard !sourceFiles.isEmpty else {
            return IngestResult(copiedFiles: [], skippedFiles: [], failedFiles: [],
                                totalBytes: 0, duration: 0)
        }

        // ── Plan every destination name up front ───────────────────────────────────
        // A template without a sequence token maps every file onto one name. That used to
        // copy the first file and silently report the other few thousand as "skipped
        // (already exist)" behind a green checkmark — on the one operation where the source
        // is about to be formatted.
        let plan = try planDestinationNames(for: sourceFiles, template: job.renameTemplate)

        let totalBytes = sourceFiles.reduce(Int64(0)) { $0 + (fileSize($1) ?? 0) }

        // ── Preflight: destinations exist, are writable, and have room ─────────────
        for destination in job.destinations {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                throw IngestError.destinationUnwritable(destination, underlying: error)
            }
            if let free = availableCapacity(at: destination), free < totalBytes {
                throw IngestError.insufficientSpace(destination: destination,
                                                    needed: totalBytes, available: free)
            }
        }

        var reports = job.destinations.map { DestinationReport(destination: $0) }
        var bytesCopied: Int64 = 0
        var wasCancelled = false

        for (index, sourceURL) in sourceFiles.enumerated() {
            if Task.isCancelled { wasCancelled = true; break }

            let destFilename = plan[index]

            // Copy this file to every destination concurrently.
            let outcomes = await withTaskGroup(of: (Int, FileOutcome).self) { group in
                for (slot, destinationRoot) in job.destinations.enumerated() {
                    let target = destinationRoot.appending(path: destFilename)
                    let template = job.metadataTemplate
                    group.addTask { [self] in
                        (slot, await copyOne(source: sourceURL,
                                             target: target,
                                             metadataTemplate: template))
                    }
                }
                var collected: [(Int, FileOutcome)] = []
                for await result in group { collected.append(result) }
                return collected
            }

            for (slot, outcome) in outcomes {
                switch outcome {
                case .copied(let url):
                    reports[slot].copied.append(url)
                case .skipped:
                    reports[slot].skipped.append(sourceURL)
                case .failed(let message):
                    reports[slot].failed.append((url: sourceURL, error: message))
                }
            }

            // Count source bytes once, when at least one destination took the file.
            if outcomes.contains(where: { if case .copied = $0.1 { return true } else { return false } }) {
                bytesCopied += fileSize(sourceURL) ?? 0
            }

            progress(IngestProgress(
                totalFiles: sourceFiles.count,
                copiedFiles: index + 1,
                currentFile: sourceURL.lastPathComponent,
                bytesTotal: totalBytes,
                bytesCopied: bytesCopied
            ))
        }

        let primary = reports[0]
        return IngestResult(
            copiedFiles: primary.copied,
            skippedFiles: primary.skipped,
            failedFiles: primary.failed,
            totalBytes: bytesCopied,
            duration: Date.now.timeIntervalSince(startTime),
            destinationReports: reports,
            wasCancelled: wasCancelled
        )
    }

    // MARK: - Per-file work

    private enum FileOutcome: Sendable {
        case copied(URL)
        case skipped
        case failed(String)
    }

    /// Copies one file to one destination, then its sidecar, then applies the template.
    /// Verifies the copy's size before declaring success — a truncated copy is worse than
    /// a failed one, because it looks like a backup.
    private func copyOne(source: URL, target: URL, metadataTemplate: MetadataTemplate?) async -> FileOutcome {
        let fm = FileManager.default

        if fm.fileExists(atPath: target.path) {
            return .skipped
        }

        do {
            try fm.copyItem(at: source, to: target)

            if let expected = fileSize(source), let actual = fileSize(target), expected != actual {
                try? fm.removeItem(at: target)
                return .failed("Copy verification failed (expected \(expected) bytes, got \(actual))")
            }

            // Carry an existing sidecar across with the new name.
            let sourceSidecar = source.deletingPathExtension().appendingPathExtension("xmp")
            let targetSidecar = target.deletingPathExtension().appendingPathExtension("xmp")
            if fm.fileExists(atPath: sourceSidecar.path), !fm.fileExists(atPath: targetSidecar.path) {
                try? fm.copyItem(at: sourceSidecar, to: targetSidecar)
            }

            if let template = metadataTemplate {
                var metadata = (try? sidecarManager.read(from: targetSidecar)) ?? PhotoMetadata()
                metadata = template.apply(to: metadata)
                try? sidecarManager.write(metadata, to: targetSidecar)
            }

            return .copied(target)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Planning

    /// Resolves the destination filename for every source file and refuses ambiguous plans.
    private func planDestinationNames(for sources: [URL], template: String?) throws -> [String] {
        guard let template, !template.isEmpty else {
            return sources.map { $0.lastPathComponent }
        }

        var names: [String] = []
        names.reserveCapacity(sources.count)

        for (index, source) in sources.enumerated() {
            let context = RenameContext.forImage(at: source, sequence: index + 1)
            names.append(renameFormatter.format(template: template, context: context))
        }

        var seen: [String: Int] = [:]
        for name in names {
            seen[name.lowercased(), default: 0] += 1
        }
        if let (worstName, count) = seen.max(by: { $0.value < $1.value }), count > 1 {
            throw IngestError.duplicateDestinationNames(example: worstName, collidingCount: count)
        }

        return names
    }

    // MARK: - Private Helpers

    private func discoverFiles(at url: URL, recursive: Bool) throws -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        let options: FileManager.DirectoryEnumerationOptions = recursive
            ? [.skipsHiddenFiles]
            : [.skipsHiddenFiles, .skipsSubdirectoryDescendants]

        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: options
        ) else {
            return []
        }

        while let next = enumerator.nextObject() {
            guard let fileURL = next as? URL, isMediaFile(fileURL) else { continue }
            // A *directory* named "shoot.jpg" would otherwise be treated as media.
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            results.append(fileURL)
        }

        return results.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func isMediaFile(_ url: URL) -> Bool {
        Self.mediaExtensions.contains(url.pathExtension.lowercased())
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private func availableCapacity(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage else { return nil }
        return Int64(capacity)
    }
}
