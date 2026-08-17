import Foundation
import Combine

public struct PhotoItem: Equatable, Hashable, Sendable {
    public let id: UUID
    public let url: URL
    public let modificationDate: Date
    public let fileSize: Int64
    public let pairedURL: URL?

    public init(id: UUID = UUID(), url: URL, modificationDate: Date, fileSize: Int64, pairedURL: URL? = nil) {
        self.id = id
        self.url = url
        self.modificationDate = modificationDate
        self.fileSize = fileSize
        self.pairedURL = pairedURL
    }

    public var fileExtension: String {
        url.pathExtension.lowercased()
    }

    public var isVideo: Bool {
        videoExtensions.contains(fileExtension)
    }

    public var isRAW: Bool {
        rawExtensions.contains(fileExtension)
    }

    public var isJPEG: Bool {
        jpegExtensions.contains(fileExtension)
    }

    public var isOtherImage: Bool {
        otherImageExtensions.contains(fileExtension)
    }

    public var isSidecar: Bool {
        sidecarExtensions.contains(fileExtension)
    }

    public var isRAWJPEGPair: Bool {
        guard rawPairCandidateExtensions.contains(fileExtension), let pairedURL else { return false }
        return jpegExtensions.contains(pairedURL.pathExtension.lowercased())
    }

    public func withPairing(_ pairedURL: URL?) -> PhotoItem {
        PhotoItem(id: id, url: url, modificationDate: modificationDate, fileSize: fileSize, pairedURL: pairedURL)
    }
}

public let rawExtensions: Set<String> = [
    "3fr", "ari", "arw", "bay", "cap", "cr2", "cr3", "crw", "dcr", "dcs", "dng",
    "drf", "eip", "erf", "fff", "gpr", "iiq", "k25", "kdc", "mdc", "mef", "mos",
    "mrw", "nef", "nrw", "orf", "pef", "ptx", "pxn", "r3d", "raf", "raw", "rw2",
    "rwl", "rwz", "sr2", "srf", "srw", "x3f"
]
public let jpegExtensions: Set<String> = ["jpg", "jpeg"]
public let otherImageExtensions: Set<String> = ["heic", "heif", "png", "tif", "tiff"]
public let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mts", "mxf"]
public let sidecarExtensions: Set<String> = ["aae", "cos", "dop", "pp3", "xmp"]

/// Extensions that can act as the primary half of a RAW+JPEG pair.
///
/// Previously this was `rawExtensions.subtracting(jpegExtensions)...`, which subtracted sets
/// that share no members — a no-op that also meant HEIC+JPG pairs (every modern iPhone,
/// and Canon/Nikon HEIF modes) never paired. HEIC/HEIF are now explicit candidates.
public let rawPairCandidateExtensions: Set<String> = rawExtensions.union(["heic", "heif"])

public final class CatalogScanner: Sendable {

    public init() {}

    /// Scans a directory and returns a list of photos.
    /// Does not decode images, only reads file attributes.
    ///
    /// Streams the directory enumerator rather than calling `.allObjects`, which used to
    /// materialize every URL in the tree into one array before any work began — the exact
    /// opposite of the lazy enumeration this is supposed to be. Also honours cancellation,
    /// so switching folders mid-scan stops the old scan instead of letting it run to
    /// completion and land on top of the new one.
    public func scan(folderURL: URL, recursive: Bool = false) async throws -> [PhotoItem] {
        return try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default

            struct FileInfo {
                let url: URL
                let ext: String
                let date: Date
                let size: Int64
            }

            var groupedFiles: [URL: [FileInfo]] = [:]

            let options: FileManager.DirectoryEnumerationOptions = recursive ?
                [.skipsHiddenFiles] :
                [.skipsHiddenFiles, .skipsSubdirectoryDescendants]

            guard let enumerator = fileManager.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
                options: options
            ) else {
                return []
            }

            var scanned = 0
            // `nextObject()` rather than for-in: `makeIterator` is unavailable from an
            // async context, and this keeps the enumeration genuinely lazy either way.
            while let next = enumerator.nextObject() {
                guard let fileURL = next as? URL else { continue }

                // Check cooperatively rather than every iteration — `isCancelled` is cheap
                // but not free, and a card can hold tens of thousands of files.
                scanned += 1
                if scanned % 256 == 0 {
                    try Task.checkCancellation()
                }

                let ext = fileURL.pathExtension.lowercased()
                guard !ext.isEmpty else { continue }

                guard let resources = try? fileURL.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
                ), resources.isRegularFile == true else { continue }

                let mDate = resources.contentModificationDate ?? Date()
                let size = Int64(resources.fileSize ?? 0)

