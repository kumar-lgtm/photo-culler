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
    @Published public var isScanning: Bool = false

    @Published public var filterSettings = FilterSettings() {
        didSet { if filterSettings != oldValue { applyFilters() } }
    }
    @Published public var sortOption: SortOption = .name {
        didSet { if sortOption != oldValue { applyFilters() } }
    }
    @Published public var autoAdvance: Bool = true

    /// Backed by UserDefaults but published manually.
    ///
    /// This was `@AppStorage`, which is a `DynamicProperty` — SwiftUI only drives its
    /// invalidation inside a `View`. On an `ObservableObject` nothing emitted
    /// `objectWillChange`, so flipping the toggle wrote the default but never redrew any of
    /// the views that read it.
    @Published public var isBeigeMode: Bool {
        didSet {
            guard isBeigeMode != oldValue else { return }
            UserDefaults.standard.set(isBeigeMode, forKey: Self.beigeModeKey)
        }
    }
    private static let beigeModeKey = "isBeigeMode"

    public var isCollectingSelection: Bool = false
    @Published public var metadataCache: [UUID: PhotoMetadata] = [:]
    @Published public var faceDataCache: [UUID: [FaceData]] = [:]
    @Published public var sharpnessCache: [UUID: Double] = [:]
    @Published public var availableFileExtensions: [String] = []
    /// Precomputed at scan time — the Inspector used to recount by filtering the whole
    /// catalog per extension on every render, and it re-renders on every arrow key.
    @Published public private(set) var extensionCounts: [String: Int] = [:]
    /// Sidecar files loaded from disk (e.g. written by Lightroom) so they can be filtered
    /// out of the displayed catalog instead of appearing as broken "Preview unavailable" tiles.
    public var allPhotos: [PhotoItem] = []
    public var pairedJPGItems: [PhotoItem] = []
    public var pairedJPGItemsByRawID: [UUID: PhotoItem] = [:]

    /// Codes stay loaded for the session instead of dying with the Metadata Editor sheet.
    @Published public var codeReplacementManager: CodeReplacementManager?
    @Published public var codeReplacementCount: Int = 0
    @Published public var codeReplacementSourceURL: URL?

    // Dependencies
    public let scanner: CatalogScanner
    public let folderManager: FolderManager
    public let imageProvider: ImageProvider
    public let sidecarManager: SidecarManager
    public let embeddedWriter: EmbeddedMetadataWriter
    public let shortcutManager: ShortcutManager
    /// Single owner of every metadata write — see `MetadataWriteCoordinator`.
    public let writeCoordinator: MetadataWriteCoordinator
    /// Held here, not in the modal's `View` struct, so the undo stack actually survives.
    public let renamer = BatchRenamer()

    private var cancellables = Set<AnyCancellable>()
    private var scanTask: Task<Void, Never>?
    private var metadataLoadTask: Task<Void, Never>?
    /// Guards against a slow scan of a previous folder landing on the current one.
    private var folderGeneration: UInt64 = 0
    private var hudToken: UInt64 = 0

    public init(scanner: CatalogScanner, folderManager: FolderManager, imageProvider: ImageProvider, sidecarManager: SidecarManager, shortcutManager: ShortcutManager) {
        self.scanner = scanner
        self.folderManager = folderManager
        self.imageProvider = imageProvider
        self.sidecarManager = sidecarManager
        self.embeddedWriter = EmbeddedMetadataWriter()
        self.shortcutManager = shortcutManager
        self.writeCoordinator = MetadataWriteCoordinator(sidecarManager: sidecarManager)
        self.isBeigeMode = UserDefaults.standard.bool(forKey: Self.beigeModeKey)

        setupShortcuts()
    }

    private func setupShortcuts() {
        shortcutManager.actionPublisher
            // `RunLoop.main` only delivers in the default run-loop mode, so keystrokes were
            // silently queued while a scroll, drag or menu-tracking loop was running.
            .receive(on: DispatchQueue.main)
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

        let panes = Array(photos.filter { selection.contains($0.id) }.prefix(4))
        guard panes.count > 1 else { return }

        let currentPos = panes.firstIndex(where: { $0.id == currentPhoto?.id }) ?? 0
        let step = forward ? 1 : -1
        let nextPos = (currentPos + step + panes.count) % panes.count
        let nextPhoto = panes[nextPos]

        if let idx = photos.firstIndex(of: nextPhoto) {
            currentPhotoIndex = idx
            loadCurrentMetadata()
        }
    }

    // MARK: - Tagging

    /// One path for every tag mutation, so rating, label and flag can't drift apart in how
    /// they persist, filter and advance.
    private func applyTagging(showing hud: HUDMessage?,
                              advances: Bool,
                              writeEmbedded: Bool,
                              writeFinderTags: Bool,
                              mutate: (inout PhotoMetadata) -> Void) {
        guard let photo = currentPhoto else { return }
        guard canWriteMetadata(to: photo) else {
            showHUD(.message("Sidecar files are read-only"))
            return
        }

        if let hud { showHUD(hud) }

        // Resolve the photo we'd advance to *before* filters can remove the current one.
        // Previously `applyFilters()` ran first, reset the index to 0 when the just-tagged
        // photo no longer passed the filter, and `navigateNext()` then moved to index 1 —
        // silently skipping whatever had slid into position 0.
        let successorID: UUID? = advances ? photoAfterCurrent()?.id : nil

        let sidecarURL = metadataSidecarURL(for: photo)
        var metadata = metadataCache[photo.id] ?? (try? sidecarManager.read(from: sidecarURL)) ?? PhotoMetadata()
        mutate(&metadata)

        currentMetadata = metadata
        cacheMetadata(metadata, for: photo)

        let job = MetadataWriteCoordinator.Job(
            metadata: metadata,
            sidecarURL: sidecarURL,
            imageURL: photo.url,
            writeEmbedded: writeEmbedded,
            writeFinderTags: writeFinderTags
        )
        writeCoordinator.submit(job)

        if filtersDependOnMetadata {
            applyFilters()
        }

        guard advances, autoAdvance, viewMode != .compare else { return }

        if let successorID, let idx = photos.firstIndex(where: { $0.id == successorID }) {
            currentPhotoIndex = idx
            updateSelection(for: idx, shift: false, command: false)
            loadCurrentMetadata()
            prefetch()
        } else if successorID == nil {
            navigateNext()
        }
        // If the successor was itself filtered out, staying put is correct — the list
        // already advanced underneath us.
    }

    private var filtersDependOnMetadata: Bool {
        filterSettings.minRating > 0 || !filterSettings.colors.isEmpty || filterSettings.hideRejects
    }

    private func photoAfterCurrent() -> PhotoItem? {
        guard let index = currentPhotoIndex, index + 1 < photos.count else { return nil }
        return photos[index + 1]
    }

    public func applyRating(_ rating: Int) {
        applyTagging(showing: .rating(rating),
                     advances: rating > 0,
                     writeEmbedded: true,
                     writeFinderTags: true) { $0.rating = rating }
    }

    public func applyColorLabel(index: Int) {
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

        applyTagging(showing: index > 0 ? .label(label.rawValue, color) : nil,
                     advances: index > 0,
                     writeEmbedded: false,
                     writeFinderTags: true) { $0.label = label }
    }

    public func applyFlag(_ flag: PhotoFlag) {
        let hud: HUDMessage
        switch flag {
        case .pick:   hud = .message("✓ Pick")
        case .reject: hud = .message("✗ Reject")
        case .none:   hud = .message("Unflagged")
        }

        applyTagging(showing: hud,
                     advances: flag != .none,
                     writeEmbedded: false,
                     writeFinderTags: false) { $0.flag = flag }
    }

    /// Persists whatever is currently in `currentMetadata` for the focused photo.
    ///
    /// The Metadata Editor edits `currentMetadata` in memory; without this, navigating away
    /// dropped every typed caption on the floor because `loadCurrentMetadata()` overwrote it.
    public func commitCurrentMetadata() {
        guard let photo = currentPhoto, canWriteMetadata(to: photo) else { return }
        let sidecarURL = metadataSidecarURL(for: photo)
        guard metadataCache[photo.id] != currentMetadata else { return }

        let metadata = currentMetadata
        cacheMetadata(metadata, for: photo)

        let job = MetadataWriteCoordinator.Job(
            metadata: metadata,
            sidecarURL: sidecarURL,
            imageURL: photo.url,
            // Captions, creator and copyright are exactly the fields the embedded writer
            // supports, and they used to reach the sidecar only.
            writeEmbedded: true,
            writeFinderTags: true
        )
        writeCoordinator.submit(job)
    }

    /// Applies a stationery-pad template across the current selection.
    public func applyTemplate(_ template: MetadataTemplate) {
        let targets = photos.filter { selection.contains($0.id) && canWriteMetadata(to: $0) }

        for photo in targets {
            let sidecarURL = metadataSidecarURL(for: photo)
            var metadata = metadataCache[photo.id] ?? PhotoMetadata()
            metadata = template.apply(to: metadata)
            cacheMetadata(metadata, for: photo)

            if photo.id == currentPhoto?.id { currentMetadata = metadata }

            let job = MetadataWriteCoordinator.Job(
                metadata: metadata,
                sidecarURL: sidecarURL,
                imageURL: photo.url,
                writeEmbedded: true,
                writeFinderTags: true
            )
            writeCoordinator.submit(job)
        }

        showHUD(.message("Applied to \(targets.count)"))
    }

    /// Ensures queued writes reach disk before the app exits.
    public func flushPendingWrites() async {
        await writeCoordinator.flush()
    }

    private func loadCurrentMetadata() {
        guard let photo = currentPhoto else {
            currentMetadata = PhotoMetadata()
            return
        }
        let sidecarURL = metadataSidecarURL(for: photo)
        currentMetadata = metadataCache[photo.id] ?? (try? sidecarManager.read(from: sidecarURL)) ?? PhotoMetadata()
    }

    // MARK: - Folders

    private var activeScopedFolder: URL?

    public func openFolder(_ url: URL) async {
        // Cancel anything still running for the previous folder. A slow scan used to finish
        // later and replace the *new* folder's metadata cache with the old folder's.
        scanTask?.cancel()
        metadataLoadTask?.cancel()
        folderGeneration &+= 1
        let generation = folderGeneration

        activeScopedFolder?.stopAccessingSecurityScopedResource()
        activeScopedFolder = url.startAccessingSecurityScopedResource() ? url : nil

        self.currentFolder = url
        self.isScanning = true
        let diagStart = DispatchTime.now()
        Diag.log("openFolder: \(url.path)")

        // A new folder means the old derived caches are meaningless — and they used to grow
        // without bound because only `metadataCache` was ever replaced.
        self.faceDataCache = [:]
        self.sharpnessCache = [:]
        self.metadataCache = [:]

        do {
            let scanStart = DispatchTime.now()
            let loadedPhotos = try await scanner.scan(folderURL: url, recursive: true)
            Diag.log(String(format: "  scan: %.0f ms, %d items", Diag.elapsedMS(since: scanStart), loadedPhotos.count))
            guard generation == folderGeneration else { return }

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

            let displayable = (self.allPhotos + self.pairedJPGItems).filter { !$0.isSidecar }
            var counts: [String: Int] = [:]
            for item in displayable { counts[item.fileExtension, default: 0] += 1 }
            self.extensionCounts = counts
            self.availableFileExtensions = counts.keys.sorted()
            self.filterSettings.enabledFileExtensions = Set(self.availableFileExtensions)

            self.isScanning = false
            let filterStart = DispatchTime.now()
            self.applyFilters()
            Diag.log(String(format: "  filter+sort: %.0f ms, %d visible", Diag.elapsedMS(since: filterStart), self.photos.count))
            folderManager.addRecent(url: url)
            prefetch()
            Diag.log(String(format: "openFolder returned after %.0f ms (decode continues in background)",
                            Diag.elapsedMS(since: diagStart)))

            startMetadataLoad(for: loadedPhotos + self.pairedJPGItems, generation: generation)

        } catch is CancellationError {
            // Superseded by a newer folder — nothing to report.
        } catch {
            guard generation == folderGeneration else { return }
            self.isScanning = false
            showHUD(.message("Error: \(error.localizedDescription)"))
        }
    }

    private func startMetadataLoad(for items: [PhotoItem], generation: UInt64) {
        // Detached on purpose: a plain `Task {}` inside this @MainActor type inherits main
        // actor isolation, which would run a sidecar read per photo on the main thread.
        metadataLoadTask = Task.detached(priority: .utility) { [weak self] in
            let sidecar = SidecarManager()
            var cache: [UUID: PhotoMetadata] = [:]

            for (index, photo) in items.enumerated() {
                if index % 128 == 0, Task.isCancelled { return }
                let sidecarURL = photo.url.deletingPathExtension().appendingPathExtension("xmp")
                if let meta = try? sidecar.read(from: sidecarURL) {
                    cache[photo.id] = meta
                }
            }

            guard !Task.isCancelled else { return }
            await self?.mergeMetadataCache(cache, generation: generation)
        }
    }

    private func mergeMetadataCache(_ cache: [UUID: PhotoMetadata], generation: UInt64) {
        // Stale results from a previous folder must never land on the current one.
        guard generation == folderGeneration else { return }
        // Merge rather than replace: the user may have tagged photos while the scan ran.
        metadataCache.merge(cache) { existing, _ in existing }
        applyFilters()
    }

    // MARK: - Filtering

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
            // Sidecars are metadata, not photos. They used to be hidden on disk, which
            // kept them out of the scan by accident; sidecars written by Lightroom or
            // Capture One still showed up as broken "Preview unavailable" tiles.
            if photo.isSidecar { return [] }

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
        if includeRAW { items.append(photo.withPairing(nil)) }
        if includeJPEG, let pairedJPG = pairedJPEG { items.append(pairedJPG) }
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

    public func count(forExtension ext: String) -> Int {
        extensionCounts[ext.lowercased()] ?? 0
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

    // MARK: - Code replacements

    public func loadCodeReplacements(from url: URL) throws {
        let manager = try CodeReplacementManager.load(from: url)
        codeReplacementManager = manager
        codeReplacementCount = manager.count
        codeReplacementSourceURL = url
        UserDefaults.standard.set(url.path, forKey: "PhotoCuller_CodeReplacementPath")
    }

    /// Re-loads the last code file at launch so a sports shooter's roster survives a restart.
    public func restoreCodeReplacements() {
        guard codeReplacementManager == nil,
              let path = UserDefaults.standard.string(forKey: "PhotoCuller_CodeReplacementPath"),
              FileManager.default.fileExists(atPath: path) else { return }
        try? loadCodeReplacements(from: URL(fileURLWithPath: path))
    }

    public func expandCodes(in text: String) -> String {
        codeReplacementManager?.expand(text) ?? text
    }

    // MARK: - Misc

    public func openInPreview(_ photo: PhotoItem) {
        NSWorkspace.shared.open(photo.url)
    }

    public func revealInFinder(_ photo: PhotoItem) {
        NSWorkspace.shared.activateFileViewerSelecting([photo.url])
    }

    public var currentPhoto: PhotoItem? {
        guard let index = currentPhotoIndex, index >= 0, index < photos.count else { return nil }
        return photos[index]
    }

    private func updateSelection(for newIndex: Int, shift: Bool, command: Bool) {
        guard newIndex >= 0, newIndex < photos.count else { return }
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
        guard let index = currentPhotoIndex, !photos.isEmpty else { return }

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
        hudToken &+= 1
        let token = hudToken
        activeHUD = message
        Task {
            try? await Task.sleep(for: .seconds(1))
            // Token, not value equality — two identical messages in a row used to make the
            // first timer dismiss the second one early.
            guard token == hudToken else { return }
            withAnimation { activeHUD = nil }
        }
    }
}
