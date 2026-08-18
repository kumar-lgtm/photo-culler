import Foundation
import Decode

/// Times a whole folder of real camera files through the real `ImageProvider.prefetch`
/// path — the thing a user waits on when a folder opens.
///
///     swift run -c release pcqa --bench-raw-dir /path/to/folder
enum RawFolderBenchmark {

    static func run(path: String) async throws {
        let dir = URL(fileURLWithPath: path)
        let all = (try FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.fileSizeKey])).sorted { $0.path < $1.path }
        let raws = all.filter { rawExtensions.contains($0.pathExtension.lowercased()) }
        guard !raws.isEmpty else { print("no camera files in \(path)"); return }

        let bytes = raws.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        print("\u{001B}[1mPhoto Culler — real folder prefetch\u{001B}[0m")
        print("cores: \(ProcessInfo.processInfo.processorCount)")
        print("\(raws.count) camera files, \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))\n")

        for tier in [ImageTier.thumbnail, .preview] {
            let provider = ImageProvider()
            let refs = raws.map { PhotoRef(url: $0, prefersEmbeddedPreview: true) }

            // Warm the one-time RAW decoder init so it isn't charged to this measurement.
            _ = await provider.image(for: PhotoRef(url: raws[0]), tier: .thumbnail)

            let t0 = DispatchTime.now()
            await provider.prefetch(photos: refs, tier: tier)
            // prefetch returns immediately; wait for every image to be resident.
            for ref in refs { _ = await provider.image(for: ref, tier: tier) }
            let s = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e9

            print(String(format: "  %-10@ %5.2fs for %d files  (%.0f ms each)  → projected %5.1fs for 449",
                         String(describing: tier) as NSString, s, refs.count,
                         s / Double(refs.count) * 1000, s / Double(refs.count) * 449))
        }
    }

    private static let rawExtensions: Set<String> = ["cr2", "cr3", "raf", "nef", "arw", "dng", "orf", "rw2"]
}
