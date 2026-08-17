import Foundation
import ImageIO

public struct RenameContext: Sendable {
    public let originalURL: URL
    public let sequence: Int
    public let rating: String?
    public let color: String?
    public let camera: String?
    public let lens: String?
    public let iso: String?
    /// The other half of a RAW+JPEG pair, renamed in lockstep.
    public let pairedURL: URL?

    public init(originalURL: URL, sequence: Int, rating: String? = nil, color: String? = nil,
                camera: String? = nil, lens: String? = nil, iso: String? = nil,
                pairedURL: URL? = nil) {
        self.originalURL = originalURL
        self.sequence = sequence
        self.rating = rating
        self.color = color
        self.camera = camera
        self.lens = lens
        self.iso = iso
        self.pairedURL = pairedURL
    }

    /// Builds a context with the EXIF-backed tokens actually populated.
    ///
    /// `{camera}`, `{lens}`, `{iso}` and `{CameraModel}` are documented in the README and
    /// shown in the ingest UI, but every call site used to construct a context with only a
    /// URL and a sequence number — so those tokens silently expanded to empty strings and
    /// users got `_0001.CR2` where they expected `R5_0001.CR2`.
    public static func forImage(at url: URL, sequence: Int, rating: String? = nil,
                                color: String? = nil, pairedURL: URL? = nil) -> RenameContext {
        let exif = ImageMetadataReader.read(from: url)
        return RenameContext(
            originalURL: url,
            sequence: sequence,
            rating: rating,
            color: color,
            camera: exif.cameraModel,
            lens: exif.lensModel,
            iso: exif.iso,
            pairedURL: pairedURL
        )
    }
}

/// Minimal EXIF reader for the rename tokens. Reads properties only — never decodes pixels.
public enum ImageMetadataReader {

    public struct Values: Sendable {
        public var cameraModel: String?
        public var lensModel: String?
        public var iso: String?
    }

    public static func read(from url: URL) -> Values {
        var values = Values()

        // Only ask for properties; this does not rasterize the image.
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return values
        }

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespaces)
            let model = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
            // Canon writes "Canon" / "Canon EOS R5"; avoid "Canon Canon EOS R5".
            if let model, let make, !model.lowercased().hasPrefix(make.lowercased()) {
                values.cameraModel = "\(make) \(model)"
            } else {
                values.cameraModel = model ?? make
            }
        }

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            if let isoArray = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber], let first = isoArray.first {
                values.iso = first.stringValue
            }
            if let lens = exif[kCGImagePropertyExifLensModel] as? String {
                values.lensModel = lens.trimmingCharacters(in: .whitespaces)
            }
        }

        if values.lensModel == nil,
           let exifAux = props["{ExifAux}" as CFString] as? [CFString: Any],
           let lens = exifAux["LensModel" as CFString] as? String {
            values.lensModel = lens.trimmingCharacters(in: .whitespaces)
        }

        return values
    }
}

public final class RenameFormatter: @unchecked Sendable {

    /// `DateFormatter` construction is expensive and was previously repeated ~15 times per
    /// file. Cached by format string, guarded because batch rename can run off-main.
    private var formatterCache: [String: DateFormatter] = [:]
    private let cacheLock = NSLock()

    public init() {}

