import Foundation
import Rename
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

enum RenameSuite {

    static func run(_ t: TestRunner) throws {
        t.suite("Rename — locale independence (4.1)")
        try localeIndependence(t)

        t.suite("Rename — filename sanitization (4.2)")
        sanitization(t)

        t.suite("Rename — extension handling")
        extensionHandling(t)

        t.suite("Rename — two-phase swap and chain (4.3)")
        try twoPhase(t)

        t.suite("Rename — RAW+JPEG pairs move together (2.4)")
        try pairAware(t)

        t.suite("Rename — undo (4.4)")
        try undo(t)

        t.suite("Rename — collision detection")
        try collisions(t)

        t.suite("Rename — EXIF tokens populated (3.4)")
        try exifTokens(t)
    }

    // MARK: -

    private static func localeIndependence(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let file = dir.appendingPathComponent("IMG_0001.JPG")
        try Data("x".utf8).write(to: file)

        // Pin a known creation date: 2026-08-17 14:30:00 UTC.
        var components = DateComponents()
        components.year = 2026; components.month = 8; components.day = 17
        components.hour = 14; components.minute = 30; components.second = 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let date = calendar.date(from: components)!
        try FileManager.default.setAttributes([.creationDate: date], ofItemAtPath: file.path)

        let formatter = RenameFormatter()
        let context = RenameContext(originalURL: file, sequence: 7)

        let dated = formatter.format(template: "{date}_{seq:000}", context: context)
        t.equal(dated, "20260817_007.JPG", "Gregorian date regardless of system calendar")

        let year = formatter.format(template: "{year}", context: context)
        t.equal(year, "2026.JPG", "year is Gregorian, not Buddhist/Imperial era")

        // Sanity: a Buddhist-calendar DateFormatter would give 2569 here.
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = calendar.timeZone
        let buddhistYear = buddhist.component(.year, from: date)
        t.check(buddhistYear != 2026, "control: the Buddhist calendar really does differ (\(buddhistYear))")
    }

    private static func sanitization(_ t: TestRunner) {
        t.equal(RenameFormatter.sanitize("EF24-70mm f/2.8"), "EF24-70mm f-2.8", "slash cannot escape the directory")
        t.equal(RenameFormatter.sanitize("a:b"), "a-b", "legacy HFS separator replaced")
        t.equal(RenameFormatter.sanitize(".hidden"), "hidden", "leading dot stripped so files aren't hidden")
        t.equal(RenameFormatter.sanitize("  spaced  "), "spaced", "trimmed")
        t.equal(RenameFormatter.sanitize("a__b"), "a_b", "collapses separators left by empty tokens")

        let long = String(repeating: "é", count: 400)   // 800 UTF-8 bytes
        let clamped = RenameFormatter.clamp(long, reservingBytesFor: "JPG")
        t.check(clamped.utf8.count <= 251, "clamped to the filesystem byte budget (\(clamped.utf8.count))")
    }

    private static func extensionHandling(_ t: TestRunner) {
        let formatter = RenameFormatter()
        let context = RenameContext(originalURL: URL(fileURLWithPath: "/p/IMG_1234.CR2"), sequence: 42)

        // No ext token → the original extension is appended once, in its original case.
        t.equal(formatter.format(template: "Wedding-{seq:000}-{name:lower}", context: context),
                "Wedding-042-img_1234.CR2",
                "auto-appends the source extension exactly once")

        // Template places the extension itself → must NOT be appended again.
        t.equal(formatter.format(template: "New_{seq}_{ext:upper}", context: context),
                "New_0042_CR2",
                "no second extension when the template already includes one")

        t.equal(formatter.format(template: "{name}.{ext}", context: context),
                "IMG_1234.cr2",
                "{ext} token lowercases, and is not doubled")

        t.equal(formatter.format(template: "{name}_{rating}_{color}", context: context),
                "IMG_1234.CR2",
                "empty metadata tokens collapse without leaving stray separators")
    }

    /// The case a single-pass sequential rename structurally cannot do.
    private static func twoPhase(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let a = dir.appendingPathComponent("A.jpg")
        let b = dir.appendingPathComponent("B.jpg")
        try Data("A".utf8).write(to: a)
        try Data("B".utf8).write(to: b)

        let renamer = BatchRenamer()
        // Swap: A→B and B→A.
        try renamer.execute(operations: [
            RenameOperation(originalURL: a, newURL: b),
            RenameOperation(originalURL: b, newURL: a)
        ])

        t.equal(try String(contentsOf: a, encoding: .utf8), "B", "A.jpg now holds B's content")
        t.equal(try String(contentsOf: b, encoding: .utf8), "A", "B.jpg now holds A's content")

        // Chain: 1→2, 2→3.
        let dir2 = try TempDir.make(); defer { TempDir.cleanup(dir2) }
        let one = dir2.appendingPathComponent("1.jpg")
        let two = dir2.appendingPathComponent("2.jpg")
        let three = dir2.appendingPathComponent("3.jpg")
        try Data("one".utf8).write(to: one)
        try Data("two".utf8).write(to: two)

        try BatchRenamer().execute(operations: [
            RenameOperation(originalURL: one, newURL: two),
            RenameOperation(originalURL: two, newURL: three)
        ])

        t.equal(try String(contentsOf: two, encoding: .utf8), "one", "chained rename 1→2 succeeded")
        t.equal(try String(contentsOf: three, encoding: .utf8), "two", "chained rename 2→3 succeeded")
        t.check(!one.exists, "source of the chain is gone")

        // No scratch files survive a successful batch.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir2.path)) ?? []
        t.equal(leftovers.filter { $0.hasPrefix(".pcrename-") }.count, 0, "no temp files left behind")
    }

