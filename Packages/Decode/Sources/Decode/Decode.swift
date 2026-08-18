import Foundation
import CoreGraphics
import ImageIO
import AVFoundation

/// Bounds blocking ImageIO work independently of how many SwiftUI cells become visible.
/// ImageIO decoding is synchronous; launching one detached task per cell can otherwise
/// occupy the cooperative thread pool and hundreds of megabytes of RAW working memory.
private actor DecodeGate {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waiterHead = 0

    init(maxConcurrent: Int) {
        self.permits = max(1, maxConcurrent)
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiterHead < waiters.count {
            let continuation = waiters[waiterHead]
            waiterHead += 1
            // Periodically compact without paying Array.removeFirst() for every decode.
            if waiterHead >= 64, waiterHead * 2 >= waiters.count {
                waiters.removeFirst(waiterHead)
                waiterHead = 0
            }
            continuation.resume()
        } else {
            waiters.removeAll(keepingCapacity: true)
            waiterHead = 0
            permits += 1
        }
    }
}

public enum ImageTier: Hashable, Sendable {
    case thumbnail  // 512px
    case preview    // 3200px
    case full       // Native
}

public struct PhotoRef: Equatable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let pairedURL: URL?
    /// RAW files normally contain a camera-generated JPEG that is dramatically cheaper to
    /// extract than rasterizing the sensor data. Catalog/UI code opts into that path only
    /// for an unpaired RAW; a paired JPEG remains the preferred source when one exists.
    public let prefersEmbeddedPreview: Bool
    
    public init(id: UUID = UUID(), url: URL, pairedURL: URL? = nil,
                prefersEmbeddedPreview: Bool = false) {
        self.id = id
        self.url = url
        self.pairedURL = pairedURL
        self.prefersEmbeddedPreview = prefersEmbeddedPreview
    }
}

