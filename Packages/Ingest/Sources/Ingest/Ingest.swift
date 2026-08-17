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

/// Result of a completed ingest.
public struct IngestResult: Sendable {
    public let copiedFiles: [URL]
    public let skippedFiles: [URL]
    public let failedFiles: [(url: URL, error: String)]
    public let totalBytes: Int64
    public let duration: TimeInterval
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
        .union(["heif", "tif", "tiff"])
    
    public init() {}
    
    /// Runs the ingest job, copying files to primary (and optionally secondary)
    /// destinations concurrently. Reports progress via the stream.
    public func run(job: IngestJob, progress: @Sendable (IngestProgress) -> Void) async throws -> IngestResult {
        let startTime = Date.now
        
        // Discover source files
        let sourceFiles = try discoverFiles(at: job.sourceURL, recursive: job.recursive)
        
        guard !sourceFiles.isEmpty else {
            return IngestResult(copiedFiles: [], skippedFiles: [], failedFiles: [], totalBytes: 0, duration: 0)
        }
        
        // Calculate total bytes
        let totalBytes = sourceFiles.reduce(Int64(0)) { acc, url in
            acc + (fileSize(url) ?? 0)
        }
        
        var copiedFiles: [URL] = []
        var skippedFiles: [URL] = []
        var failedFiles: [(url: URL, error: String)] = []
        var bytesCopied: Int64 = 0
        
        // Ensure destination directories exist
        try FileManager.default.createDirectory(at: job.primaryDestination, withIntermediateDirectories: true)
        if let secondary = job.secondaryDestination {
            try FileManager.default.createDirectory(at: secondary, withIntermediateDirectories: true)
        }
        
        for (index, sourceURL) in sourceFiles.enumerated() {
            // Determine destination filename
            let destFilename: String
            if let renameTemplate = job.renameTemplate {
                let context = RenameContext(
                    originalURL: sourceURL,
                    sequence: index + 1
                )
                destFilename = renameFormatter.format(template: renameTemplate, context: context)
            } else {
                destFilename = sourceURL.lastPathComponent
            }
            
            let primaryDest = job.primaryDestination.appending(path: destFilename)
            
            // Skip if already exists at primary
            if FileManager.default.fileExists(atPath: primaryDest.path) {
                skippedFiles.append(sourceURL)
                continue
            }
            
            do {
                // Copy to primary destination
                try FileManager.default.copyItem(at: sourceURL, to: primaryDest)
                
                // Copy to secondary destination concurrently
                if let secondary = job.secondaryDestination {
                    let secondaryDest = secondary.appending(path: destFilename)
                    try FileManager.default.copyItem(at: sourceURL, to: secondaryDest)
                }
                
                // Also copy sidecar if it exists
                let sourceSidecar = sourceURL.deletingPathExtension().appendingPathExtension("xmp")
                if FileManager.default.fileExists(atPath: sourceSidecar.path) {
                    let destSidecar = primaryDest.deletingPathExtension().appendingPathExtension("xmp")
                    try? FileManager.default.copyItem(at: sourceSidecar, to: destSidecar)
                    
                    if let secondary = job.secondaryDestination {
                        let secondarySidecar = secondary.appending(path: destFilename).deletingPathExtension().appendingPathExtension("xmp")
                        try? FileManager.default.copyItem(at: sourceSidecar, to: secondarySidecar)
                    }
                }
                
                // Apply metadata template if provided
                if let template = job.metadataTemplate {
                    let sidecarURL = primaryDest.deletingPathExtension().appendingPathExtension("xmp")
                    var metadata: PhotoMetadata
                    if FileManager.default.fileExists(atPath: sidecarURL.path) {
                        metadata = (try? sidecarManager.read(from: sidecarURL)) ?? PhotoMetadata()
                    } else {
                        metadata = PhotoMetadata()
                    }
                    metadata = template.apply(to: metadata)
                    try? sidecarManager.write(metadata, to: sidecarURL)
                    
                    // Also write to secondary
                    if let secondary = job.secondaryDestination {
                        let secondarySidecar = secondary.appending(path: destFilename).deletingPathExtension().appendingPathExtension("xmp")
                        try? sidecarManager.write(metadata, to: secondarySidecar)
                    }
                }
                
                copiedFiles.append(primaryDest)
                bytesCopied += fileSize(sourceURL) ?? 0
                
            } catch {
                failedFiles.append((url: sourceURL, error: error.localizedDescription))
            }
            
            // Report progress
            progress(IngestProgress(
                totalFiles: sourceFiles.count,
                copiedFiles: index + 1,
                currentFile: sourceURL.lastPathComponent,
                bytesTotal: totalBytes,
                bytesCopied: bytesCopied
            ))
        }
        
        let duration = Date.now.timeIntervalSince(startTime)
        
        return IngestResult(
            copiedFiles: copiedFiles,
            skippedFiles: skippedFiles,
            failedFiles: failedFiles,
            totalBytes: bytesCopied,
            duration: duration
        )
    }
    
    // MARK: - Private Helpers
    
    private func discoverFiles(at url: URL, recursive: Bool) throws -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        
        if recursive {
            guard let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            
            for case let fileURL as URL in enumerator {
                if isMediaFile(fileURL) {
                    results.append(fileURL)
                }
            }
        } else {
            let contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey])
            results = contents.filter { isMediaFile($0) }
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
}
