import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import UI
import Catalog
import Decode
import Sidecar
import Shortcuts

/// Measures `WorkspaceViewModel.openFolder` end to end — the thing a user actually waits on.
///
/// The earlier scan benchmark timed `CatalogScanner.scan` alone, on zero-byte stub files.
/// That is a small fraction of opening a folder: the view model also stats every paired
/// JPEG, records a security-scoped bookmark, filters and sorts, kicks off prefetch, and
/// reads a sidecar per photo. Timing only the scan produced a number that looked great and
/// told the user nothing.
///
/// Run with `swift run -c release pcqa --bench-open`.
@MainActor
enum OpenFolderBenchmark {

    static func run() async throws {
        print("\u{001B}[1mPhoto Culler — openFolder breakdown\u{001B}[0m")
        print("Machine: \(ProcessInfo.processInfo.processorCount) cores\n")

        try await phase("A. 5,000 stub files, no sidecars", pairs: 2_500, sidecars: false, realImages: 0)
        try await phase("B. 5,000 stub files, 2,500 sidecars", pairs: 2_500, sidecars: true, realImages: 0)
        try await phase("C. 400 real 24MP JPEGs", pairs: 0, sidecars: false, realImages: 400)
    }

    private static func phase(_ label: String, pairs: Int, sidecars: Bool, realImages: Int) async throws {
        print("\u{001B}[1m▸ \(label)\u{001B}[0m")

        let dir = try makeCorpus(pairs: pairs, sidecars: sidecars, realImages: realImages)
        defer { TempDir.cleanup(dir) }

        // ── Component timings, measured the way openFolder actually does the work ──
        let scanStart = DispatchTime.now()
        let scanned = try await CatalogScanner().scan(folderURL: dir, recursive: true)
        let scanTime = ms(since: scanStart)

        // The paired-JPEG stat loop runs on the main actor inside openFolder.
        let statStart = DispatchTime.now()
        var statted = 0
        for photo in scanned {
            guard let jpgURL = photo.pairedURL else { continue }
            _ = try? jpgURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            statted += 1
        }
        let statTime = ms(since: statStart)

        // Security-scoped bookmark creation — one call, but it can be surprisingly costly.
        let bookmarkStart = DispatchTime.now()
        _ = try? dir.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let bookmarkTime = ms(since: bookmarkStart)

        // Sidecar sweep — the background pass that fills in ratings.
        let sidecarStart = DispatchTime.now()
        let manager = SidecarManager()
        var found = 0
        for photo in scanned {
            let url = photo.url.deletingPathExtension().appendingPathExtension("xmp")
            if (try? manager.read(from: url)) != nil { found += 1 }
        }
        let sidecarTime = ms(since: sidecarStart)

        // ── The number the user feels: openFolder returning ────────────────────────
        let vm = WorkspaceViewModel(scanner: CatalogScanner(),
                                    folderManager: FolderManager(),
                                    imageProvider: ImageProvider(),
                                    sidecarManager: SidecarManager(),
                                    shortcutManager: ShortcutManager())

        let openStart = DispatchTime.now()
        await vm.openFolder(dir)
        let openTime = ms(since: openStart)

        // And the number they *actually* feel: first thumbnails on screen.
        let firstThumbStart = DispatchTime.now()
        var decoded = 0
        for photo in vm.photos.prefix(30) {
            let ref = PhotoRef(id: photo.id, url: photo.url, pairedURL: photo.pairedURL,
                               prefersEmbeddedPreview: photo.isRAW && photo.pairedURL == nil)
            if await vm.imageProvider.image(for: ref, tier: .thumbnail) != nil { decoded += 1 }
        }
        let firstThumbTime = ms(since: firstThumbStart)

        print(String(format: "  scan .................. %8.1f ms   (%d items)", scanTime, scanned.count))
        print(String(format: "  paired-JPEG stats ..... %8.1f ms   (%d stats, ON MAIN ACTOR)", statTime, statted))
        print(String(format: "  security bookmark ..... %8.1f ms", bookmarkTime))
        print(String(format: "  sidecar sweep ......... %8.1f ms   (%d found, background)", sidecarTime, found))
        print(String(format: "  \u{001B}[1mopenFolder() total .... %8.1f ms\u{001B}[0m   (blocks the UI)", openTime))
        print(String(format: "  first 30 thumbnails ... %8.1f ms   (%.1f ms each)", firstThumbTime,
                     decoded > 0 ? firstThumbTime / Double(decoded) : 0))
        print("")
    }

    // MARK: - Fixtures

    private static func makeCorpus(pairs: Int, sidecars: Bool, realImages: Int) throws -> URL {
        let dir = try TempDir.make("openbench")
        let payload = Data(count: 512)

        // `1...max(pairs, 0)` traps when pairs == 0 — a ClosedRange can't be empty.
        if pairs > 0 {
            for i in 1...pairs {
                let base = String(format: "IMG_%05d", i)
                try payload.write(to: dir.appendingPathComponent("\(base).CR2"))
                try payload.write(to: dir.appendingPathComponent("\(base).JPG"))
                if sidecars {
                    try lightroomXMP(rating: (i % 5) + 1)
                        .write(to: dir.appendingPathComponent("\(base).xmp"), atomically: true, encoding: .utf8)
                }
            }
        }

        if realImages > 0 {
            for i in 0..<realImages {
                try writeRealJPEG(to: dir.appendingPathComponent(String(format: "REAL_%04d.jpg", i)))
            }
        }

        return dir
    }

    private static func lightroomXMP(rating: Int) -> String {
        """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmp:Rating="\(rating)" xmp:Label="Red"/>
          </rdf:RDF>
        </x:xmpmeta>
        """
    }

    private static func writeRealJPEG(to url: URL) throws {
        let width = 6000, height = 4000
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        var rng = SystemRandomNumberGenerator()
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<1_500 {
            ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &rng),
                                     green: .random(in: 0...1, using: &rng),
                                     blue: .random(in: 0...1, using: &rng), alpha: 1))
            ctx.fill(CGRect(x: .random(in: 0..<CGFloat(width), using: &rng),
                            y: .random(in: 0..<CGFloat(height), using: &rng),
                            width: .random(in: 20...200, using: &rng),
                            height: .random(in: 20...200, using: &rng)))
        }
        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
    }

    private static func ms(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }
}
