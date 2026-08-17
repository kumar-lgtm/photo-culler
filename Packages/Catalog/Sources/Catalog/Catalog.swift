import Foundation

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
public let otherImageExtensions: Set<String> = ["heic", "png"]
public let videoExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mts", "mxf"]
public let sidecarExtensions: Set<String> = ["aae", "cos", "dop", "pp3", "xmp"]
public let rawPairCandidateExtensions = rawExtensions.subtracting(jpegExtensions).subtracting(videoExtensions).subtracting(sidecarExtensions)

public final class CatalogScanner: Sendable {
    
    public init() {}
    
    /// Scans a directory and returns a list of photos.
    /// Does not decode images, only reads file attributes.
    public func scan(folderURL: URL, recursive: Bool = false) async throws -> [PhotoItem] {
        return await Task.detached(priority: .userInitiated) {
            print("Started scanning folder: \(folderURL.path), recursive: \(recursive)")
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
            
            guard let enumerator = fileManager.enumerator(at: folderURL, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: options) else {
                return []
            }
            
            let allObjects = enumerator.allObjects as? [URL] ?? []
            for fileURL in allObjects {
                let ext = fileURL.pathExtension.lowercased()
                guard !ext.isEmpty else { continue }

                do {
                    let resources = try fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey])
                    guard resources.isRegularFile == true else { continue }

                    let mDate = resources.contentModificationDate ?? Date()
                    let size = Int64(resources.fileSize ?? 0)

                    let baseURL = fileURL.deletingPathExtension()
                    let info = FileInfo(url: fileURL, ext: ext, date: mDate, size: size)
                    groupedFiles[baseURL, default: []].append(info)
                } catch {
                    // Skip unreadable files
                    continue
                }
            }
            
            var items: [PhotoItem] = []
            for (_, files) in groupedFiles {
                if files.count == 1 {
                    let file = files[0]
                    items.append(PhotoItem(url: file.url, modificationDate: file.date, fileSize: file.size))
                } else {
                    if let raw = files.first(where: { rawPairCandidateExtensions.contains($0.ext) }),
                       let jpeg = files.first(where: { jpegExtensions.contains($0.ext) }) {
                        
                        let combinedSize = files.filter { $0.url == raw.url || $0.url == jpeg.url }.reduce(0) { $0 + $1.size }
                        items.append(PhotoItem(url: raw.url, modificationDate: raw.date, fileSize: combinedSize, pairedURL: jpeg.url))
                        
                        // Add any other files that share the same base name but aren't the pair
                        for file in files {
                            if file.url != raw.url && file.url != jpeg.url {
                                items.append(PhotoItem(url: file.url, modificationDate: file.date, fileSize: file.size))
                            }
                        }
                    } else {
                        // No valid RAW+JPEG pair found, add all independently
                        for file in files {
                            items.append(PhotoItem(url: file.url, modificationDate: file.date, fileSize: file.size))
                        }
                    }
                }
            }
            
            print("Found \(items.count) matching photos")
            return items
        }.value
    }
}

public struct BookmarkFolder: Codable, Equatable, Hashable {
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

    public var url: URL {
        if let data = bookmarkData {
            var isStale = false
            if let resolved = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                return resolved
            }
        }
        return URL(fileURLWithPath: path)
    }
}

public class FolderManager {

    private let recentsKey = "PhotoCuller_RecentFolders_v2"
    private let favoritesFileName = "favorites.json"

    public private(set) var recents: [BookmarkFolder] = []
    public private(set) var favorites: [BookmarkFolder] = []

    public init() {
        loadRecents()
        loadFavorites()
    }

    public func addRecent(url: URL) {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent

        let bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)

        recents.removeAll { $0.path == path }
        recents.insert(BookmarkFolder(name: name, path: path, bookmarkData: bookmarkData), at: 0)

        if recents.count > 20 {
            recents = Array(recents.prefix(20))
        }

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
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("PhotoCuller")
        if !FileManager.default.fileExists(atPath: appDir.path) {
            try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true, attributes: nil)
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
