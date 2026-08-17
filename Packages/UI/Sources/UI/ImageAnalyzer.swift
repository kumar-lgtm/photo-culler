import Foundation
import Vision
import CoreImage

public struct FaceData: Equatable, Sendable {
    public let boundingBox: CGRect // Normalized coordinates (0-1)
    
    public init(boundingBox: CGRect) {
        self.boundingBox = boundingBox
    }
}

public final class ImageAnalyzer: Sendable {
    public static let shared = ImageAnalyzer()
    
    private init() {}
    
    /// Relative sharpness score (variance of the Laplacian), measured on a **native-resolution
    /// crop** rather than a downsampled copy of the whole frame.
    ///
    /// Downsampling to 320px destroys exactly the high-frequency detail that separates a
    /// tack-sharp frame from a slightly-missed-focus one, so the old score routinely picked
    /// the wrong frame in a burst. Sampling a native-resolution region keeps that detail,
    /// and capping the region keeps the cost bounded regardless of sensor size.
    ///
    /// Pass `region` (normalized, origin bottom-left, as Vision reports faces) to measure a
    /// detected face instead of the centre — that's where focus actually matters.
    ///
    /// The absolute number is arbitrary; it's only meaningful when comparing frames of the
    /// same scene at the same sampling settings.
    public func sharpness(of cgImage: CGImage, region: CGRect? = nil) async -> Double {
        return await Task.detached(priority: .utility) {
            let imageWidth = cgImage.width
            let imageHeight = cgImage.height
            guard imageWidth > 8, imageHeight > 8 else { return 0 }

            // Choose the area to sample: a face if we have one, otherwise the central 50%.
            let normalized = region ?? CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
            // CGImage cropping uses a top-left origin; Vision boxes are bottom-left.
            let cropRect = CGRect(
                x: normalized.minX * CGFloat(imageWidth),
                y: (1.0 - normalized.maxY) * CGFloat(imageHeight),
                width: max(normalized.width * CGFloat(imageWidth), 8),
                height: max(normalized.height * CGFloat(imageHeight), 8)
            ).integral.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

            guard !cropRect.isNull, cropRect.width >= 8, cropRect.height >= 8,
                  let cropped = cgImage.cropping(to: cropRect) else { return 0 }

            // Sample at native scale, capped so a 100MP file costs the same as a 24MP one.
            let sampleCap = 768
            let scale = min(1.0, Double(sampleCap) / Double(max(cropped.width, cropped.height)))
            let w = max(8, Int(Double(cropped.width) * scale))
            let h = max(8, Int(Double(cropped.height) * scale))

            let gray = CGColorSpaceCreateDeviceGray()
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
            ctx.interpolationQuality = .none   // don't smooth away the detail we're measuring
            ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let buf = ctx.data else { return 0 }
            let px = buf.bindMemory(to: UInt8.self, capacity: w * h)

            // 3x3 Laplacian (4-neighbour) over the interior; accumulate mean and variance.
            var sum = 0.0, sumSq = 0.0, n = 0.0
            for y in 1..<(h - 1) {
                for x in 1..<(w - 1) {
                    let i = y * w + x
                    let lap = 4.0 * Double(px[i])
                        - Double(px[i - 1]) - Double(px[i + 1])
                        - Double(px[i - w]) - Double(px[i + w])
                    sum += lap
                    sumSq += lap * lap
                    n += 1
                }
            }
            guard n > 0 else { return 0 }
            let mean = sum / n
            return sumSq / n - mean * mean   // variance
        }.value
    }

    public func detectFaces(in cgImage: CGImage) async -> [FaceData] {
        return await Task.detached(priority: .userInitiated) {
            let request = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

            do {
                try handler.perform([request])
                guard let results = request.results else { return [] }

                // Drop low-confidence detections (false positives), but never end up empty if
                // the only faces found are borderline.
                let confident = results.filter { $0.confidence >= 0.3 }
                let chosen = confident.isEmpty ? results : confident

                // Largest first, so faces[0] is the main subject — that's what "Z" targets by default.
                return chosen
                    .sorted { ($0.boundingBox.width * $0.boundingBox.height) > ($1.boundingBox.width * $1.boundingBox.height) }
                    .map { FaceData(boundingBox: $0.boundingBox) }
            } catch {
                print("Face detection failed: \(error)")
                return []
            }
        }.value
    }
}
