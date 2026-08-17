import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Catalog
import Decode
import Rename

/// Measures the two claims the README makes: a 10,000-file catalog stays responsive, and
/// memory stays bounded. Run with `swift run pcqa --bench`.
///
/// These are real measurements on real files, not estimates — but read them carefully:
///
///  - Fixtures live on a fast local SSD and are smaller than a working photographer's RAWs.
///    Treat the numbers as "the code is not accidentally quadratic", not as a promise.
///  - Memory is reported as **phys_footprint** (what Activity Monitor shows), not
///    `resident_size`. Measuring resident_size here reported +1.7 GB for a 24-frame decode
///    sweep where the footprint delta was under 2 MB — resident counts freed-but-unreturned
///    malloc pages, so it wildly overstates. That difference is worth knowing before anyone
///    "optimizes" against the wrong number.
///  - ImageIO-backed CGImages use purgeable backing that only materializes when drawn, so a
///    headless decode loop under-measures what the app costs with those frames on screen.
///    This bounds the *cache*, not the rendered UI.
enum Benchmarks {

    static func run() async throws {
        print("\u{001B}[1mPhoto Culler — benchmarks\u{001B}[0m")
        print("Machine: \(ProcessInfo.processInfo.processorCount) cores, "
              + "\(ByteCountFormatter.string(fromByteCount: Int64(ProcessInfo.processInfo.physicalMemory), countStyle: .memory)) RAM\n")

        try await scanBenchmark()
        try await decodeBenchmark()
        try await renameBenchmark()

        print("\nFinal footprint: \(formatBytes(residentBytes()))")
        print("Peak resident high-water: \(formatBytes(peakResidentBytes()))")
        print("  ^ dominated by generating the 6000x4000 test JPEGs (a 96 MB CGContext each),")
        print("    not by the app's decode path. Ignore it when judging Photo Culler.")
    }

    // MARK: - Scan

    private static func scanBenchmark() async throws {
        print("\u{001B}[1m▸ Catalog scan\u{001B}[0m")

        for count in [1_000, 5_000, 10_000] {
            let dir = try makeFlatCorpus(pairs: count / 2)
            defer { TempDir.cleanup(dir) }

            let before = residentBytes()
            let start = DispatchTime.now()
            let items = try await CatalogScanner().scan(folderURL: dir, recursive: true)
            let elapsed = seconds(since: start)
            let delta = residentBytes() - before

            let perFile = elapsed / Double(count) * 1_000_000
            print(String(format: "  %6d files → %6.3fs  (%5.1f µs/file, %d items, +%@)",
                         count, elapsed, perFile, items.count, formatBytes(delta)))
        }
        print("  (RAW+JPEG pairs collapse 2 files into 1 catalog item, hence items = files/2)")
    }

    // MARK: - Decode

    private static func decodeBenchmark() async throws {
        print("\n\u{001B}[1m▸ Decode pipeline + cache ceiling\u{001B}[0m")

        let dir = try TempDir.make("bench-images")
        defer { TempDir.cleanup(dir) }

        // 24 megapixel-ish JPEGs — representative of a mirrorless body's output.
        let imageCount = 24
        var urls: [URL] = []
        for i in 0..<imageCount {
            let url = dir.appendingPathComponent(String(format: "BENCH_%03d.jpg", i))
            try writeTestJPEG(to: url, width: 6000, height: 4000, seed: i)
            urls.append(url)
        }
        let onDisk = urls.reduce(Int64(0)) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize).map(Int64.init)! }
        print("  corpus: \(imageCount) × 6000×4000 JPEG (\(formatBytes(onDisk)) on disk)")

        let provider = ImageProvider()
        let refs = urls.map { PhotoRef(url: $0) }

        for tier in [ImageTier.thumbnail, .preview, .full] {
            let before = residentBytes()
            let start = DispatchTime.now()
            for ref in refs {
                _ = await provider.image(for: ref, tier: tier)
            }
            let elapsed = seconds(since: start)
            let peak = residentBytes() - before
            // Let transient allocations settle, then measure what the cache actually holds.
            try? await Task.sleep(for: .milliseconds(600))
            let settled = residentBytes() - before
            print(String(format: "  %-9@ %2d decodes → %6.3fs  (%5.1f ms each) footprint peak +%@ / settled +%@",
                         String(describing: tier) as NSString, imageCount, elapsed,
                         elapsed / Double(imageCount) * 1000, formatBytes(peak), formatBytes(settled)))
        }

        // The point of the byte-cost fix: hammering the cache must not grow without bound.
        let beforeFlood = residentBytes()
        for _ in 0..<6 {
            for ref in refs {
                _ = await provider.image(for: ref, tier: .preview)
            }
        }
        let floodDelta = residentBytes() - beforeFlood
        print("  cache flood (144 preview fetches): resident +\(formatBytes(floodDelta))")
        print("  configured ceilings: thumbnail 192 MB · preview 256 MB · full 320 MB")
    }

    // MARK: - Rename

    private static func renameBenchmark() async throws {
        print("\n\u{001B}[1m▸ Rename preview (collision check)\u{001B}[0m")

        for count in [500, 2_000] {
            let dir = try makeFlatCorpus(pairs: count / 2)
            defer { TempDir.cleanup(dir) }

            let items = try await CatalogScanner().scan(folderURL: dir, recursive: true)
            let contexts = items.enumerated().map { index, photo in
                RenameContext(originalURL: photo.url, sequence: index + 1, pairedURL: photo.pairedURL)
            }

            let start = DispatchTime.now()
            let result = BatchRenamer().preview(items: contexts, template: "shoot_{seq:0000}")
            let elapsed = seconds(since: start)

            print(String(format: "  %5d items → %6.3fs  (%d ops, %d collisions)",
                         items.count, elapsed, result.operations.count, result.collisions.count))
        }
        print("  (this used to run synchronously on the main thread on every keystroke)")
    }

    // MARK: - Fixtures

    private static func makeFlatCorpus(pairs: Int) throws -> URL {
        let dir = try TempDir.make("bench-scan")
        let payload = Data(count: 512)
        for i in 1...pairs {
            let base = String(format: "IMG_%05d", i)
            try payload.write(to: dir.appendingPathComponent("\(base).CR2"))
            try payload.write(to: dir.appendingPathComponent("\(base).JPG"))
        }
        return dir
    }

    /// A real, decodable JPEG with actual high-frequency content, so decode timings mean
    /// something (a flat colour image compresses to nothing and decodes unrealistically fast).
    private static func writeTestJPEG(to url: URL, width: Int, height: Int, seed: Int) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw NSError(domain: "bench", code: 1)
        }

        var rng = SystemRandomNumberGenerator()
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<4_000 {
            ctx.setFillColor(CGColor(red: .random(in: 0...1, using: &rng),
                                     green: .random(in: 0...1, using: &rng),
                                     blue: .random(in: 0...1, using: &rng),
                                     alpha: 1))
            ctx.fill(CGRect(x: .random(in: 0..<CGFloat(width), using: &rng),
                            y: .random(in: 0..<CGFloat(height), using: &rng),
                            width: .random(in: 4...90, using: &rng),
                            height: .random(in: 4...90, using: &rng)))
        }

        guard let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "bench", code: 2)
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "bench", code: 3) }
    }

    // MARK: - Instrumentation

    private static func seconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
    }

    /// `phys_footprint` is the number Activity Monitor shows and what the OS uses for
    /// memory-pressure decisions — `resident_size` over-reports because freed pages linger
    /// in the malloc zone rather than being returned to the kernel immediately.
    static func residentBytes() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    static func peakResidentBytes() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size_max) : 0
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
