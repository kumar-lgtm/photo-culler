import XCTest
import Foundation
import CoreGraphics
@testable import Decode

final class DecodeTests: XCTestCase {
    func testDecodePrefetchAndCancel() async throws {
        let provider = ImageProvider()
        
        // Create a dummy image file URL
        let tempDir = FileManager.default.temporaryDirectory
        let dummyImageURL = tempDir.appendingPathComponent(UUID().uuidString + ".jpg")
        
        // Create a simple 1x1 image and write it
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cgImage = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(dummyImageURL as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        
        defer {
            try? FileManager.default.removeItem(at: dummyImageURL)
        }
        
        let photo = PhotoRef(id: UUID(), url: dummyImageURL)
        
        // Test prefetching
        await provider.prefetch(photos: [photo], tier: .thumbnail)
        
        // Since it's prefetching, wait a tiny bit
        try await Task.sleep(nanoseconds: 100_000_000)
        
        // Image should now be cached
        let image = await provider.image(for: photo, tier: .thumbnail)
        XCTAssertNotNil(image)
        
        // Test cancellation doesn't crash
        await provider.cancelPrefetch(for: [photo])
    }

    /// Regression: the `.full` tier must apply EXIF orientation just like `.preview`/`.thumbnail`.
    /// Previously `.full` used `CGImageSourceCreateImageAtIndex`, which ignores orientation, so a
    /// portrait photo (stored landscape + rotate flag) appeared sideways the moment full quality
    /// loaded (e.g. on face-zoom / "Z").
    func testFullTierAppliesEXIFOrientation() async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent(UUID().uuidString + ".jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        // Stored buffer is landscape 40x20, with EXIF orientation 6 (rotate 90° CW).
        // After applying the transform it should present as portrait 20x40.
        let storedWidth = 40, storedHeight = 20
        let ctx = CGContext(data: nil, width: storedWidth, height: storedHeight, bitsPerComponent: 8,
                            bytesPerRow: storedWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cgImage = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        let props: [CFString: Any] = [kCGImagePropertyOrientation: 6]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let provider = ImageProvider()
        let photo = PhotoRef(id: UUID(), url: url)

        let preview = await provider.image(for: photo, tier: .preview)
        let full = await provider.image(for: photo, tier: .full)

        XCTAssertNotNil(preview)
        XCTAssertNotNil(full)

        // Preview applies the transform → presents portrait.
        XCTAssertEqual(preview?.width, storedHeight)   // 20
        XCTAssertEqual(preview?.height, storedWidth)    // 40

        // Full must match the same orientation, not the raw landscape buffer.
        XCTAssertEqual(full?.width, preview?.width)
        XCTAssertEqual(full?.height, preview?.height)
    }
}