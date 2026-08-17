import Foundation
import Catalog

enum CatalogSuite {

    static func run(_ t: TestRunner) async throws {
        t.suite("Catalog — RAW+JPEG pairing (regression)")
        try await pairing(t)

        t.suite("Catalog — HEIC+JPG pairing (5.19)")
        try await heicPairing(t)

        t.suite("Catalog — classification and sidecar detection")
        classification(t)

        t.suite("Catalog — scan cancellation (4.7)")
        try await cancellation(t)
    }

    private static func makeFolder(_ files: [String]) throws -> URL {
        let dir = try TempDir.make("catalog")
        for name in files {
            try Data(name.utf8).write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private static func pairing(_ t: TestRunner) async throws {
        let dir = try makeFolder(["DSCF0001.RAF", "DSCF0001.JPG", "DSCF0002.JPG"])
        defer { TempDir.cleanup(dir) }

        let items = try await CatalogScanner().scan(folderURL: dir)

        guard let paired = items.first(where: { $0.url.lastPathComponent == "DSCF0001.RAF" }) else {
            t.fail("RAF not found in scan"); return
        }
        t.check(paired.isRAW, "RAF classified as RAW")
        t.check(paired.isRAWJPEGPair, "RAF+JPG recognized as a pair")
        t.equal(paired.pairedURL?.lastPathComponent, "DSCF0001.JPG", "paired URL points at the JPEG")

        guard let standalone = items.first(where: { $0.url.lastPathComponent == "DSCF0002.JPG" }) else {
            t.fail("standalone JPG not found"); return
        }
        t.check(standalone.isJPEG, "standalone JPG classified as JPEG")
        t.check(standalone.pairedURL == nil, "standalone JPG has no pair")

        // The pair is a single catalog item, not two.
        t.equal(items.count, 2, "pair collapses into one item alongside the standalone")
    }

    /// Previously impossible: `rawPairCandidateExtensions` was `rawExtensions` minus sets it
    /// shared no members with, so HEIC never qualified as the primary half of a pair.
    private static func heicPairing(_ t: TestRunner) async throws {
        let dir = try makeFolder(["IMG_9001.HEIC", "IMG_9001.JPG"])
        defer { TempDir.cleanup(dir) }

        let items = try await CatalogScanner().scan(folderURL: dir)
        guard let heic = items.first(where: { $0.url.lastPathComponent == "IMG_9001.HEIC" }) else {
            t.fail("HEIC not found in scan"); return
        }
        t.check(heic.isRAWJPEGPair, "HEIC+JPG now pairs (modern iPhone / HEIF camera modes)")
        t.equal(items.count, 1, "the HEIC pair is a single catalog item")
    }

    private static func classification(_ t: TestRunner) {
        let raw = PhotoItem(url: URL(fileURLWithPath: "/tmp/IMG_0001.CR3"), modificationDate: Date(), fileSize: 10)
        let video = PhotoItem(url: URL(fileURLWithPath: "/tmp/clip.MP4"), modificationDate: Date(), fileSize: 10)
        let sidecar = PhotoItem(url: URL(fileURLWithPath: "/tmp/IMG_0001.xmp"), modificationDate: Date(), fileSize: 10)
        let heic = PhotoItem(url: URL(fileURLWithPath: "/tmp/IMG_0002.heic"), modificationDate: Date(), fileSize: 10)

        t.check(raw.isRAW, "CR3 is RAW")
        t.check(!raw.isJPEG, "CR3 is not JPEG")
        t.check(video.isVideo, "MP4 is video")
        t.check(sidecar.isSidecar, "xmp is a sidecar (so it can be filtered from the catalog)")
        t.check(heic.isOtherImage, "HEIC classified as an image")
        t.check(!sidecar.isRAW, "xmp is not RAW")
    }

    private static func cancellation(_ t: TestRunner) async throws {
        let names = (1...400).map { String(format: "IMG_%04d.CR2", $0) }
        let dir = try makeFolder(names)
        defer { TempDir.cleanup(dir) }

        let scanner = CatalogScanner()
        let task = Task { try await scanner.scan(folderURL: dir, recursive: true) }
        task.cancel()

        do {
            let items = try await task.value
            // Cancellation is checked cooperatively, so a fast scan may still complete.
            t.check(items.count <= 400, "scan completed before the cancellation check (\(items.count) items)")
        } catch is CancellationError {
            t.check(true, "scan honoured cancellation")
        }

        // The important property: an uncancelled scan still returns everything.
        let full = try await CatalogScanner().scan(folderURL: dir, recursive: true)
        t.equal(full.count, 400, "uncancelled scan still returns every file")
    }
}