    /// Formats a single filename based on the template and context.
    public func format(template: String, context: RenameContext) -> String {
        var result = template

        let date = context.originalURL.creationDate ?? Date.now

        // Advanced Photo Mechanic-style tokens with arguments: {Token(arg)}
        result = expandAdvancedTokens(result, date: date, context: context)

        // Date formats
        result = replace(result, token: "{date}", with: formatDate(date, format: "yyyyMMdd"))
        result = replace(result, token: "{date:yyyymmdd}", with: formatDate(date, format: "yyyyMMdd"))
        result = replace(result, token: "{date:yyyy-mm-dd}", with: formatDate(date, format: "yyyy-MM-dd"))
        result = replace(result, token: "{date:mmddyy}", with: formatDate(date, format: "MMddyy"))

        // Time formats
        result = replace(result, token: "{time}", with: formatDate(date, format: "HHmmss"))
        result = replace(result, token: "{time:hhmmss}", with: formatDate(date, format: "HHmmss"))
        result = replace(result, token: "{time:hh-mm-ss}", with: formatDate(date, format: "HH-mm-ss"))

        // Sequence formats
        result = replace(result, token: "{seq}", with: formatSequence(context.sequence, format: "%04d"))
        result = replace(result, token: "{seq:0000}", with: formatSequence(context.sequence, format: "%04d"))
        result = replace(result, token: "{seq:000}", with: formatSequence(context.sequence, format: "%03d"))
        result = replace(result, token: "{seq:00}", with: formatSequence(context.sequence, format: "%02d"))
        result = replace(result, token: "{seq:0}", with: "\(context.sequence)")

        // Name formats
        let originalName = context.originalURL.deletingPathExtension().lastPathComponent
        result = replace(result, token: "{name}", with: originalName)
        result = replace(result, token: "{name:original}", with: originalName)
        result = replace(result, token: "{name:lower}", with: originalName.lowercased())
        result = replace(result, token: "{name:upper}", with: originalName.uppercased())

        // Ext formats
        let ext = context.originalURL.pathExtension
        result = replace(result, token: "{ext}", with: ext.lowercased())
        result = replace(result, token: "{ext:lower}", with: ext.lowercased())
        result = replace(result, token: "{ext:upper}", with: ext.uppercased())

        // Metadata
        result = replace(result, token: "{rating}", with: context.rating ?? "")
        result = replace(result, token: "{color}", with: context.color ?? "")

        // Exif
        result = replace(result, token: "{camera}", with: context.camera ?? "")
        result = replace(result, token: "{lens}", with: context.lens ?? "")
        result = replace(result, token: "{iso}", with: context.iso ?? "")

        // Standalone shortcuts
        result = replace(result, token: "{year}", with: formatDate(date, format: "yyyy"))
        result = replace(result, token: "{month}", with: formatDate(date, format: "MM"))
        result = replace(result, token: "{day}", with: formatDate(date, format: "dd"))
        result = replace(result, token: "{hour}", with: formatDate(date, format: "HH"))
        result = replace(result, token: "{minute}", with: formatDate(date, format: "mm"))
        result = replace(result, token: "{second}", with: formatDate(date, format: "ss"))

        let includesExtensionToken = template.contains("{ext}")
            || template.contains("{ext:lower}")
            || template.contains("{ext:upper}")

        // Sanitize before the extension goes on, so a value containing a path separator
        // (e.g. a lens named "EF24-70mm f/2.8") can't escape the directory.
        func fallbackStem() -> String {
            let cleaned = Self.sanitize(originalName)
            return cleaned.isEmpty ? "untitled" : cleaned
        }

        // The template placed the extension itself — don't append a second one.
        if includesExtensionToken {
            var name = Self.sanitize(result)
            if name.isEmpty { name = fallbackStem() }
            return Self.clamp(name, reservingBytesFor: "")
        }

        var stem = Self.sanitize(result)
        if stem.isEmpty { stem = fallbackStem() }
        stem = Self.clamp(stem, reservingBytesFor: ext)

        // Original extension case is preserved (Photo Mechanic behaviour). Note that the
        // {ext} token lowercases, so `{name}.{ext}` and the automatic suffix can disagree
        // in case — see README "Renaming" for how to force one or the other.
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// Strips anything that can't safely be a filename component.
    ///
    /// `/` is the path separator and `:` is the legacy HFS separator that Finder still
    /// displays as `/`. Control characters and a leading dot (which would hide the file)
    /// go too.
    public static func sanitize(_ input: String) -> String {
        var out = String(input.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            return Character(scalar)
        })

        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        while out.hasPrefix(".") { out.removeFirst() }
        while out.hasSuffix(".") { out.removeLast() }

        // Collapse runs of separators introduced by empty tokens.
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        while out.contains("__") { out = out.replacingOccurrences(of: "__", with: "_") }

        return out.trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
    }

    /// APFS/HFS+ cap filename components at 255 *bytes*, not characters.
    public static func clamp(_ stem: String, reservingBytesFor ext: String) -> String {
        let budget = 255 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        guard stem.utf8.count > budget, budget > 0 else { return stem }
        var out = stem
        while out.utf8.count > budget, !out.isEmpty { out.removeLast() }
        return out
    }

    /// Expands advanced Photo Mechanic-style tokens with parenthesized arguments.
    /// e.g., {Date(YYMMDD)}, {Sequence(001)}, {CameraModel}
    private func expandAdvancedTokens(_ input: String, date: Date, context: RenameContext) -> String {
        var result = input

        if let regex = try? NSRegularExpression(pattern: #"\{Date\(([^)]+)\)\}"#) {
            let nsRange = NSRange(result.startIndex..., in: result)
            for match in regex.matches(in: result, range: nsRange).reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let fmtRange = Range(match.range(at: 1), in: result) else { continue }
                let fmt = String(result[fmtRange])
                result.replaceSubrange(fullRange, with: formatDate(date, format: fmt))
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"\{Sequence\(([^)]+)\)\}"#) {
            let nsRange = NSRange(result.startIndex..., in: result)
            for match in regex.matches(in: result, range: nsRange).reversed() {
                guard let fullRange = Range(match.range, in: result),
                      let padRange = Range(match.range(at: 1), in: result) else { continue }
                let width = String(result[padRange]).count
                result.replaceSubrange(fullRange, with: formatSequence(context.sequence, format: "%0\(width)d"))
            }
        }

        result = replace(result, token: "{CameraModel}", with: context.camera ?? "")
        result = replace(result, token: "{Lens}", with: context.lens ?? "")
        result = replace(result, token: "{ISO}", with: context.iso ?? "")
        result = replace(result, token: "{Rating}", with: context.rating ?? "")

        return result
    }

