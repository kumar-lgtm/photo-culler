import Foundation

public enum ColorLabel: String, CaseIterable, Equatable, Sendable {
    case red = "Red"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    case orange = "Orange"
    case cyan = "Cyan"
    case magenta = "Magenta"
    case none = ""
}

/// Culling flag — orthogonal to star rating and color label. Pick = keeper, Reject = cut.
public enum PhotoFlag: String, Equatable, Sendable {
    case none = ""
    case pick = "pick"
    case reject = "reject"
}

public struct PhotoMetadata: Equatable, Sendable {
    public var rating: Int // 0-5
    public var label: ColorLabel
    public var flag: PhotoFlag

    // IPTC / XMP fields
    public var headline: String?
    public var description: String? // Caption
    public var creator: String?     // Photographer
    public var copyright: String?

    public init(rating: Int = 0, label: ColorLabel = .none, flag: PhotoFlag = .none, headline: String? = nil, description: String? = nil, creator: String? = nil, copyright: String? = nil) {
        self.rating = max(0, min(5, rating))
        self.label = label
        self.flag = flag
        self.headline = headline
        self.description = description
        self.creator = creator
        self.copyright = copyright
    }
}

public enum SidecarError: Error {
    case fileNotFound
    case unreadable
    case writeFailed
    case invalidXML
}

public final class SidecarManager: Sendable {
    
    public init() {}
    