                let baseURL = fileURL.deletingPathExtension()
                groupedFiles[baseURL, default: []].append(
                    FileInfo(url: fileURL, ext: ext, date: mDate, size: size)
                )
            }

            try Task.checkCancellation()

            var items: [PhotoItem] = []
            items.reserveCapacity(groupedFiles.count)

            for (_, files) in groupedFiles {
                if files.count == 1 {
                    let file = files[0]
                    items.append(PhotoItem(url: file.url, modificationDate: file.date, fileSize: file.size))
                    continue
                }

                if let raw = files.first(where: { rawPairCandidateExtensions.contains($0.ext) }),
                   let jpeg = files.first(where: { jpegExtensions.contains($0.ext) }) {

                    let combinedSize = raw.size + jpeg.size
                    items.append(PhotoItem(url: raw.url, modificationDate: raw.date,
                                           fileSize: combinedSize, pairedURL: jpeg.url))

                    // Anything else sharing the base name stands on its own.
                    for file in files where file.url != raw.url && file.url != jpeg.url {
                        items.append(PhotoItem(url: file.url, modificationDate: file.date, fileSize: file.size))
                    }
                } else {
                    for file in files {
                        items.append(PhotoItem(url: file.url, modificationDate: file.date, fileSize: file.size))
                    }
                }
            }

            return items
        }.value
    }
}

public struct BookmarkFolder: Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let path: String
    public var bookmarkData: Data?

    public init(id: UUID = UUID(), name: String, path: String, bookmarkData: Data? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmarkData = bookmarkData
    }

    /// Resolves the bookmark, reporting staleness so the caller can refresh it.
    /// Falls back to the recorded path when there's no usable bookmark.
    public func resolve() -> (url: URL, isStale: Bool) {
        if let data = bookmarkData {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: data,
                                       options: .withSecurityScope,
                                       relativeTo: nil,
                                       bookmarkDataIsStale: &isStale) {
                return (resolved, isStale)
            }
        }
        return (URL(fileURLWithPath: path), false)
    }

    public var url: URL { resolve().url }
}

@MainActor
public final class FolderManager: ObservableObject {

    private let recentsKey = "PhotoCuller_RecentFolders_v2"
    private let favoritesFileName = "favorites.json"

    /// Published so the sidebar actually redraws. These used to be plain stored properties
    /// on a non-observable class, so opening a folder never updated the Recents list.
    @Published public private(set) var recents: [BookmarkFolder] = []
    @Published public private(set) var favorites: [BookmarkFolder] = []

    public init() {
        loadRecents()
        loadFavorites()
    }

    public func addRecent(url: URL) {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent

        let bookmarkData = try? url.bookmarkData(options: .withSecurityScope,
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)

        recents.removeAll { $0.path == path }
        recents.insert(BookmarkFolder(name: name, path: path, bookmarkData: bookmarkData), at: 0)

        if recents.count > 20 {
            recents = Array(recents.prefix(20))
        }

        saveRecents()
    }

    /// Re-records a bookmark that resolved stale, so it keeps working across reboots.
    public func refreshBookmark(for folder: BookmarkFolder, resolvedURL: URL) {
        guard let index = recents.firstIndex(where: { $0.id == folder.id }) else { return }
        let data = try? resolvedURL.bookmarkData(options: .withSecurityScope,
                                                 includingResourceValuesForKeys: nil,
                                                 relativeTo: nil)
        guard data != nil else { return }
        recents[index].bookmarkData = data
        saveRecents()
    }

    public func addFavorite(folder: BookmarkFolder) {
        if !favorites.contains(where: { $0.path == folder.path }) {
            favorites.append(folder)
            saveFavorites()
        }
    }

    public func removeFavorite(id: UUID) {
        favorites.removeAll { $0.id == id }
        saveFavorites()
    }

    // MARK: - Persistence

    private func loadRecents() {
        if let data = UserDefaults.standard.data(forKey: recentsKey),
           let decoded = try? JSONDecoder().decode([BookmarkFolder].self, from: data) {
            self.recents = decoded
        }
    }

    private func saveRecents() {
        if let encoded = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(encoded, forKey: recentsKey)
        }
    }

    private func favoritesURL() -> URL {
        // No force-unwrap: a search-path lookup can legitimately come back empty.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let appDir = base.appendingPathComponent("PhotoCuller")
        if !FileManager.default.fileExists(atPath: appDir.path) {
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        return appDir.appendingPathComponent(favoritesFileName)
    }

    private func loadFavorites() {
        let url = favoritesURL()
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([BookmarkFolder].self, from: data) {
            self.favorites = decoded
        }
    }

    private func saveFavorites() {
        let url = favoritesURL()
        if let encoded = try? JSONEncoder().encode(favorites) {
            try? encoded.write(to: url, options: .atomic)
        }
    }
}
