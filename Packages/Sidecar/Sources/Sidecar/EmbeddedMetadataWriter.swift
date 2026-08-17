import Foundation
import ImageIO
import CoreGraphics

/// Writes metadata directly into image files (EXIF/IPTC/XMP embedded)
/// so that Finder, Preview, and other macOS apps can read ratings and labels.
///
/// This complements the XMP sidecar writer — sidecars are the non-destructive
/// standard for pro tools (Lightroom, Photo Mechanic), while embedded metadata
/// is what macOS and consumer apps read.
public final class EmbeddedMetadataWriter: Sendable {
    
    public init() {}
    
    /// RAW formats that don't support IPTC embedding and are too large to re-encode.
    /// Writing to these would either fail or take 10+ seconds, blocking file access.
    private static let rawExtensions: Set<String> = [
        "cr2", "cr3", "nef", "arw", "orf", "rw2", "dng", "raf",
        "pef", "srw", "x3f", "3fr", "iiq", "rwl", "mrw"
    ]
    
    /// Writes rating and IPTC fields directly into the image file's metadata.
    /// Uses CGImageSource/CGImageDestination to preserve existing image data.
    public func write(_ metadata: PhotoMetadata, to imageURL: URL) throws {
        guard FileManager.default.fileExists(atPath: imageURL.path) else {
            throw SidecarError.fileNotFound
        }
        
        // Skip RAW files — they don't support IPTC embedding and re-encoding
        // a 40MB+ RAW file blocks the I/O pipeline, causing the app to hang.
        let ext = imageURL.pathExtension.lowercased()
        guard !Self.rawExtensions.contains(ext) else { return }
        
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
            throw SidecarError.unreadable
        }
        
        let uti = CGImageSourceGetType(source)
        guard let uti else {
            throw SidecarError.unreadable
        }
        
        // Build the metadata dictionary to merge
        var properties: [String: Any] = [:]
        
        // IPTC metadata
        var iptc: [String: Any] = [:]
        if metadata.rating > 0 {
            iptc[kCGImagePropertyIPTCStarRating as String] = metadata.rating
        }
        if let headline = metadata.headline, !headline.isEmpty {
            iptc[kCGImagePropertyIPTCHeadline as String] = headline
        }
        if let description = metadata.description, !description.isEmpty {
            iptc[kCGImagePropertyIPTCCaptionAbstract as String] = description
        }
        if let creator = metadata.creator, !creator.isEmpty {
            iptc[kCGImagePropertyIPTCByline as String] = creator
        }
        if let copyright = metadata.copyright, !copyright.isEmpty {
            iptc[kCGImagePropertyIPTCCopyrightNotice as String] = copyright
        }
        if !iptc.isEmpty {
            properties[kCGImagePropertyIPTCDictionary as String] = iptc
        }
        
        // EXIF doesn't have a standard rating field, but TIFF does via
        // the Windows-compatible Rating tag. Some apps read this.
        var tiff: [String: Any] = [:]
        if let copyright = metadata.copyright, !copyright.isEmpty {
            tiff[kCGImagePropertyTIFFCopyright as String] = copyright
        }
        if let creator = metadata.creator, !creator.isEmpty {
            tiff[kCGImagePropertyTIFFArtist as String] = creator
        }
        if let description = metadata.description, !description.isEmpty {
            tiff[kCGImagePropertyTIFFImageDescription as String] = description
        }
        if !tiff.isEmpty {
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        
        guard !properties.isEmpty else { return }
        
        // Write to a temp file then replace
        let tempURL = imageURL.deletingLastPathComponent()
            .appendingPathComponent(".\(imageURL.lastPathComponent).embed.tmp")
        
        guard let destination = CGImageDestinationCreateWithURL(
            tempURL as CFURL,
            uti,
            CGImageSourceGetCount(source),
            nil
        ) else {
            throw SidecarError.writeFailed
        }
        
        // Copy all frames with merged metadata
        let count = CGImageSourceGetCount(source)
        for i in 0..<count {
            let existingProps = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [String: Any] ?? [:]
            let merged = mergeProperties(existing: existingProps, updates: properties)
            CGImageDestinationAddImageFromSource(destination, source, i, merged as CFDictionary)
        }
        
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: tempURL)
            throw SidecarError.writeFailed
        }
        
        // Atomic replace
        do {
            _ = try FileManager.default.replaceItemAt(imageURL, withItemAt: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw SidecarError.writeFailed
        }
    }
    
    /// Deep-merges update dictionaries into existing properties,
    /// preserving EXIF data we don't touch (e.g. GPS, lens info).
    private func mergeProperties(existing: [String: Any], updates: [String: Any]) -> [String: Any] {
        var result = existing
        for (key, value) in updates {
            if let existingDict = result[key] as? [String: Any],
               let updateDict = value as? [String: Any] {
                // Merge sub-dictionaries (e.g., IPTC, TIFF)
                var merged = existingDict
                for (subKey, subValue) in updateDict {
                    merged[subKey] = subValue
                }
                result[key] = merged
            } else {
                result[key] = value
            }
        }
        return result
    }
}

