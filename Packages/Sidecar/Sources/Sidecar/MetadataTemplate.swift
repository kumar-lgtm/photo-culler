import Foundation

/// A reusable metadata template ("Stationery Pad") that stores
/// default IPTC values to bulk-apply during culling or ingest.
public struct MetadataTemplate: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var headline: String
    public var description: String
    public var creator: String
    public var copyright: String
    
    public init(id: UUID = UUID(), name: String = "Untitled", headline: String = "", description: String = "", creator: String = "", copyright: String = "") {
        self.id = id
        self.name = name
        self.headline = headline
        self.description = description
        self.creator = creator
        self.copyright = copyright
    }
    
    /// Apply this template's values onto a PhotoMetadata, preserving existing rating and label.
    public func apply(to metadata: PhotoMetadata) -> PhotoMetadata {
        var result = metadata
        if !headline.isEmpty { result.headline = headline }
        if !description.isEmpty { result.description = description }
        if !creator.isEmpty { result.creator = creator }
        if !copyright.isEmpty { result.copyright = copyright }
        return result
    }
}

/// Manages persistent storage of metadata templates.
public final class TemplateManager: Sendable {
    private let storageURL: URL
    
    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appending(path: "PhotoCuller")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appending(path: "metadata_templates.json")
    }
    
    public func loadTemplates() -> [MetadataTemplate] {
        guard FileManager.default.fileExists(atPath: storageURL.path),
              let data = try? Data(contentsOf: storageURL),
              let templates = try? JSONDecoder().decode([MetadataTemplate].self, from: data) else {
            return []
        }
        return templates
    }
    
    public func saveTemplates(_ templates: [MetadataTemplate]) {
        guard let data = try? JSONEncoder().encode(templates) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