    private func replace(_ string: String, token: String, with replacement: String) -> String {
        return string.replacingOccurrences(of: token, with: replacement)
    }

    /// Locale-independent by construction. A plain `DateFormatter` inherits the user's
    /// locale, so `yyyyMMdd` produced Buddhist-era `25690817` on a Thai-configured Mac.
    private func formatDate(_ date: Date, format: String) -> String {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = formatterCache[format] {
            return cached.string(from: date)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = format
        formatterCache[format] = formatter
        return formatter.string(from: date)
    }

    private func formatSequence(_ seq: Int, format: String) -> String {
        return String(format: format, seq)
    }
}

public struct RenameOperation: Equatable, Sendable {
    public let originalURL: URL
    public let newURL: URL
    /// The paired JPEG of a RAW+JPEG pair, renamed to the same stem with its own extension.
    public let pairedOriginalURL: URL?
    public let pairedNewURL: URL?

    public init(originalURL: URL, newURL: URL,
                pairedOriginalURL: URL? = nil, pairedNewURL: URL? = nil) {
        self.originalURL = originalURL
        self.newURL = newURL
        self.pairedOriginalURL = pairedOriginalURL
        self.pairedNewURL = pairedNewURL
    }

    /// Every file this operation touches, primary first.
    var fileMoves: [(from: URL, to: URL)] {
        var moves: [(URL, URL)] = [(originalURL, newURL)]
        if let pairedOriginalURL, let pairedNewURL {
            moves.append((pairedOriginalURL, pairedNewURL))
        }
        return moves
    }
}

public enum RenameError: Error {
    case collisionsDetected([URL])
    case moveFailed(url: URL, underlying: Error)
    /// A rollback could not fully restore the original names. Names the files left moved.
    case rollbackIncomplete(stranded: [URL], underlying: Error)
}

/// Owns batch rename execution and the undo stack.
///
/// `@unchecked Sendable` with an explicit lock, because this now lives on the view model
/// (so undo survives the modal being dismissed) but the actual file moves run off the main
/// actor — it has to be able to cross isolation boundaries.
public final class BatchRenamer: @unchecked Sendable {

    private var undoStack: [[RenameOperation]] = []
    private let stackLock = NSLock()
    private let sidecarExtension = "xmp"

    public init() {}

    private func pushUndo(_ operations: [RenameOperation]) {
        stackLock.lock()
        defer { stackLock.unlock() }
        undoStack.append(operations)
    }

    private func popUndo() -> [RenameOperation]? {
        stackLock.lock()
        defer { stackLock.unlock() }
        return undoStack.popLast()
    }

    /// Previews a batch rename and returns collisions if any.
    public func preview(items: [RenameContext], template: String,
                        formatter: RenameFormatter = RenameFormatter()) -> (operations: [RenameOperation], collisions: [URL]) {
        var operations: [RenameOperation] = []
        var claimedNames: Set<String> = []
        var collisions: [URL] = []

        // Everything being renamed is fair game to overwrite — it's moving too.
        var originalPaths = Set(items.map { $0.originalURL.standardizedFileURL.path })
        for item in items where item.pairedURL != nil {
            originalPaths.insert(item.pairedURL!.standardizedFileURL.path)
        }

        for item in items {
            let newName = formatter.format(template: template, context: item)
            let directory = item.originalURL.deletingLastPathComponent()
            let newURL = directory.appendingPathComponent(newName)

            var pairedNewURL: URL?
            if let pairedURL = item.pairedURL {
                let stem = (newName as NSString).deletingPathExtension
                let pairedExt = pairedURL.pathExtension
                pairedNewURL = pairedURL.deletingLastPathComponent()
                    .appendingPathComponent(pairedExt.isEmpty ? stem : "\(stem).\(pairedExt)")
            }

            var collided = false
            for candidate in [newURL, pairedNewURL].compactMap({ $0 }) {
                let key = candidate.deletingLastPathComponent().path + "/" + candidate.lastPathComponent.lowercased()
                if claimedNames.contains(key) {
                    collided = true
                } else {
                    claimedNames.insert(key)
                }
                if FileManager.default.fileExists(atPath: candidate.path),
                   !originalPaths.contains(candidate.standardizedFileURL.path) {
                    collided = true
                }
            }

            if collided { collisions.append(item.originalURL) }

            operations.append(RenameOperation(originalURL: item.originalURL,
                                              newURL: newURL,
                                              pairedOriginalURL: item.pairedURL,
                                              pairedNewURL: pairedNewURL))
        }

        return (operations, collisions)
    }