// MARK: - Finder Tag Writer

extension EmbeddedMetadataWriter {
    
    private static let userTagsAttribute = "com.apple.metadata:_kMDItemUserTags"

    /// The Finder tag names this app manages. Only these are ever removed — anything else
    /// on the file belongs to the user.
    private static let managedTagNames: Set<String> = ["Red", "Orange", "Yellow", "Green", "Blue", "Purple"]

    /// Maps XMP color labels to macOS Finder tag colors and writes them
    /// as extended attributes so colors appear in Finder's tag column.
    ///
    /// Merges into the file's existing tags rather than replacing them. The previous
    /// implementation wrote a single-element array over the whole tag list, so a
    /// photographer who organizes with their own Finder tags lost every one of them the
    /// first time they pressed a color key.
    public func writeFinderTags(for metadata: PhotoMetadata, to imageURL: URL) throws {
        guard FileManager.default.fileExists(atPath: imageURL.path) else { return }

        let path = imageURL.path
        var tags = readFinderTags(atPath: path)

        // Drop only the color tags we own, preserving user tags and their order.
        tags.removeAll { entry in
            let name = entry.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? entry
            return Self.managedTagNames.contains(name)
        }

        if metadata.label != .none, let tagEntry = finderTagEntry(for: metadata.label) {
            tags.append(tagEntry)
        }

        if tags.isEmpty {
            removexattr(path, Self.userTagsAttribute, 0)
            return
        }

        // Finder tags are a binary plist array of "TagName\nColorIndex" strings.
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: tags,
            format: .binary,
            options: 0
        )

        let result = plistData.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return setxattr(path, Self.userTagsAttribute, base, buffer.count, 0, 0)
        }
        if result != 0 {
            throw SidecarError.writeFailed
        }
    }

    /// Reads the existing Finder tag array, or an empty array if the file has none.
    public func readFinderTags(atPath path: String) -> [String] {
        let size = getxattr(path, Self.userTagsAttribute, nil, 0, 0, 0)
        guard size > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        let read = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return -1 }
            return getxattr(path, Self.userTagsAttribute, base, size, 0, 0)
        }
        guard read > 0 else { return [] }

        let data = Data(buffer.prefix(read))
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return (plist as? [String]) ?? []
    }
    
    /// Returns a Finder tag entry string in the format "Name\nColorIndex".
    /// Finder uses color indices: 0=None, 1=Gray, 2=Green, 3=Purple,
    /// 4=Blue, 5=Yellow, 6=Red, 7=Orange
    private func finderTagEntry(for label: ColorLabel) -> String? {
        switch label {
        case .red:     return "Red\n6"
        case .orange:  return "Orange\n7"
        case .yellow:  return "Yellow\n5"
        case .green:   return "Green\n2"
        case .blue:    return "Blue\n4"
        case .purple:  return "Purple\n3"
        case .cyan:    return "Blue\n4"      // No cyan in Finder — map to Blue
        case .magenta: return "Purple\n3"    // No magenta in Finder — map to Purple
        case .none:    return nil
        }
    }
}
