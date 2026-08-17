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
    /// The document had no `rdf:Description` and one could not be created.
    case malformedStructure
}

/// XMP namespace URIs. Matched by URI rather than by prefix, because the prefix a
/// given tool chooses is arbitrary — Lightroom has historically used both `xmp:` and
/// the older `xap:` for the same namespace.
enum XMPNamespace {
    static let xmp = "http://ns.adobe.com/xap/1.0/"
    static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
    static let dc = "http://purl.org/dc/elements/1.1/"
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let photoCuller = "http://photoculler.app/ns/1.0/"
}

public final class SidecarManager: Sendable {

    public init() {}

    // MARK: - Reading

    /// Reads XMP metadata from the specified file path.
    ///
    /// Handles both serializations that real tools emit:
    ///  - **attribute form** (`<rdf:Description xmp:Rating="4"/>`) — what Adobe writes
    ///  - **element form** (`<xmp:Rating>4</xmp:Rating>`)
    ///
    /// Attributes win when both are present, matching Adobe's own precedence.
    public func read(from url: URL) throws -> PhotoMetadata {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SidecarError.fileNotFound
        }

        let data = try Data(contentsOf: url)
        guard let document = try? XMLDocument(data: data, options: []) else {
            throw SidecarError.invalidXML
        }

        var metadata = PhotoMetadata()

        if let ratingString = simpleValue(in: document, localName: "Rating", namespace: XMPNamespace.xmp),
           let rating = Int(ratingString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            metadata.rating = max(0, min(5, rating))
        }

        if let labelString = simpleValue(in: document, localName: "Label", namespace: XMPNamespace.xmp),
           let label = ColorLabel(rawValue: labelString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            metadata.label = label
        }

        if let flagString = simpleValue(in: document, localName: "Flag", namespace: XMPNamespace.photoCuller),
           let flag = PhotoFlag(rawValue: flagString.trimmingCharacters(in: .whitespacesAndNewlines)) {
            metadata.flag = flag
        }

        metadata.headline = simpleValue(in: document, localName: "Headline", namespace: XMPNamespace.photoshop)
        metadata.description = arrayValue(in: document, localName: "description", namespace: XMPNamespace.dc)
        metadata.creator = arrayValue(in: document, localName: "creator", namespace: XMPNamespace.dc)
        metadata.copyright = arrayValue(in: document, localName: "rights", namespace: XMPNamespace.dc)

