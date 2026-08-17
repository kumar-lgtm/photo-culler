import Foundation
import Sidecar

/// Covers the P0 write-safety fixes and the Adobe interop fixes.
enum SidecarSuite {

    static func run(_ t: TestRunner) async throws {
        t.suite("Sidecar — round trip")
        try roundTrip(t)

        t.suite("Sidecar — Adobe attribute-form interop (3.1)")
        try adobeAttributeForm(t)

        t.suite("Sidecar — legacy element form still readable")
        try legacyElementForm(t)

        t.suite("Sidecar — alternate prefix resolves by namespace URI")
        try alternatePrefix(t)

        t.suite("Sidecar — duplicate forms are healed on write")
        try duplicateHealing(t)

        t.suite("Sidecar — malformed structure no longer silently no-ops (3.2)")
        try malformedStructure(t)

        t.suite("Sidecar — files are not hidden (3.3)")
        try notHidden(t)

        t.suite("Sidecar — write coordinator serialization (2.1)")
        try await coordinatorSerialization(t)

        t.suite("Finder tags — user tags preserved (2.3)")
        try finderTagMerge(t)
    }

    // MARK: -

    private static func roundTrip(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let url = dir.appendingPathComponent("shot.xmp")
        let manager = SidecarManager()

        let original = PhotoMetadata(rating: 4, label: .red, flag: .pick,
                                     headline: "Final whistle",
                                     description: "Keeper lifts the trophy",
                                     creator: "Braveen Kumar",
                                     copyright: "© Kumar Creative Inc.")
        try manager.write(original, to: url)
        let read = try manager.read(from: url)

        t.equal(read.rating, 4, "rating round-trips")
        t.equal(read.label, .red, "label round-trips")
        t.equal(read.flag, .pick, "pick/reject flag round-trips")
        t.equal(read.headline, "Final whistle", "headline round-trips")
        t.equal(read.description, "Keeper lifts the trophy", "caption round-trips")
        t.equal(read.creator, "Braveen Kumar", "creator round-trips")
        t.equal(read.copyright, "© Kumar Creative Inc.", "copyright round-trips")

        // Clearing values removes them rather than writing empties.
        var cleared = read
        cleared.rating = 0
        cleared.label = .none
        cleared.flag = .none
        try manager.write(cleared, to: url)
        let reread = try manager.read(from: url)
        t.equal(reread.rating, 0, "clearing rating persists")
        t.equal(reread.label, .none, "clearing label persists")
        t.equal(reread.flag, .none, "clearing flag persists")
        t.equal(reread.headline, "Final whistle", "clearing rating leaves IPTC intact")
    }