    private static func pairAware(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let raw = dir.appendingPathComponent("IMG_1234.CR2")
        let jpeg = dir.appendingPathComponent("IMG_1234.JPG")
        let sidecar = dir.appendingPathComponent("IMG_1234.xmp")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)
        try Data("<x/>".utf8).write(to: sidecar)

        let renamer = BatchRenamer()
        let context = RenameContext(originalURL: raw, sequence: 1, pairedURL: jpeg)
        let plan = renamer.preview(items: [context], template: "wedding_{seq:0000}", formatter: RenameFormatter())

        t.equal(plan.collisions.count, 0, "no collisions for a clean pair rename")
        t.equal(plan.operations.first?.newURL.lastPathComponent, "wedding_0001.CR2", "RAW gets the new name")
        t.equal(plan.operations.first?.pairedNewURL?.lastPathComponent, "wedding_0001.JPG",
                "paired JPEG gets the same stem with its own extension")

        try renamer.execute(operations: plan.operations)

        t.check(dir.appendingPathComponent("wedding_0001.CR2").exists, "RAW renamed")
        // This is the bug: the JPEG used to be left behind, silently breaking the pair.
        t.check(dir.appendingPathComponent("wedding_0001.JPG").exists, "paired JPEG renamed too")
        t.check(dir.appendingPathComponent("wedding_0001.xmp").exists, "sidecar followed the RAW")
        t.check(!raw.exists && !jpeg.exists, "no orphaned originals left behind")
    }

    private static func undo(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let raw = dir.appendingPathComponent("DSC01.ARW")
        let jpeg = dir.appendingPathComponent("DSC01.JPG")
        try Data("raw".utf8).write(to: raw)
        try Data("jpeg".utf8).write(to: jpeg)

        let renamer = BatchRenamer()
        t.check(!renamer.canUndo(), "nothing to undo before a rename")

        let context = RenameContext(originalURL: raw, sequence: 1, pairedURL: jpeg)
        let plan = renamer.preview(items: [context], template: "shoot_{seq:00}", formatter: RenameFormatter())
        try renamer.execute(operations: plan.operations)

        t.check(renamer.canUndo(), "undo is available after a rename")
        t.check(dir.appendingPathComponent("shoot_01.ARW").exists, "renamed before undo")

        try renamer.undo()

        t.check(raw.exists, "undo restores the RAW's original name")
        t.check(jpeg.exists, "undo restores the paired JPEG too")
        t.check(!dir.appendingPathComponent("shoot_01.ARW").exists, "renamed file is gone after undo")
        t.check(!renamer.canUndo(), "undo stack is empty again (undo is not its own redo)")
    }

    private static func collisions(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let a = dir.appendingPathComponent("a.jpg")
        let b = dir.appendingPathComponent("b.jpg")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        let renamer = BatchRenamer()
        // No sequence token → both map to the same name.
        let items = [
            RenameContext(originalURL: a, sequence: 1),
            RenameContext(originalURL: b, sequence: 2)
        ]
        let plan = renamer.preview(items: items, template: "same", formatter: RenameFormatter())
        t.check(!plan.collisions.isEmpty, "collision detected when a template has no sequence token")

        let good = renamer.preview(items: items, template: "ok_{seq:000}", formatter: RenameFormatter())
        t.equal(good.collisions.count, 0, "no collision once a sequence token is present")
    }

    private static func exifTokens(_ t: TestRunner) throws {
        let dir = try TempDir.make(); defer { TempDir.cleanup(dir) }
        let url = dir.appendingPathComponent("exif.jpg")
        try writeJPEG(to: url, make: "Canon", model: "Canon EOS R5", iso: 640)

        let values = ImageMetadataReader.read(from: url)
        t.equal(values.cameraModel, "Canon EOS R5", "camera model read from EXIF (no doubled make)")
        t.equal(values.iso, "640", "ISO read from EXIF")

        let context = RenameContext.forImage(at: url, sequence: 3)
        let name = RenameFormatter().format(template: "{camera}_{iso}_{seq:000}", context: context)
        // Previously every one of these tokens expanded to "" and you got "__003.jpg".
        t.equal(name, "Canon EOS R5_640_003.jpg", "documented EXIF tokens actually expand")

        let upperTokens = RenameFormatter().format(template: "{CameraModel}-{ISO}", context: context)
        t.equal(upperTokens, "Canon EOS R5-640.jpg", "Photo Mechanic-style token spellings work too")
    }

    /// Builds a tiny real JPEG carrying EXIF, so the reader is exercised against a true file.
    private static func writeJPEG(to url: URL, make: String, model: String, iso: Int) throws {
        let width = 16, height = 16
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = ctx.makeImage() else {
            throw NSError(domain: "pcqa", code: 1)
        }

        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: make,
                kCGImagePropertyTIFFModel: model
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifISOSpeedRatings: [iso]
            ]
        ]

        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "pcqa", code: 2)
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "pcqa", code: 3) }
    }
}
