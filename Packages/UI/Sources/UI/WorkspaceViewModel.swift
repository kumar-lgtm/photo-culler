import Foundation
import Catalog
import Decode
import Sidecar
import Rename
import Shortcuts
import Combine
import SwiftUI

public enum ViewMode: Equatable {
    case loupe
    case grid
    case compare
}

public struct FilterSettings: Equatable {
    public var minRating: Int = 0
    public var colors: Set<ColorLabel> = []
    public var enabledFileExtensions: Set<String> = []
    public var keepRAWAndJPEGPairsTogether: Bool = true
    public var hideRejects: Bool = false
}

public enum SortOption: String, CaseIterable, Identifiable {
    case name = "Name"
    case date = "Newest"
    case size = "Largest"
    public var id: String { rawValue }
}

@MainActor
public class WorkspaceViewModel: ObservableObject {
    @Published public var currentFolder: URL?
    @Published public var photos: [PhotoItem] = []
    @Published public var selection: Set<UUID> = []
    @Published public var currentPhotoIndex: Int?
    @Published public var viewMode: ViewMode = .loupe
    @Published public var activeHUD: HUDMessage?
    @Published public var gridScale: CGFloat = 160
    @Published public var gridColumnsCount: Int = 1
    @Published public var currentMetadata: PhotoMetadata = PhotoMetadata()
    
    @Published public var filterSettings = FilterSettings() {
        didSet { applyFilters() }
    }
    @Published public var sortOption: SortOption = .name {
        didSet { applyFilters() }
    }
    @Published public var autoAdvance: Bool = true
    @AppStorage("isBeigeMode") public var isBeigeMode: Bool = false
    public var isCollectingSelection: Bool = false
    @Published public var metadataCache: [UUID: PhotoMetadata] = [:]
    @Published public var faceDataCache: [UUID: [FaceData]] = [:]
    @Published public var sharpnessCache: [UUID: Double] = [:]
    @Published public var availableFileExtensions: [String] = []
    public var allPhotos: [PhotoItem] = []
    public var pairedJPGItems: [PhotoItem] = []
    public var pairedJPGItemsByRawID: [UUID: PhotoItem] = [:]
    
    // Dependencies
    public let scanner: CatalogScanner
    public let folderManager: FolderManager
    public let imageProvider: ImageProvider
    public let sidecarManager: SidecarManager
    public let embeddedWriter: EmbeddedMetadataWriter
    public let shortcutManager: ShortcutManager
    
    private var cancellables = Set<AnyCancellable>()
    
    public init(scanner: CatalogScanner, folderManager: FolderManager, imageProvider: ImageProvider, sidecarManager: SidecarManager, shortcutManager: ShortcutManager) {
        self.scanner = scanner
        self.folderManager = folderManager
        self.imageProvider = imageProvider
        self.sidecarManager = sidecarManager
        self.embeddedWriter = EmbeddedMetadataWriter()
        self.shortcutManager = shortcutManager
        
        setupShortcuts()
    }
    
