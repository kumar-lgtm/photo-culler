import Foundation
import Decode

/// Times the exact ImageProvider paths against caller-supplied camera files.
///
///     swift run -c release pcqa --bench-raw-file sample.CR3 sample.RAF
///
/// Fixtures intentionally stay outside git; real RAW files are tens of megabytes each.
enum RawFileBenchmark {

    static func run(paths: [String]) async throws {
        guard !paths.isEmpty else {
            throw NSError(domain: "PhotoCuller.RawFileBenchmark", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "provide at least one RAW path"])
        }

        print("\u{001B}[1mPhoto Culler — real RAW decode paths\u{001B}[0m")
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            print("\n\u{001B}[1m▸ \(url.lastPathComponent)\u{001B}[0m  (\(formatBytes(size)))")

            let embeddedProvider = ImageProvider()
            let embeddedRef = PhotoRef(url: url, prefersEmbeddedPreview: true)
            try await measure("embedded-first thumbnail", provider: embeddedProvider,
                              ref: embeddedRef, tier: .thumbnail)
            try await measure("embedded-first preview", provider: embeddedProvider,
                              ref: embeddedRef, tier: .preview)

            let forcedProvider = ImageProvider()
            let forcedRef = PhotoRef(url: url)
            try await measure("legacy forced thumbnail", provider: forcedProvider,
                              ref: forcedRef, tier: .thumbnail)
            try await measure("legacy forced preview", provider: forcedProvider,
                              ref: forcedRef, tier: .preview)
        }
    }

    private static func measure(_ label: String, provider: ImageProvider, ref: PhotoRef,
                                tier: ImageTier) async throws {
        let started = DispatchTime.now()
        let image = await provider.image(for: ref, tier: tier)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        let dimensions = image.map { "\($0.width)×\($0.height)" } ?? "unavailable"
        print(String(format: "  %-27@ %8.1f ms   %@", label as NSString, ms, dimensions))
    }

    private static func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
