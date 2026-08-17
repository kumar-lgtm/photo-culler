import Foundation
import CoreGraphics
import ImageIO
import AVFoundation

public enum ImageTier: Sendable {
    case thumbnail  // 256px
    case preview    // 2048px
    case full       // Native
}

public struct PhotoRef: Equatable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let pairedURL: URL?
    
    public init(id: UUID = UUID(), url: URL, pairedURL: URL? = nil) {
        self.id = id
        self.url = url
        self.pairedURL = pairedURL
    }
}

public actor ImageProvider {
    
    private let thumbnailCache = NSCache<NSURL, CGImage>()
    private let previewCache = NSCache<NSURL, CGImage>()
    private let fullCache = NSCache<NSURL, CGImage>()

    private struct TaskKey: Hashable {
        let url: URL
        let tier: ImageTier
    }
    
    private var decodeTasks: [TaskKey: Task<CGImage?, Never>] = [:]

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
        
        let key = TaskKey(url: photo.url, tier: tier)
        if let existingTask = decodeTasks[key] {
            return await existingTask.value
        }
        
        let task = Task {
            let targetURL = photo.pairedURL ?? photo.url
            let image = await decode(url: targetURL, tier: tier)
            if let image {
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
        for photo in photos {
            let nsURL = photo.url as NSURL
            
            // Check if already cached
            if tier == .thumbnail, thumbnailCache.object(forKey: nsURL) != nil { continue }
            if tier == .preview, previewCache.object(forKey: nsURL) != nil { continue }
            
            let key = TaskKey(url: photo.url, tier: tier)
            if decodeTasks[key] == nil {
                let task = Task {
                    let targetURL = photo.pairedURL ?? photo.url
                    let image = await decode(url: targetURL, tier: tier)
                    if let image, !Task.isCancelled {
                        self.store(image, forKey: nsURL, tier: tier)
                    }
                    self.decodeTasks[key] = nil
                    return image
                }
                decodeTasks[key] = task
            }
        }
    }
    
    public func cancelPrefetch(for photos: [PhotoRef]) {
        for photo in photos {
            for tier in [ImageTier.thumbnail, .preview, .full] {
                let key = TaskKey(url: photo.url, tier: tier)
                if let task = decodeTasks[key] {
                    task.cancel()
                    decodeTasks[key] = nil
                }
            }
        }
    }
    
    private nonisolated func decode(url: URL, tier: ImageTier) async -> CGImage? {
        if isVideo(url: url) {
            return await decodeVideo(url: url, tier: tier)
        }
        // Offload decode to a detached task to avoid blocking the actor
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            
            switch tier {
            case .thumbnail:
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 512,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            case .preview:
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 3200,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }
        }.value
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