    private func setupShortcuts() {
        shortcutManager.actionPublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] action in
                self?.handleShortcut(action)
            }
            .store(in: &cancellables)
    }
    
    public func handleShortcut(_ action: ShortcutAction) {
        switch action {
        case .navigateNext(let shift, let command):
            navigateNext(shift: shift, command: command)
        case .navigatePrevious(let shift, let command):
            navigatePrevious(shift: shift, command: command)
        case .navigateUp(let shift, let command):
            navigateUp(shift: shift, command: command)
        case .navigateDown(let shift, let command):
            navigateDown(shift: shift, command: command)
        case .addToSelection:
            addToSelection()
        case .clearSelection:
            isCollectingSelection = false
            if let id = currentPhoto?.id {
                selection = [id]
            }
            if viewMode == .compare {
                viewMode = .loupe
            }
        case .setRating(let rating):
            applyRating(rating)
        case .clearRating:
            applyRating(0)
        case .setLabel(let labelIndex):
            applyColorLabel(index: labelIndex)
        case .clearLabel:
            applyColorLabel(index: 0)
        case .viewModeLoupe:
            viewMode = .loupe
        case .viewModeGrid:
            viewMode = .grid
        case .viewModeCompare:
            viewMode = .compare
        case .toggleSidebar, .toggleInspector, .openFolder, .openRenameModal:
            // Handled at the view level or app level
            break
        case .toggleFaceZoom, .panUp, .panDown, .panLeft, .panRight:
            // Handled directly by LoupeView and CompareView via actionPublisher
            break
        case .cycleComparePane(let forward):
            cycleComparePane(forward: forward)
        case .setFlag(let pick):
            applyFlag(pick ? .pick : .reject)
        case .clearFlag:
            applyFlag(.none)
        case .toggleActualSize:
            // Handled directly by LoupeView via actionPublisher
            break
        }
    }

    /// Moves focus to the next/previous pane within the current compare set (the displayed
    /// selection, in filmstrip order), wrapping around. Rating/label keys target `currentPhoto`,
    /// so Tabbing to a pane lets you tag exactly that photo without reaching for the mouse.
    public func cycleComparePane(forward: Bool) {
        guard viewMode == .compare else { return }

        let panes = photos.filter { selection.contains($0.id) }.prefix(4)
        guard panes.count > 1 else { return }

        let currentPos = panes.firstIndex(where: { $0.id == currentPhoto?.id }) ?? panes.startIndex
        let step = forward ? 1 : -1
        let nextPos = (currentPos - panes.startIndex + step + panes.count) % panes.count
        let nextPhoto = panes[panes.startIndex + nextPos]

        if let idx = photos.firstIndex(of: nextPhoto) {
            currentPhotoIndex = idx
            loadCurrentMetadata()
        }
    }
    
    public func applyRating(_ rating: Int) {
        guard let photo = currentPhoto else { return }
        guard canWriteMetadata(to: photo) else {
            showHUD(.message("Sidecar files are read-only"))
            return
        }

        showHUD(.rating(rating))

        let sidecarURL = metadataSidecarURL(for: photo)
        var metadata = metadataCache[photo.id] ?? (try? sidecarManager.read(from: sidecarURL)) ?? PhotoMetadata()

        metadata.rating = rating
        currentMetadata = metadata
        cacheMetadata(metadata, for: photo)
        
        let sidecar = sidecarManager
        let writer = embeddedWriter
        let imageURL = photo.url
        Task.detached {
            // Write XMP sidecar (for pro tools like Lightroom, Photo Mechanic)
            do {
                try sidecar.write(metadata, to: sidecarURL)
            } catch {
                print("Failed to write sidecar \(sidecarURL.path): \(error)")
            }
            // Embed IPTC metadata in image (for Finder, Preview, macOS apps)
            try? writer.write(metadata, to: imageURL)
            // Write Finder color tags (for macOS tag column)
            try? writer.writeFinderTags(for: metadata, to: imageURL)
        }
        
        if filterSettings.minRating > 0 || !filterSettings.colors.isEmpty {
            applyFilters()
        }

        // Auto-advance
        if rating > 0 && viewMode != .compare && autoAdvance {
            navigateNext()
        }
    }
    
    public func applyColorLabel(index: Int) {
        guard let photo = currentPhoto else { return }
        guard canWriteMetadata(to: photo) else {
            showHUD(.message("Sidecar files are read-only"))
            return
        }
        
        let label: ColorLabel
        let color: Color
        switch index {
        case 1: label = .red; color = .red
        case 2: label = .yellow; color = .yellow
        case 3: label = .green; color = .green
        case 4: label = .blue; color = .blue
        case 5: label = .purple; color = .purple
        case 6: label = .orange; color = .orange
        case 7: label = .cyan; color = .cyan
        case 8: label = .magenta; color = .pink
        default: label = .none; color = .clear
        }
        
        if index > 0 {
            showHUD(.label(label.rawValue, color))
        }
        
        let sidecarURL = metadataSidecarURL(for: photo)
        var metadata = metadataCache[photo.id] ?? (try? sidecarManager.read(from: sidecarURL)) ?? PhotoMetadata()

        metadata.label = label
        currentMetadata = metadata
        cacheMetadata(metadata, for: photo)

        let sidecar = sidecarManager
        let writer = embeddedWriter
        let imageURL = photo.url
        Task.detached {
            // Write XMP sidecar (for pro tools)
            do {
                try sidecar.write(metadata, to: sidecarURL)
            } catch {
                print("Failed to write sidecar \(sidecarURL.path): \(error)")
            }
            // Write Finder color tags (visible in Finder tag column)
            try? writer.writeFinderTags(for: metadata, to: imageURL)
        }
        
        if filterSettings.minRating > 0 || !filterSettings.colors.isEmpty {
            applyFilters()
        }

        // Auto-advance
        if index > 0 && viewMode != .compare && autoAdvance {
            navigateNext()
        }
    }

    public func applyFlag(_ flag: PhotoFlag) {
        guard let photo = currentPhoto else { return }
        guard canWriteMetadata(to: photo) else {
            showHUD(.message("Sidecar files are read-only"))
            return
        }

        switch flag {
        case .pick:   showHUD(.message("✓ Pick"))
        case .reject: showHUD(.message("✗ Reject"))
        case .none:   showHUD(.message("Unflagged"))
        }

        let sidecarURL = metadataSidecarURL(for: photo)
        var metadata = metadataCache[photo.id] ?? (try? sidecarManager.read(from: sidecarURL)) ?? PhotoMetadata()

        metadata.flag = flag
        currentMetadata = metadata
        cacheMetadata(metadata, for: photo)

        let sidecar = sidecarManager
        let metaToWrite = metadata
        Task.detached {
            do {
                try sidecar.write(metaToWrite, to: sidecarURL)
            } catch {
                print("Failed to write sidecar \(sidecarURL.path): \(error)")
            }
        }

        if filterSettings.hideRejects {
            applyFilters()
        }

        // Auto-advance after flagging (same behavior as rating), but never in compare.
        if flag != .none && viewMode != .compare && autoAdvance {
            navigateNext()
        }
    }

    private func loadCurrentMetadata() {
        guard let photo = currentPhoto else {
            currentMetadata = PhotoMetadata()
            return
        }
        let sidecarURL = metadataSidecarURL(for: photo)
        currentMetadata = metadataCache[photo.id] ?? (try? sidecarManager.read(from: sidecarURL)) ?? PhotoMetadata()
    }
    
    private var activeScopedFolder: URL?

    public func openFolder(_ url: URL) async {
        activeScopedFolder?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() {
            activeScopedFolder = url
        }

        self.currentFolder = url
        do {
            let loadedPhotos = try await scanner.scan(folderURL: url, recursive: true)
            self.allPhotos = loadedPhotos.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
            
            let pairedJPGs = allPhotos.compactMap { photo -> (UUID, PhotoItem)? in
                guard let jpgURL = photo.pairedURL else { return nil }
                let resourceValues = try? jpgURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let jpgItem = PhotoItem(
                    url: jpgURL,
                    modificationDate: resourceValues?.contentModificationDate ?? photo.modificationDate,
                    fileSize: Int64(resourceValues?.fileSize ?? 0)
                )
                return (photo.id, jpgItem)
            }
            self.pairedJPGItemsByRawID = Dictionary(uniqueKeysWithValues: pairedJPGs)
            self.pairedJPGItems = pairedJPGs.map { $0.1 }
            self.availableFileExtensions = Array(Set((self.allPhotos + self.pairedJPGItems).map(\.fileExtension))).sorted()
            self.filterSettings.enabledFileExtensions = Set(self.availableFileExtensions)
            
            // Background metadata load for filtering
            let metadataItems = loadedPhotos + self.pairedJPGItems
            Task.detached { [weak self] in
                let sidecar = SidecarManager()
                var cache: [UUID: PhotoMetadata] = [:]
                for photo in metadataItems {
                    let sidecarURL = photo.url.deletingPathExtension().appendingPathExtension("xmp")
                    if let meta = try? sidecar.read(from: sidecarURL) {
                        cache[photo.id] = meta
                    }
                }
                await self?.updateMetadataCache(cache)
            }

            self.applyFilters()
            folderManager.addRecent(url: url)
            prefetch()
            
        } catch {
            print("Failed to open folder: \(error)")
            showHUD(.message("Error: \(error.localizedDescription)"))
        }
    }
    
    public func applyFilters() {
        let oldCurrentPhoto = self.currentPhoto
        
        self.photos = filteredSourcePhotos().filter { photo in
            let meta = metadataCache[photo.id] ?? PhotoMetadata()
            if filterSettings.minRating > 0 && meta.rating < filterSettings.minRating { return false }
            if !filterSettings.colors.isEmpty && !filterSettings.colors.contains(meta.label) { return false }
            if filterSettings.hideRejects && meta.flag == .reject { return false }

            return true
        }.sorted { a, b in
            switch sortOption {
            case .name:
                return a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
            case .date:
                return a.modificationDate > b.modificationDate
            case .size:
                return a.fileSize > b.fileSize
            }
        }
        
        if let current = oldCurrentPhoto, let newIdx = self.photos.firstIndex(where: { $0.id == current.id }) {
            self.currentPhotoIndex = newIdx
        } else if !self.photos.isEmpty {
            self.currentPhotoIndex = 0
            self.selection = [self.photos[0].id]
        } else {
            self.currentPhotoIndex = nil
            self.selection = []
        }
        loadCurrentMetadata()
    }

    private func filteredSourcePhotos() -> [PhotoItem] {
        allPhotos.flatMap { photo -> [PhotoItem] in
            if photo.isRAWJPEGPair {
                return filteredRAWJPEGPair(photo)
            }

            return isFileExtensionEnabled(photo.fileExtension) ? [photo.withPairing(nil)] : []
        }
    }

    private func filteredRAWJPEGPair(_ photo: PhotoItem) -> [PhotoItem] {
        let includeRAW = isFileExtensionEnabled(photo.fileExtension)
        let pairedJPEG = pairedJPGItemsByRawID[photo.id]
        let includeJPEG = pairedJPEG.map { isFileExtensionEnabled($0.fileExtension) } ?? false
        let keepPair = filterSettings.keepRAWAndJPEGPairsTogether

        if includeRAW && includeJPEG && keepPair {
            return [photo]
        }

        var items: [PhotoItem] = []

        if includeRAW {
            items.append(photo.withPairing(nil))
        }

        if includeJPEG, let pairedJPG = pairedJPEG {
            items.append(pairedJPG)
        }

        return items
    }

    private func isFileExtensionEnabled(_ ext: String) -> Bool {
        filterSettings.enabledFileExtensions.contains(ext.lowercased())
    }

    public func setFileExtension(_ ext: String, enabled: Bool) {
        let normalized = ext.lowercased()
        if enabled {
            filterSettings.enabledFileExtensions.insert(normalized)
        } else {
            filterSettings.enabledFileExtensions.remove(normalized)
        }
    }

    public func selectAllFileExtensions() {
        filterSettings.enabledFileExtensions = Set(availableFileExtensions)
    }

    public func clearFileExtensions() {
        filterSettings.enabledFileExtensions = []
    }

    public func metadataSidecarURL(for photo: PhotoItem) -> URL {
        photo.url.deletingPathExtension().appendingPathExtension("xmp")
    }

    public func canWriteMetadata(to photo: PhotoItem) -> Bool {
        !photo.isSidecar
    }

    public func renamableSelection() -> [PhotoItem] {
        photos.filter { selection.contains($0.id) && !$0.isSidecar }
    }

    public func cacheMetadata(_ metadata: PhotoMetadata, for photo: PhotoItem) {
        let sidecarURL = metadataSidecarURL(for: photo)
        for item in allKnownItems() where metadataSidecarURL(for: item) == sidecarURL {
            metadataCache[item.id] = metadata
        }
        if let current = currentPhoto, metadataSidecarURL(for: current) == sidecarURL {
            currentMetadata = metadata
        }
    }

    private func allKnownItems() -> [PhotoItem] {
        allPhotos + pairedJPGItems
    }
    
    private func updateMetadataCache(_ cache: [UUID: PhotoMetadata]) {
        self.metadataCache = cache
        self.applyFilters()
    }
    
    public func openInPreview(_ photo: PhotoItem) {
        NSWorkspace.shared.open(photo.url)
    }

    public func revealInFinder(_ photo: PhotoItem) {
        NSWorkspace.shared.activateFileViewerSelecting([photo.url])
    }
    
    public var currentPhoto: PhotoItem? {
        guard let index = currentPhotoIndex, index < photos.count else { return nil }
        return photos[index]
    }
    private func updateSelection(for newIndex: Int, shift: Bool, command: Bool) {
        let newId = photos[newIndex].id
        if shift {
            selection.insert(newId)
        } else if command || isCollectingSelection {
            // Move focus only, preserve user-built selection
        } else {
            if selection.count <= 1 {
                selection = [newId]
            }
        }
    }
    
    public func navigateNext(shift: Bool = false, command: Bool = false) {
        if viewMode == .compare {
            let selectedPhotos = photos.filter { selection.contains($0.id) }
            let batchSize = max(1, selectedPhotos.count)
            
            // Find the last index of the current batch
            if let lastSelected = selectedPhotos.last,
               let lastGlobalIdx = photos.firstIndex(of: lastSelected) {
                
                let nextStartIdx = lastGlobalIdx + 1
                if nextStartIdx < photos.count {
                    let nextEndIdx = min(photos.count, nextStartIdx + batchSize)
                    let newBatch = photos[nextStartIdx..<nextEndIdx]
                    
                    selection = Set(newBatch.map { $0.id })
                    currentPhotoIndex = nextStartIdx
                    loadCurrentMetadata()
                    prefetch()
                }
            }
        } else {
            guard let index = currentPhotoIndex, index + 1 < photos.count else { return }
            currentPhotoIndex = index + 1
            updateSelection(for: index + 1, shift: shift, command: command)
            loadCurrentMetadata()
            prefetch()
        }
    }

    public func navigatePrevious(shift: Bool = false, command: Bool = false) {
        if viewMode == .compare {
            let selectedPhotos = photos.filter { selection.contains($0.id) }
            let batchSize = max(1, selectedPhotos.count)
            
            // Find the first index of the current batch
            if let firstSelected = selectedPhotos.first,
               let firstGlobalIdx = photos.firstIndex(of: firstSelected) {
                
                let prevEndIdx = firstGlobalIdx
                if prevEndIdx > 0 {
                    let prevStartIdx = max(0, prevEndIdx - batchSize)
                    let newBatch = photos[prevStartIdx..<prevEndIdx]
                    
                    selection = Set(newBatch.map { $0.id })
                    currentPhotoIndex = prevStartIdx
                    loadCurrentMetadata()
                    prefetch()
                }
            }
        } else {
            guard let index = currentPhotoIndex, index > 0 else { return }
            currentPhotoIndex = index - 1
            updateSelection(for: index - 1, shift: shift, command: command)
            loadCurrentMetadata()
            prefetch()
        }
    }
    
    public func navigateUp(shift: Bool = false, command: Bool = false) {
        if viewMode == .grid {
            guard let index = currentPhotoIndex else { return }
            let newIndex = max(0, index - gridColumnsCount)
            if newIndex != index {
                currentPhotoIndex = newIndex
                updateSelection(for: newIndex, shift: shift, command: command)
                loadCurrentMetadata()
                prefetch()
            }
        } else {
            // In Loupe/Compare, up could mean something else, or just behave like previous
            navigatePrevious(shift: shift, command: command)
        }
    }
    
    public func navigateDown(shift: Bool = false, command: Bool = false) {
        if viewMode == .grid {
            guard let index = currentPhotoIndex, !photos.isEmpty else { return }
            let newIndex = min(photos.count - 1, index + gridColumnsCount)
            if newIndex != index {
                currentPhotoIndex = newIndex
                updateSelection(for: newIndex, shift: shift, command: command)
                loadCurrentMetadata()
                prefetch()
            }
        } else {
            // In Loupe/Compare, down could mean something else, or just behave like next
            navigateNext(shift: shift, command: command)
        }
    }
    
    public func addToSelection() {
        guard let current = currentPhoto else { return }
        isCollectingSelection = true
        selection.insert(current.id)
        showHUD(.message("\(selection.count) selected"))
        
        guard let index = currentPhotoIndex, index + 1 < photos.count else { return }
        currentPhotoIndex = index + 1
        loadCurrentMetadata()
        prefetch()
    }
    
    private func prefetch() {
        guard let index = currentPhotoIndex else { return }
        
        // Prefetch ±20 thumbnails, ±3 previews
        let startThumb = max(0, index - 20)
        let endThumb = min(photos.count, index + 20)
        let thumbRefs = photos[startThumb..<endThumb].map { PhotoRef(id: $0.id, url: $0.url, pairedURL: $0.pairedURL) }
        
        let startPrev = max(0, index - 3)
        let endPrev = min(photos.count, index + 3)
        let prevRefs = photos[startPrev..<endPrev].map { PhotoRef(id: $0.id, url: $0.url, pairedURL: $0.pairedURL) }
        
        Task {
            await imageProvider.prefetch(photos: thumbRefs, tier: .thumbnail)
            await imageProvider.prefetch(photos: prevRefs, tier: .preview)
        }
    }
    
    private func showHUD(_ message: HUDMessage) {
        activeHUD = message
        Task {
            try? await Task.sleep(for: .seconds(1))
            if activeHUD == message {
                withAnimation {
                    activeHUD = nil
                }
            }
        }
    }
}
