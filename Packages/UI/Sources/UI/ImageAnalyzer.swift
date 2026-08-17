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
    
    /// Relative sharpness score (variance of the Laplacian) computed on a downsampled grayscale
    /// copy. Higher = more in-focus / more detail. The absolute number is arbitrary, so it's only
    /// meaningful when comparing frames of the same scene (e.g. a burst in compare mode).
    public func sharpness(of cgImage: CGImage) async -> Double {
        return await Task.detached(priority: .utility) {
            // Downsample to a small grayscale buffer — fast and resolution-independent.
            let maxDim = 320
            let scale = min(1.0, Double(maxDim) / Double(max(cgImage.width, cgImage.height)))
            let w = max(8, Int(Double(cgImage.width) * scale))
            let h = max(8, Int(Double(cgImage.height) * scale))

            let gray = CGColorSpaceCreateDeviceGray()
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: gray,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
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