        return metadata
    }

    /// Namespace-URI-based lookup, so any prefix works. Attribute form first.
    private func simpleValue(in document: XMLDocument, localName: String, namespace: String) -> String? {
        if let attr = attributeNode(in: document, localName: localName, namespace: namespace),
           let value = attr.stringValue, !value.isEmpty {
            return value
        }
        if let element = elementNode(in: document, localName: localName, namespace: namespace),
           let value = element.stringValue, !value.isEmpty {
            return value
        }
        return nil
    }

    /// `dc:*` fields are RDF containers (`rdf:Alt` / `rdf:Seq` of `rdf:li`). Adobe also
    /// sometimes writes them as a bare attribute when there is exactly one value.
    private func arrayValue(in document: XMLDocument, localName: String, namespace: String) -> String? {
        if let element = elementNode(in: document, localName: localName, namespace: namespace) {
            let items = (try? element.nodes(forXPath: ".//*[local-name()='li']")) ?? []
            if let first = items.first?.stringValue, !first.isEmpty { return first }
            if let direct = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !direct.isEmpty {
                return direct
            }
        }
        if let attr = attributeNode(in: document, localName: localName, namespace: namespace),
           let value = attr.stringValue, !value.isEmpty {
            return value
        }
        return nil
    }

    /// Finds nodes by local name, then filters by namespace in Swift.
    ///
    /// Foundation's `XMLDocument` resolves namespaces onto `XMLNode.uri`, but its XPath
    /// engine does *not* implement `namespace-uri()` against that model — the expression
    /// silently matches nothing, and a prefixed path like `//xmp:Rating` matches nothing
    /// either, because nodes keep their literal qualified name. `local-name()` does work,
    /// so select on that and do the namespace check against `uri` where it's reliable.
    ///
    /// Nodes with no resolved namespace are accepted only when nothing matched exactly,
    /// which keeps programmatically-built documents (and files with an undeclared prefix)
    /// working without letting a foreign namespace win over the real one.
    private func matchingNodes(in document: XMLDocument, xpath: String, namespace: String) -> [XMLNode] {
        let all = (try? document.nodes(forXPath: xpath)) ?? []
        let exact = all.filter { $0.uri == namespace }
        if !exact.isEmpty { return exact }
        return all.filter { ($0.uri ?? "").isEmpty }
    }

    private func elementNode(in document: XMLDocument, localName: String, namespace: String) -> XMLElement? {
        matchingNodes(in: document,
                      xpath: "//*[local-name()='\(localName)']",
                      namespace: namespace)
            .compactMap { $0 as? XMLElement }
            .first
    }

    private func attributeNode(in document: XMLDocument, localName: String, namespace: String) -> XMLNode? {
        matchingNodes(in: document,
                      xpath: "//@*[local-name()='\(localName)']",
                      namespace: namespace)
            .first
    }

    // MARK: - Writing

    /// Writes XMP metadata to the specified file path, preserving everything it doesn't own.
    ///
    /// Writes back in whichever serialization the file already uses, defaulting to
    /// attribute form for new files (what Adobe emits). If a field somehow exists in
    /// *both* forms — which earlier versions of this app could produce — the stale
    /// duplicate is removed so the file stops carrying two conflicting values.
    public func write(_ metadata: PhotoMetadata, to url: URL) throws {
        let document: XMLDocument

        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existingDoc = try? XMLDocument(data: data, options: []) {
            document = existingDoc
        } else {
            document = createEmptyXMPDocument()
        }

        try update(document: document, with: metadata)

        let xmlData = document.xmlData(options: [.nodePrettyPrint])

        // Unique temp name: two writes racing on the same sidecar must never collide on
        // the same scratch file. (Writes are also serialized per-file by
        // MetadataWriteCoordinator — this is the belt to that suspenders.)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        do {
            try xmlData.write(to: tempURL, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try FileManager.default.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw SidecarError.writeFailed
        }
    }

    private func update(document: XMLDocument, with metadata: PhotoMetadata) throws {
        let descriptionElement = try resolveDescriptionElement(in: document)

        setValue(metadata.rating > 0 ? "\(metadata.rating)" : nil,
                 on: descriptionElement, in: document,
                 localName: "Rating", namespace: XMPNamespace.xmp, preferredPrefix: "xmp")

        setValue(metadata.label != .none ? metadata.label.rawValue : nil,
                 on: descriptionElement, in: document,
                 localName: "Label", namespace: XMPNamespace.xmp, preferredPrefix: "xmp")

        setValue(metadata.flag != .none ? metadata.flag.rawValue : nil,
                 on: descriptionElement, in: document,
                 localName: "Flag", namespace: XMPNamespace.photoCuller, preferredPrefix: "pc")

        setValue(metadata.headline,
                 on: descriptionElement, in: document,
                 localName: "Headline", namespace: XMPNamespace.photoshop, preferredPrefix: "photoshop")

        setArrayValue(metadata.description, on: descriptionElement, in: document,
                      localName: "description", namespace: XMPNamespace.dc,
                      preferredPrefix: "dc", container: "rdf:Alt")

        setArrayValue(metadata.creator, on: descriptionElement, in: document,
                      localName: "creator", namespace: XMPNamespace.dc,
                      preferredPrefix: "dc", container: "rdf:Seq")

        setArrayValue(metadata.copyright, on: descriptionElement, in: document,
                      localName: "rights", namespace: XMPNamespace.dc,
                      preferredPrefix: "dc", container: "rdf:Alt")

        let formatter = ISO8601DateFormatter()
        setValue(formatter.string(from: Date()),
                 on: descriptionElement, in: document,
                 localName: "MetadataDate", namespace: XMPNamespace.xmp, preferredPrefix: "xmp")
    }

    /// Finds the `rdf:Description` to write into, building the surrounding structure if the
    /// document is missing it. Previously this returned silently, so a sidecar with an
    /// unexpected shape reported a successful write while persisting nothing.
    private func resolveDescriptionElement(in document: XMLDocument) throws -> XMLElement {
        if let existing = elementNode(in: document, localName: "Description", namespace: XMPNamespace.rdf) {
            return existing
        }

        // No Description node — graft one onto the existing rdf:RDF, or rebuild the tree.
        let rdfElement: XMLElement
        if let existingRDF = elementNode(in: document, localName: "RDF", namespace: XMPNamespace.rdf) {
            rdfElement = existingRDF
        } else if let root = document.rootElement() {
            let created = XMLElement(name: "rdf:RDF")
            created.addAttribute(XMLNode.attribute(withName: "xmlns:rdf", stringValue: XMPNamespace.rdf) as! XMLNode)
            root.addChild(created)
            rdfElement = created
        } else {
            throw SidecarError.malformedStructure
        }

        let description = XMLElement(name: "rdf:Description")
        description.addAttribute(XMLNode.attribute(withName: "rdf:about", stringValue: "") as! XMLNode)
        rdfElement.addChild(description)
        return description
    }

    /// Writes a scalar field in whichever form the file already uses, removing the other
    /// form if it also exists so the file never carries two conflicting values.
    private func setValue(_ value: String?, on element: XMLElement, in document: XMLDocument,
                          localName: String, namespace: String, preferredPrefix: String) {
        let existingAttribute = attributeNode(in: document, localName: localName, namespace: namespace)
        let existingElement = elementNode(in: document, localName: localName, namespace: namespace)

        guard let value else {
            existingAttribute.flatMap(removeAttribute)
            existingElement.flatMap(removeElement)
            return
        }

        if let existingAttribute {
            existingAttribute.stringValue = value
            // Heal the duplicate an older build could have created.
            existingElement.flatMap(removeElement)
            return
        }

        if let existingElement {
            existingElement.stringValue = value
            return
        }

        let prefix = resolvePrefix(preferred: preferredPrefix, uri: namespace, on: element)
        element.addAttribute(XMLNode.attribute(withName: "\(prefix):\(localName)", stringValue: value) as! XMLNode)
    }

    /// RDF container fields always stay in element form — attribute form can't express a
    /// language-alternative array, and that's what `dc:` fields are.
    private func setArrayValue(_ value: String?, on element: XMLElement, in document: XMLDocument,
                               localName: String, namespace: String,
                               preferredPrefix: String, container: String) {
        let existingAttribute = attributeNode(in: document, localName: localName, namespace: namespace)
        let existingElement = elementNode(in: document, localName: localName, namespace: namespace)

        guard let value, !value.isEmpty else {
            existingAttribute.flatMap(removeAttribute)
            existingElement.flatMap(removeElement)
            return
        }

        // A single-value attribute is a legal Adobe shorthand; keep the shape if it's there.
        if let existingAttribute, existingElement == nil {
            existingAttribute.stringValue = value
            return
        }

        existingAttribute.flatMap(removeAttribute)

        let wrapper: XMLElement
        if let existingElement {
            wrapper = existingElement
            wrapper.setChildren(nil)
        } else {
            let prefix = resolvePrefix(preferred: preferredPrefix, uri: namespace, on: element)
            wrapper = XMLElement(name: "\(prefix):\(localName)")
            element.addChild(wrapper)
        }

        let containerNode = XMLElement(name: container)
        containerNode.addChild(XMLElement(name: "rdf:li", stringValue: value))
        wrapper.addChild(containerNode)
    }

    private func removeElement(_ node: XMLElement) {
        guard let parent = node.parent as? XMLElement,
              let index = parent.children?.firstIndex(of: node) else { return }
        parent.removeChild(at: index)
    }

    private func removeAttribute(_ node: XMLNode) {
        guard let owner = node.parent as? XMLElement, let name = node.name else { return }
        owner.removeAttribute(forName: name)
    }

    /// Returns the prefix bound to `uri` in this element's scope, declaring `preferred` if
    /// the namespace isn't bound anywhere up the tree.
    ///
    /// Two traps here. Foundation keeps *parsed* namespace declarations in
    /// `XMLElement.namespaces`, not in `attributes` — checking only `attributes` re-declared
    /// `xmlns:xmp` on an element that already had it, producing a duplicate attribute and
    /// therefore an XML file that would not re-parse. And a file may legitimately bind the
    /// namespace to a different prefix (older Adobe files use `xap:`), so a new attribute has
    /// to be written with the prefix actually in scope rather than our preferred one.
    private func resolvePrefix(preferred: String, uri: String, on element: XMLElement) -> String {
        var node: XMLElement? = element
        while let current = node {
            for namespace in current.namespaces ?? [] where namespace.stringValue == uri {
                if let name = namespace.name, !name.isEmpty { return name }
            }
            for attribute in current.attributes ?? [] where attribute.stringValue == uri {
                if let name = attribute.name, name.hasPrefix("xmlns:") {
                    return String(name.dropFirst("xmlns:".count))
                }
            }
            node = current.parent as? XMLElement
        }

        if let namespace = XMLNode.namespace(withName: preferred, stringValue: uri) as? XMLNode {
            element.addNamespace(namespace)
        }
        return preferred
    }

    private func createEmptyXMPDocument() -> XMLDocument {
        let root = XMLElement(name: "x:xmpmeta")
        root.addAttribute(XMLNode.attribute(withName: "xmlns:x", stringValue: "adobe:ns:meta/") as! XMLNode)
        root.addAttribute(XMLNode.attribute(withName: "x:xmptk", stringValue: "PhotoCuller 1.0") as! XMLNode)

        let rdf = XMLElement(name: "rdf:RDF")
        rdf.addAttribute(XMLNode.attribute(withName: "xmlns:rdf", stringValue: XMPNamespace.rdf) as! XMLNode)
        root.addChild(rdf)

        let description = XMLElement(name: "rdf:Description")
        description.addAttribute(XMLNode.attribute(withName: "rdf:about", stringValue: "") as! XMLNode)
        description.addAttribute(XMLNode.attribute(withName: "xmlns:xmp", stringValue: XMPNamespace.xmp) as! XMLNode)
        description.addAttribute(XMLNode.attribute(withName: "xmlns:photoshop", stringValue: XMPNamespace.photoshop) as! XMLNode)
        description.addAttribute(XMLNode.attribute(withName: "xmlns:dc", stringValue: XMPNamespace.dc) as! XMLNode)
        description.addAttribute(XMLNode.attribute(withName: "xmlns:pc", stringValue: XMPNamespace.photoCuller) as! XMLNode)
        rdf.addChild(description)

        return XMLDocument(rootElement: root)
    }
}
