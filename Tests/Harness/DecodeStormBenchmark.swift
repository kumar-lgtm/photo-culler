import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Decode

/// Reproduces the reported symptom: open a folder of ~450 RAW files and every thumbnail
/// spins forever.
///
/// The UI fires one `ThumbnailView.task` per visible/buffered tile, while prefetch and the
/// loupe request their own tiers. Each awaits `ImageProvider.image(...)`, whose ImageIO call
/// is synchronous. This deliberately exaggerated 449-request case proves the global decode
/// gate stays responsive even when a view regression produces far more work than expected.
///
/// Run: `swift run -c release pcqa --bench-storm`
enum DecodeStormBenchmark {

    static func run() async throws {
        print("\u{001B}[1mPhoto Culler — concurrent decode storm\u{001B}[0m")
        print("Cores: \(ProcessInfo.processInfo.processorCount) (cooperative pool width)\n")

        let dir = try TempDir.make("storm")
        defer { TempDir.cleanup(dir) }

        // One big source, copied — each copy is a distinct cache key, so all decode for real.
        let master = dir.appendingPathComponent("master.jpg")
        try writeBig(to: master, width: 6000, height: 4000)
        let fileCount = 449            // 267 CR3 + 122 RAF + 60 JPG
        var urls: [URL] = []
        for i in 0..<fileCount {
            let u = dir.appendingPathComponent(String(format: "IMG_%04d.jpg", i))
            try FileManager.default.copyItem(at: master, to: u)
            urls.append(u)
        }
        print("corpus: \(fileCount) × 6000×4000 JPEG\n")

        try await storm(urls: urls, label: "all \(fileCount) requested at once")
    }

    private static func storm(urls: [URL], label: String) async throws {
        let provider = ImageProvider()
        let refs = urls.map { PhotoRef(url: $0) }
        let done = Counter()

        print("\u{001B}[1m▸ \(label)\u{001B}[0m")
        let start = DispatchTime.now()

        // Progress watchdog: if the pool starves, completion flatlines.
        let watchdog = Task {
            for tick in 1...12 {
                try? await Task.sleep(for: .seconds(5))
                let n = await done.value
                print(String(format: "   t=%3ds  completed %d / %d", tick * 5, n, refs.count))
                if n >= refs.count { return }
            }
        }

        await withTaskGroup(of: Void.self) { group in
            for ref in refs {
                group.addTask {
                    _ = await provider.image(for: ref, tier: .thumbnail)
                    await done.bump()
                }
            }
            await group.waitForAll()
        }
        watchdog.cancel()

        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9
        print(String(format: "   finished %d decodes in %.1fs (%.0f ms each)\n",
                     refs.count, elapsed, elapsed / Double(refs.count) * 1000))
    }

    actor Counter {
        var value = 0
        func bump() { value += 1 }
    }

    private static func writeBig(to url: URL, width: Int, height: Int) throws {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        var rng = SystemRandomNumberGenerator()
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.35, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<3000 {
            ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng),
                                     blue: .random(in: 0...1, using: &rng), alpha: 1))
            ctx.fill(CGRect(x: .random(in: 0..<CGFloat(width), using: &rng),
                            y: .random(in: 0..<CGFloat(height), using: &rng),
                            width: .random(in: 20...220, using: &rng),
                            height: .random(in: 20...220, using: &rng)))
        }
        guard let img = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        _ = CGImageDestinationFinalize(dest)
    }
}
