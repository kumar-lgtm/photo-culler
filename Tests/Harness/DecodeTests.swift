import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Decode

/// Behavioral coverage for the RAW fast path.
///
/// The fixture is a JPEG because ImageIO can deterministically write one with an embedded
/// thumbnail. Marking the `PhotoRef` as RAW-preferred then lets the test prove whether the
/// provider preserved that embedded bitmap or forced a raster of the full source. This
/// catches the exact option regression without checking private implementation details or
/// committing a large proprietary RAW fixture to the repository.
enum DecodeSuite {

    static func run(_ t: TestRunner) async throws {
        t.suite("Decode — RAW browsing uses embedded camera previews")
        try await embeddedPreviewFastPath(t)
    }

    private static func embeddedPreviewFastPath(_ t: TestRunner) async throws {
        let dir = try TempDir.make("decode-embedded")
        defer { TempDir.cleanup(dir) }
        let url = dir.appendingPathComponent("embedded-preview.jpg")
        try writeJPEGWithEmbeddedThumbnail(to: url)

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            t.fail("fixture opens with ImageIO")
            return
        }

        let embeddedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true
        ]
        let forcedOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let embedded = CGImageSourceCreateThumbnailAtIndex(
            source, 0, embeddedOptions as CFDictionary
        ), let forced = CGImageSourceCreateThumbnailAtIndex(
            source, 0, forcedOptions as CFDictionary
        ) else {
            t.fail("fixture exposes both embedded and forced thumbnail paths")
            return
        }

        t.check(embedded.width != forced.width || embedded.height != forced.height,
                "fixture distinguishes embedded extraction from full rasterization")

        let rawProvider = ImageProvider()
        let rawRef = PhotoRef(url: url, prefersEmbeddedPreview: true)
        let rawThumb = await rawProvider.image(for: rawRef, tier: .thumbnail)
        t.equal(rawThumb?.width, embedded.width,
                "RAW thumbnail preserves the embedded camera preview width")
        t.equal(rawThumb?.height, embedded.height,
                "RAW thumbnail preserves the embedded camera preview height")

        // A tiny EXIF thumbnail is enough for the filmstrip, but not the loupe. The preview
        // tier must fall back to the source rather than stretching a 160px bitmap forever.
        let rawPreview = await rawProvider.image(for: rawRef, tier: .preview)
        t.check(max(rawPreview?.width ?? 0, rawPreview?.height ?? 0) >= 1200,
                "tiny embedded thumbnail falls back to a usable loupe preview")

        let jpegProvider = ImageProvider()
        let ordinaryJPEG = await jpegProvider.image(for: PhotoRef(url: url), tier: .thumbnail)
        t.equal(ordinaryJPEG?.width, forced.width,
                "ordinary JPEG thumbnails retain the 512px quality path")
    }

    private static func writeJPEGWithEmbeddedThumbnail(to url: URL) throws {
        let width = 1600
        let height = 1200
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
              )
        else {
            throw NSError(domain: "PhotoCuller.DecodeFixture", code: 1)
        }

        context.setFillColor(CGColor(red: 0.12, green: 0.35, blue: 0.72, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Recreate after drawing; the first image above only validates context allocation.
        guard let rendered = context.makeImage() else {
            throw NSError(domain: "PhotoCuller.DecodeFixture", code: 2)
        }
        CGImageDestinationAddImage(
            destination, rendered,
            [kCGImageDestinationEmbedThumbnail: true] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(domain: "PhotoCuller.DecodeFixture", code: 3)
        }
    }
}