    /// A sidecar exactly as Lightroom/Bridge write it: values are attributes, not elements.
    private static func adobeAttributeForm(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let url = dir.appendingPathComponent("adobe.xmp")

        try url.writeText("""
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 9.0">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmp:Rating="4"
              xmp:Label="Red"
              photoshop:Headline="Existing headline">
              <dc:creator><rdf:Seq><rdf:li>Ansel Adams</rdf:li></rdf:Seq></dc:creator>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """)

        let manager = SidecarManager()
        let read = try manager.read(from: url)

        // This is the headline interop bug: it used to return 0 here.
        t.equal(read.rating, 4, "reads xmp:Rating written as an attribute")
        t.equal(read.label, .red, "reads xmp:Label written as an attribute")
        t.equal(read.headline, "Existing headline", "reads photoshop:Headline attribute")
        t.equal(read.creator, "Ansel Adams", "reads dc:creator rdf:Seq")

        // Writing back must update the attribute in place, not append a rival element.
        var updated = read
        updated.rating = 2
        try manager.write(updated, to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        t.check(raw.contains("xmp:Rating=\"2\""), "updates the existing attribute in place")
        t.check(!raw.contains("<xmp:Rating>"), "does not append a conflicting child element")
        t.equal(try manager.read(from: url).rating, 2, "re-reads the updated attribute value")
        t.equal(try manager.read(from: url).creator, "Ansel Adams", "preserves untouched fields")
    }

    private static func legacyElementForm(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let url = dir.appendingPathComponent("legacy.xmp")

        try url.writeText("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/">
              <xmp:Rating>5</xmp:Rating>
              <xmp:Label>Blue</xmp:Label>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """)

        let manager = SidecarManager()
        t.equal(try manager.read(from: url).rating, 5, "reads element-form rating")
        t.equal(try manager.read(from: url).label, .blue, "reads element-form label")

        var updated = try manager.read(from: url)
        updated.rating = 1
        try manager.write(updated, to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        t.check(raw.contains("<xmp:Rating>1</xmp:Rating>"), "keeps element form when the file already uses it")
        t.check(!raw.contains("xmp:Rating=\"1\""), "does not also add an attribute")
    }

    /// Older Adobe files bind the same namespace to the `xap:` prefix.
    private static func alternatePrefix(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let url = dir.appendingPathComponent("xap.xmp")

        try url.writeText("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xap="http://ns.adobe.com/xap/1.0/"
              xap:Rating="3"/>
          </rdf:RDF>
        </x:xmpmeta>
        """)

        t.equal(try SidecarManager().read(from: url).rating, 3,
                "matches by namespace URI, not by prefix")
    }

    private static func duplicateHealing(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let url = dir.appendingPathComponent("dupe.xmp")

        // Exactly the corruption the old writer produced: attribute AND element.
        try url.writeText("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmp:Rating="1">
              <xmp:Rating>5</xmp:Rating>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """)

        let manager = SidecarManager()
        t.equal(try manager.read(from: url).rating, 1, "attribute wins on read, matching Adobe")

        var updated = try manager.read(from: url)
        updated.rating = 4
        try manager.write(updated, to: url)

        let raw = try String(contentsOf: url, encoding: .utf8)
        t.check(raw.contains("xmp:Rating=\"4\""), "attribute updated")
        t.check(!raw.contains("<xmp:Rating>"), "stale duplicate element removed")
    }

    private static func malformedStructure(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let url = dir.appendingPathComponent("nodesc.xmp")

        // Valid XML, but no rdf:Description — the old code returned silently and claimed success.
        try url.writeText("""
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"/>
        </x:xmpmeta>
        """)

        let manager = SidecarManager()
        try manager.write(PhotoMetadata(rating: 3, label: .green), to: url)

        let read = try manager.read(from: url)
        t.equal(read.rating, 3, "builds the missing rdf:Description and persists")
        t.equal(read.label, .green, "label persists into the rebuilt structure")
    }

    private static func notHidden(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let url = dir.appendingPathComponent("visible.xmp")

        try SidecarManager().write(PhotoMetadata(rating: 2), to: url)

        t.check(url.exists, "sidecar written")
        t.check(!url.isHiddenFlag, "sidecar is visible to Finder, backups and Lightroom import")

        // And no scratch file left lying around.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        t.equal(leftovers.filter { $0.contains(".tmp") }.count, 0, "no temp files left behind")
    }

    /// The core P0: hammer one file the way a photographer hammers rating keys.
    private static func coordinatorSerialization(_ t: TestRunner) async throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let imageURL = dir.appendingPathComponent("burst.jpg")
        try Data("not-a-real-jpeg".utf8).write(to: imageURL)
        let sidecarURL = dir.appendingPathComponent("burst.xmp")

        let coordinator = MetadataWriteCoordinator()

        // 40 rapid-fire edits, alternating rating and label, ending in a known state.
        var metadata = PhotoMetadata()
        for i in 1...40 {
            metadata.rating = (i % 5) + 1
            metadata.label = [.red, .yellow, .green, .blue][i % 4]
            coordinator.submit(.init(metadata: metadata,
                                           sidecarURL: sidecarURL,
                                           imageURL: imageURL))
        }
        let finalState = metadata

        await coordinator.flush()

        t.check(sidecarURL.exists, "sidecar exists after a burst of writes")

        let read = try SidecarManager().read(from: sidecarURL)
        t.equal(read.rating, finalState.rating, "converges on the LAST submitted rating")
        t.equal(read.label, finalState.label, "converges on the LAST submitted label")

        // Torn/half-written files are the other half of this bug.
        let raw = try String(contentsOf: sidecarURL, encoding: .utf8)
        t.check(raw.contains("</x:xmpmeta>"), "file is complete, not truncated by a colliding write")

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        t.equal(leftovers.filter { $0.contains(".tmp") }.count, 0, "no orphaned temp files after 40 writes")

        // Concurrent writes to *different* files must still both land.
        let a = dir.appendingPathComponent("a.xmp")
        let b = dir.appendingPathComponent("b.xmp")
        coordinator.submit(.init(metadata: PhotoMetadata(rating: 1), sidecarURL: a, imageURL: imageURL))
        coordinator.submit(.init(metadata: PhotoMetadata(rating: 5), sidecarURL: b, imageURL: imageURL))
        await coordinator.flush()
        t.equal(try SidecarManager().read(from: a).rating, 1, "independent file A written")
        t.equal(try SidecarManager().read(from: b).rating, 5, "independent file B written")
    }

    private static func finderTagMerge(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let imageURL = dir.appendingPathComponent("tagged.jpg")
        try Data("payload".utf8).write(to: imageURL)

        let writer = EmbeddedMetadataWriter()

        // The user's own tags, set in Finder.
        let userTags = ["Client Work\n0", "Portfolio\n0"]
        let plist = try PropertyListSerialization.data(fromPropertyList: userTags, format: .binary, options: 0)
        _ = plist.withUnsafeBytes { buf in
            setxattr(imageURL.path, "com.apple.metadata:_kMDItemUserTags", buf.baseAddress, buf.count, 0, 0)
        }

        try writer.writeFinderTags(for: PhotoMetadata(label: .red), to: imageURL)
        var tags = writer.readFinderTags(atPath: imageURL.path)

        t.check(tags.contains("Client Work\n0"), "user tag 'Client Work' survives a color label")
        t.check(tags.contains("Portfolio\n0"), "user tag 'Portfolio' survives a color label")
        t.check(tags.contains(where: { $0.hasPrefix("Red") }), "the Red color tag is applied")

        // Switching color replaces only the managed one.
        try writer.writeFinderTags(for: PhotoMetadata(label: .green), to: imageURL)
        tags = writer.readFinderTags(atPath: imageURL.path)
        t.check(tags.contains("Client Work\n0"), "user tags survive a color change")
        t.check(tags.contains(where: { $0.hasPrefix("Green") }), "new color applied")
        t.check(!tags.contains(where: { $0.hasPrefix("Red") }), "previous color removed")

        // Clearing removes only the managed tag.
        try writer.writeFinderTags(for: PhotoMetadata(label: .none), to: imageURL)
        tags = writer.readFinderTags(atPath: imageURL.path)
        t.equal(tags.sorted(), userTags.sorted(), "clearing the label leaves exactly the user's tags")
    }
}