    /// Executes a batch rename in two phases and adds it to the undo stack.
    ///
    /// Phase 1 moves every source to a unique temp name in its own directory; phase 2 moves
    /// the temps to their final names. A single-phase sequential rename could not express a
    /// swap or a shifted sequence (A→B while B→C), because the first move would collide
    /// with a file that hadn't been renamed yet.
    ///
    /// If anything fails, everything already moved is put back, and a rollback that can't
    /// complete is reported rather than swallowed — the previous implementation used `try?`
    /// throughout, so a failed rollback left a half-renamed folder with no error at all.
    public func execute(operations: [RenameOperation]) throws {
        let effective = operations.filter { op in
            op.originalURL != op.newURL || op.pairedOriginalURL != op.pairedNewURL
        }
        guard !effective.isEmpty else { return }

        let fm = FileManager.default
        let batchToken = UUID().uuidString

        // from → temp, recorded so we can unwind in either direction.
        var staged: [(source: URL, temp: URL, destination: URL)] = []

        func tempURL(for url: URL) -> URL {
            url.deletingLastPathComponent()
                .appendingPathComponent(".pcrename-\(batchToken)-\(UUID().uuidString)")
        }

        // ── Phase 1: park every file (and its sidecar) under a unique temp name ─────
        do {
            for op in effective {
                for move in op.fileMoves where move.from != move.to {
                    let temp = tempURL(for: move.from)
                    try fm.moveItem(at: move.from, to: temp)
                    staged.append((move.from, temp, move.to))

                    let sourceSidecar = move.from.deletingPathExtension().appendingPathExtension(sidecarExtension)
                    if fm.fileExists(atPath: sourceSidecar.path) {
                        let sidecarTemp = tempURL(for: sourceSidecar)
                        let destinationSidecar = move.to.deletingPathExtension().appendingPathExtension(sidecarExtension)
                        try fm.moveItem(at: sourceSidecar, to: sidecarTemp)
                        staged.append((sourceSidecar, sidecarTemp, destinationSidecar))
                    }
                }
            }
        } catch {
            try unwindToSources(staged, underlying: error)
            throw RenameError.moveFailed(url: staged.last?.source ?? effective[0].originalURL, underlying: error)
        }

        // ── Phase 2: temp → final ──────────────────────────────────────────────────
        var completedIndex = 0
        do {
            for entry in staged {
                try fm.moveItem(at: entry.temp, to: entry.destination)
                completedIndex += 1
            }
        } catch {
            // Put the finished ones back to temp, then everything back to source.
            for entry in staged.prefix(completedIndex).reversed() {
                try? fm.moveItem(at: entry.destination, to: entry.temp)
            }
            try unwindToSources(staged, underlying: error)
            throw RenameError.moveFailed(url: staged[min(completedIndex, staged.count - 1)].source, underlying: error)
        }

        pushUndo(effective)
    }

    /// Restores staged files to their original names, reporting anything left stranded.
    private func unwindToSources(_ staged: [(source: URL, temp: URL, destination: URL)],
                                 underlying: Error) throws {
        let fm = FileManager.default
        var stranded: [URL] = []

        for entry in staged.reversed() {
            guard fm.fileExists(atPath: entry.temp.path) else { continue }
            do { try fm.moveItem(at: entry.temp, to: entry.source) }
            catch { stranded.append(entry.temp) }
        }

        if !stranded.isEmpty {
            throw RenameError.rollbackIncomplete(stranded: stranded, underlying: underlying)
        }
    }

    public func canUndo() -> Bool {
        stackLock.lock()
        defer { stackLock.unlock() }
        return !undoStack.isEmpty
    }

    public func undo() throws {
        guard let lastBatch = popUndo() else { return }
        let inverted = lastBatch.map { op in
            RenameOperation(originalURL: op.newURL,
                            newURL: op.originalURL,
                            pairedOriginalURL: op.pairedNewURL,
                            pairedNewURL: op.pairedOriginalURL)
        }
        do {
            // Run the inverse through the same two-phase machinery, then drop the entry the
            // undo itself just pushed so undo isn't its own redo.
            try execute(operations: inverted)
            _ = popUndo()
        } catch {
            // Undo failed — put the batch back so the user can retry.
            pushUndo(lastBatch)
            throw error
        }
    }
}

// Extension to help with dates
extension URL {
    var creationDate: Date? {
        return (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }
}