    /// Reads XMP metadata from the specified file path.
    public func read(from url: URL) throws -> PhotoMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SidecarError.fileNotFound
        }
        
        let data = try Data(contentsOf: url)
        guard let document = try? XMLDocument(data: data, options: []) else {
            throw SidecarError.invalidXML
        }
        
        var metadata = PhotoMetadata()
        
        // Find xmp:Rating
        if let ratingNodes = try? document.nodes(forXPath: "//xmp:Rating"),
           let ratingString = ratingNodes.first?.stringValue,
           let rating = Int(ratingString) {
            metadata.rating = rating
        }
        
        // Find xmp:Label
        if let labelNodes = try? document.nodes(forXPath: "//xmp:Label"),
           let labelString = labelNodes.first?.stringValue,
           let label = ColorLabel(rawValue: labelString) {
            metadata.label = label
        }
        
        // Find pc:Flag (PhotoCuller pick/reject flag)
        if let flagNodes = try? document.nodes(forXPath: "//pc:Flag"),
           let flagString = flagNodes.first?.stringValue,
           let flag = PhotoFlag(rawValue: flagString) {
            metadata.flag = flag
        }

        // Find photoshop:Headline
        if let headlineNodes = try? document.nodes(forXPath: "//photoshop:Headline"),
           let headlineString = headlineNodes.first?.stringValue {
            metadata.headline = headlineString
        }
        
        // Find dc:description (This is usually an rdf:Alt array, but we can try to extract string)
        if let descNodes = try? document.nodes(forXPath: "//dc:description//rdf:li"),
           let descString = descNodes.first?.stringValue {
            metadata.description = descString
        } else if let descNodes = try? document.nodes(forXPath: "//dc:description"),
                  let descString = descNodes.first?.stringValue, !descString.isEmpty {
            metadata.description = descString
        }
        
        // Find dc:creator
        if let creatorNodes = try? document.nodes(forXPath: "//dc:creator//rdf:li"),
           let creatorString = creatorNodes.first?.stringValue {
            metadata.creator = creatorString
        }
        
        // Find dc:rights
        if let rightsNodes = try? document.nodes(forXPath: "//dc:rights//rdf:li"),
           let rightsString = rightsNodes.first?.stringValue {
            metadata.copyright = rightsString
        }
        
        return metadata
    }
    
    /// Writes XMP metadata to the specified file path. Preserves existing metadata.
    public func write(_ metadata: PhotoMetadata, to url: URL) throws {
        var document: XMLDocument
        
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existingDoc = try? XMLDocument(data: data, options: []) {
            document = existingDoc
        } else {
            // Create default XMP structure
            document = createEmptyXMPDocument()
        }
        
        try update(document: document, with: metadata)
        
        let xmlData = document.xmlData(options: [.nodePrettyPrint])
        
        // Atomic write
        let tempURL = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).tmp")
        do {
            try xmlData.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
            
            // Hide the XMP file from Finder so it doesn't clutter the user's view.
            // Pro tools (Lightroom, Photo Mechanic) will still read it perfectly fine.
            var mutableURL = url
            var resourceValues = URLResourceValues()
            resourceValues.isHidden = true
            try? mutableURL.setResourceValues(resourceValues)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw SidecarError.writeFailed
        }
    }
    
    private func update(document: XMLDocument, with metadata: PhotoMetadata) throws {
        // Ensure xmp: and rdf: namespaces are available by finding the rdf:Description node
        guard let descriptionNodes = try? document.nodes(forXPath: "//rdf:Description"),
              let descriptionElement = descriptionNodes.first as? XMLElement else {
            return
        }
        
        // Update xmp:Rating
        updateOrAddChild(to: descriptionElement, name: "xmp:Rating", value: metadata.rating > 0 ? "\(metadata.rating)" : nil)
        
        // Update xmp:Label
        updateOrAddChild(to: descriptionElement, name: "xmp:Label", value: metadata.label != .none ? metadata.label.rawValue : nil)

        // Update pc:Flag (PhotoCuller pick/reject). Ensure the pc namespace is declared so
        // the prefixed element round-trips on re-read (sidecars from pro tools won't have it).
        if descriptionElement.attribute(forName: "xmlns:pc") == nil {
            descriptionElement.addAttribute(XMLNode.attribute(withName: "xmlns:pc", stringValue: "http://photoculler.app/ns/1.0/") as! XMLNode)
        }
        updateOrAddChild(to: descriptionElement, name: "pc:Flag", value: metadata.flag != .none ? metadata.flag.rawValue : nil)
        
        // Update photoshop:Headline
        updateOrAddChild(to: descriptionElement, name: "photoshop:Headline", value: metadata.headline)
        
        // Update dc:description
        updateOrAddArrayChild(to: descriptionElement, name: "dc:description", value: metadata.description, arrayType: "rdf:Alt")
        
        // Update dc:creator
        updateOrAddArrayChild(to: descriptionElement, name: "dc:creator", value: metadata.creator, arrayType: "rdf:Seq")
        
        // Update dc:rights
        updateOrAddArrayChild(to: descriptionElement, name: "dc:rights", value: metadata.copyright, arrayType: "rdf:Alt")
        
        // Update xmp:MetadataDate
        let formatter = ISO8601DateFormatter()
        let dateString = formatter.string(from: Date())
        updateOrAddChild(to: descriptionElement, name: "xmp:MetadataDate", value: dateString)
    }
    
    private func updateOrAddChild(to element: XMLElement, name: String, value: String?) {
        if let existing = element.elements(forName: name).first {
            if let value = value {
                existing.stringValue = value
            } else {
                // If value is nil, remove the element (e.g. 0 rating)
                if let index = element.children?.firstIndex(of: existing) {
                    element.removeChild(at: index)
                }
            }
        } else if let value = value {
            let newNode = XMLElement(name: name, stringValue: value)
            element.addChild(newNode)
        }
    }
    
    private func updateOrAddArrayChild(to element: XMLElement, name: String, value: String?, arrayType: String) {
        if let existing = element.elements(forName: name).first {
            if let value = value, !value.isEmpty {
                // Update existing array item
                if let arrayNode = existing.elements(forName: arrayType).first,
                   let liNode = arrayNode.elements(forName: "rdf:li").first {
                    liNode.stringValue = value
                } else {
                    // Malformed or missing array inside the wrapper
                    existing.setChildren(nil)
                    let arrayNode = XMLElement(name: arrayType)
                    let liNode = XMLElement(name: "rdf:li", stringValue: value)
                    arrayNode.addChild(liNode)
                    existing.addChild(arrayNode)
                }
            } else {
                if let index = element.children?.firstIndex(of: existing) {
                    element.removeChild(at: index)
                }
            }
        } else if let value = value, !value.isEmpty {
            let wrapper = XMLElement(name: name)
            let arrayNode = XMLElement(name: arrayType)
            let liNode = XMLElement(name: "rdf:li", stringValue: value)
            arrayNode.addChild(liNode)
            wrapper.addChild(arrayNode)
            element.addChild(wrapper)
        }
    }
    
    private func createEmptyXMPDocument() -> XMLDocument {
        let root = XMLElement(name: "x:xmpmeta")
        // Add namespaces
        root.addAttribute(XMLNode.attribute(withName: "xmlns:x", stringValue: "adobe:ns:meta/") as! XMLNode)
        root.addAttribute(XMLNode.attribute(withName: "x:xmptk", stringValue: "PhotoCuller 1.0") as! XMLNode)
        
        let rdf = XMLElement(name: "rdf:RDF")
        rdf.addAttribute(XMLNode.attribute(withName: "xmlns:rdf", stringValue: "http://www.w3.org/1999/02/22-rdf-syntax-ns#") as! XMLNode)
        root.addChild(rdf)
        
        let description = XMLElement(name: "rdf:Description")
        description.addAttribute(XMLNode.attribute(withName: "rdf:about", stringValue: "") as! XMLNode)
        description.addAttribute(XMLNode.attribute(withName: "xmlns:xmp", stringValue: "http://ns.adobe.com/xap/1.0/") as! XMLNode)
        description.addAttribute(XMLNode.attribute(withName: "xmlns:photoshop", stringValue: "http://ns.adobe.com/photoshop/1.0/") as! XMLNode)
        description.addAttribute(XMLNode.attribute(withName: "xmlns:dc", stringValue: "http://purl.org/dc/elements/1.1/") as! XMLNode)
        description.addAttribute(XMLNode.attribute(withName: "xmlns:pc", stringValue: "http://photoculler.app/ns/1.0/") as! XMLNode)
        rdf.addChild(description)
        
        let document = XMLDocument(rootElement: root)
        return document
    }
}