public actor ImageProvider {

    /// Three lanes leave room for a loupe preview plus visible filmstrip thumbnails while
    /// preventing a SwiftUI task storm from asking ImageIO to rasterize every RAW at once.
    /// Sized from the machine rather than a fixed 3.
    ///
    /// Measured on real 5760x3840 Canon CR2 files (18-core M-series), projected to a
    /// 449-file folder:
    ///
    ///     thumbnails 512px   1-wide 13.2s | 3-wide 4.1s | 8-wide 3.2s | 16-wide 3.2s
    ///     previews   3200px  1-wide 60.0s | 3-wide 21.9s | 8-wide 10.6s | 16-wide 7.1s
    ///
    /// Most of the win lands by 8, so this leaves headroom rather than claiming every core.
    private static let decodeGate = DecodeGate(
        maxConcurrent: max(4, min(ProcessInfo.processInfo.processorCount - 2, 12))
    )
    
    private let thumbnailCache = NSCache<NSURL, CGImage>()
    private let previewCache = NSCache<NSURL, CGImage>()
    private let fullCache = NSCache<NSURL, CGImage>()

    private struct TaskKey: Hashable {
        let url: URL
        let tier: ImageTier
        let prefersEmbeddedPreview: Bool
    }
    
    private var decodeTasks: [TaskKey: Task<CGImage?, Never>] = [:]
    /// One deliberately serial prefetch lane per tier. The old implementation launched up
    /// to 46 user-initiated ImageIO decodes at once whenever a folder opened. With large RAW
    /// files that saturated CPU and memory before the on-screen photo could finish.
    private var prefetchTasks: [ImageTier: Task<Void, Never>] = [:]

    public init() {
        // `countLimit` bounds the number of entries, not their size — so the old limits
        // couldn't hold the documented memory ceiling. A 512px RGBA thumbnail is ~1 MB, so
        // 1000 of them was ~1 GB, not the "~150 MB" the comment claimed. These are byte
        // budgets via `totalCostLimit`, with the cost supplied per image on insert.
        thumbnailCache.totalCostLimit = 192 * 1_048_576   // 192 MB
        thumbnailCache.countLimit = 1500

        previewCache.totalCostLimit = 256 * 1_048_576     // 256 MB
        previewCache.countLimit = 16

        fullCache.totalCostLimit = 320 * 1_048_576        // 320 MB
        fullCache.countLimit = 3
    }

    /// Approximate resident size of a decoded bitmap, used as the NSCache cost.
    private nonisolated func cost(of image: CGImage) -> Int {
        let bytesPerRow = image.bytesPerRow > 0 ? image.bytesPerRow : image.width * 4
        return max(1, bytesPerRow * image.height)
    }

    private func store(_ image: CGImage, forKey key: NSURL, tier: ImageTier) {
        switch tier {
        case .thumbnail: thumbnailCache.setObject(image, forKey: key, cost: cost(of: image))
        case .preview:   previewCache.setObject(image, forKey: key, cost: cost(of: image))
        case .full:      fullCache.setObject(image, forKey: key, cost: cost(of: image))
        }
    }
    
    public func image(for photo: PhotoRef, tier: ImageTier) async -> CGImage? {
        let nsURL = photo.url as NSURL
        
        switch tier {
        case .thumbnail:
            if let cached = thumbnailCache.object(forKey: nsURL) { return cached }
        case .preview:
            if let cached = previewCache.object(forKey: nsURL) { return cached }
        case .full:
            if let cached = fullCache.object(forKey: nsURL) { return cached }
        }
        
        let key = TaskKey(url: photo.url, tier: tier,
                          prefersEmbeddedPreview: photo.prefersEmbeddedPreview)
        if let existingTask = decodeTasks[key] {
            return await existingTask.value
        }
        
        let task = Task {
            let targetURL = photo.pairedURL ?? photo.url
            let image = await decode(url: targetURL, tier: tier,
                                     prefersEmbeddedPreview: photo.prefersEmbeddedPreview)
            if let image, !Task.isCancelled {
                self.store(image, forKey: nsURL, tier: tier)
            }
            // Remove task once done
            self.decodeTasks[key] = nil
            return image
        }
        
        decodeTasks[key] = task
        return await task.value
    }
    
    public func prefetch(photos: [PhotoRef], tier: ImageTier) {
        prefetchTasks[tier]?.cancel()

        // `photos` arrives in nearest-first order. Fan out rather than decoding one file at
        // a time: `decodeGate` already bounds how much blocking ImageIO work is in flight,
        // so a strictly serial lane only adds latency.
        //
        // Prefetch stays at `.utility`, so a visible cell or the loupe still wins the gate
        // ahead of speculative work.
        let task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for photo in photos {
                    guard !Task.isCancelled else { break }
                    group.addTask(priority: .utility) { [weak self] in
                        guard let self, !Task.isCancelled else { return }
                        _ = await self.image(for: photo, tier: tier)
                    }
                }
                await group.waitForAll()
            }
        }
        prefetchTasks[tier] = task
    }

    /// Stops speculative work from the previous folder before a new folder starts loading.
    /// Active synchronous ImageIO calls may finish, but cancellation prevents them from
    /// populating caches and, with serial prefetch lanes, there are at most two of them.
    public func cancelOutstandingWork() {
        for task in prefetchTasks.values { task.cancel() }
        prefetchTasks.removeAll()
        for task in decodeTasks.values { task.cancel() }
    }
    
    public func cancelPrefetch(for photos: [PhotoRef]) {
        for photo in photos {
            for tier in [ImageTier.thumbnail, .preview, .full] {
                let key = TaskKey(url: photo.url, tier: tier,
                                  prefersEmbeddedPreview: photo.prefersEmbeddedPreview)
                if let task = decodeTasks[key] {
                    task.cancel()
                    decodeTasks[key] = nil
                }
            }
        }
    }
    
    private nonisolated func decode(url: URL, tier: ImageTier,
                                    prefersEmbeddedPreview: Bool) async -> CGImage? {
        if isVideo(url: url) {
            return await decodeVideo(url: url, tier: tier)
        }

        let queueStart = DispatchTime.now()
        await ImageProvider.decodeGate.acquire()
        let queueMS = Diag.elapsedMS(since: queueStart)
        guard !Task.isCancelled else {
            await ImageProvider.decodeGate.release()
            return nil
        }

        // Preserve the request's priority. Speculative prefetch enters at `.utility`;
        // interactive cells and the loupe stay user-initiated.
        let priority = Task.currentPriority
        // Offload decode to a detached task to avoid blocking the actor
        let result: CGImage? = await Task.detached(priority: priority) { () -> CGImage? in
            let diagStart = DispatchTime.now()
            var decodedPixels = 0
            var decodePath = "full-raster"
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            defer {
                if Diag.isEnabled {
                    let ms = Diag.elapsedMS(since: diagStart)
                    let tierName = String(describing: tier)
                    let pixelCount = decodedPixels
                    Task { await Diag.DecodeStats.shared.record(tier: tierName, ms: ms,
                                                                pixels: pixelCount) }
                    // Anything this slow per image is what the user is feeling.
                    if ms > 250 {
                        Diag.log(String(format: "slow decode [%@/%@] %.0f ms — %@",
                                        tierName, decodePath, ms, url.lastPathComponent))
                    }
                }
            }

            let decoded: CGImage?
            switch tier {
            case .thumbnail:
                // `...FromImageAlways` explicitly discards an embedded thumbnail and
                // rasterizes the full source. On hundreds of CR3/RAF files that made every
                // filmstrip cell perform a full RAW conversion just to draw ~100 points.
                // Ask ImageIO for the camera preview first; if one is absent, ImageIO still
                // creates the requested 512px image from the full source as a fallback.
                let useEmbedded = prefersEmbeddedPreview
                decodePath = useEmbedded ? "embedded-first" : "full-raster"
                let options = ImageProvider.thumbnailOptions(maxPixelSize: 512,
                                                             preferEmbedded: useEmbedded)
                let image = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                                 options as CFDictionary)
                decoded = image.flatMap { ImageProvider.downscaled($0, maxPixelSize: 512) }
            case .preview:
                if prefersEmbeddedPreview {
                    let embeddedOptions = ImageProvider.thumbnailOptions(maxPixelSize: 3200,
                                                                         preferEmbedded: true)
                    let embedded = CGImageSourceCreateThumbnailAtIndex(
                        source, 0, embeddedOptions as CFDictionary
                    )

                    // Modern RAWs generally carry a large camera JPEG. Keep it when it is
                    // useful for a loupe; tiny EXIF thumbnails still fall back to a 3200px
                    // raster so the main viewer is not left showing a soft 160px image.
                    if let embedded, max(embedded.width, embedded.height) >= 1200 {
                        decodePath = "embedded-preview"
                        decoded = ImageProvider.downscaled(embedded, maxPixelSize: 3200)
                    } else {
                        decodePath = "small-preview-fallback"
                        let options = ImageProvider.thumbnailOptions(maxPixelSize: 3200,
                                                                     preferEmbedded: false)
                        decoded = CGImageSourceCreateThumbnailAtIndex(
                            source, 0, options as CFDictionary
                        )
                    }
                } else {
                    let options = ImageProvider.thumbnailOptions(maxPixelSize: 3200,
                                                                 preferEmbedded: false)
                    decoded = CGImageSourceCreateThumbnailAtIndex(
                        source, 0, options as CFDictionary
                    )
                }
            case .full:
                // CGImageSourceCreateImageAtIndex ignores EXIF orientation (the transform key is
                // a no-op there), so portrait photos came back sideways the moment full quality
                // swapped in. Request a full-resolution thumbnail instead — same API as the
                // thumbnail/preview tiers — so the orientation transform is actually applied.
                let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                let pixelWidth = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
                let pixelHeight = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
                var options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                let maxDimension = max(pixelWidth, pixelHeight)
                if maxDimension > 0 {
                    // Cap at native size so we get full resolution without upscaling.
                    options[kCGImageSourceThumbnailMaxPixelSize] = maxDimension
                }
                decoded = CGImageSourceCreateThumbnailAtIndex(source, 0,
                                                               options as CFDictionary)
            }

            if let decoded {
                decodedPixels = decoded.width * decoded.height
            }
            return decoded
        }.value
        await ImageProvider.decodeGate.release()

        if Diag.isEnabled, queueMS > 250 {
            Diag.log(String(format: "decode queue [%@] waited %.0f ms — %@",
                            String(describing: tier), queueMS, url.lastPathComponent))
        }
        return result
    }

    /// ImageIO's two similarly named thumbnail flags have opposite performance semantics:
    /// `IfAbsent` preserves an embedded camera preview, while `Always` forces full decoding.
    private nonisolated static func thumbnailOptions(maxPixelSize: Int,
                                                     preferEmbedded: Bool) -> [CFString: Any] {
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if preferEmbedded {
            options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
        } else {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        }
        return options
    }

    /// ImageIO does not guarantee `ThumbnailMaxPixelSize` will resize a thumbnail that was
    /// already embedded. Bound that bitmap before it enters NSCache without touching the RAW.
    private nonisolated static func downscaled(_ image: CGImage,
                                               maxPixelSize: Int) -> CGImage? {
        let largest = max(image.width, image.height)
        guard largest > maxPixelSize else { return image }

        let scale = CGFloat(maxPixelSize) / CGFloat(largest)
        let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let colorSpace = image.colorSpace?.model == .rgb
            ? (image.colorSpace ?? CGColorSpaceCreateDeviceRGB())
            : CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    private nonisolated func isVideo(url: URL) -> Bool {
        ["mov", "mp4", "m4v", "avi", "mts", "mxf"].contains(url.pathExtension.lowercased())
    }

    private nonisolated func decodeVideo(url: URL, tier: ImageTier) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        let cap: CGFloat
        switch tier {
        case .thumbnail: cap = 256
        case .preview:   cap = 3200
        case .full:      cap = 0
        }
        if cap > 0 {
            generator.maximumSize = CGSize(width: cap, height: cap)
        }

        do {
            let (image, _) = try await generator.image(at: .zero)
            return image
        } catch {
            return nil
        }
    }
}
