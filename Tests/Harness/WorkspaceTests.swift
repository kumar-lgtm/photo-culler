import Foundation
import AppKit
import UI
import Catalog
import Decode
import Sidecar
import Shortcuts

/// Drives `WorkspaceViewModel` against real files on disk.
///
/// SwiftUI *views* need a running app, but the state machine behind them does not — and
/// that's where the culling behaviour actually lives. These exercise the end-to-end path a
/// photographer takes: open a folder Lightroom has already rated, tag photos, switch
/// folders mid-scan, filter, rename.
@MainActor
enum WorkspaceSuite {

    static func run(_ t: TestRunner) async throws {
        t.suite("Workspace — opens a Lightroom-rated folder end to end (3.1/3.3)")
        try await lightroomFolder(t)

        t.suite("Workspace — tagging round-trips to disk (2.1)")
        try await taggingPersists(t)

        t.suite("Workspace — auto-advance under an active filter (4.8)")
        try await autoAdvanceFiltered(t)

        t.suite("Workspace — folder switching cannot clobber the new folder (4.7/5.17)")
        try await folderSwitch(t)

        t.suite("Workspace — beige mode publishes (5.9)")
        beigeModePublishes(t)

        t.suite("Workspace — metadata editor commit (2.7/5.16)")
        try await metadataCommit(t)
    }

    // MARK: - Fixtures

    private static func makeViewModel() -> WorkspaceViewModel {
        WorkspaceViewModel(scanner: CatalogScanner(),
                           folderManager: FolderManager(),
                           imageProvider: ImageProvider(),
                           sidecarManager: SidecarManager(),
                           shortcutManager: ShortcutManager())
    }

    /// Writes a sidecar in Adobe's compact attribute form — what Lightroom actually emits.
    private static func writeLightroomSidecar(at url: URL, rating: Int, label: String) throws {
        try """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 9.0">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmp:Rating="\(rating)"
              xmp:Label="\(label)"/>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func makeShoot(_ count: Int) throws -> URL {
        let dir = try TempDir.make("shoot")
        for i in 1...count {
            let base = String(format: "IMG_%04d", i)
            try Data("raw".utf8).write(to: dir.appendingPathComponent("\(base).CR2"))
            try Data("jpg".utf8).write(to: dir.appendingPathComponent("\(base).JPG"))
        }
        return dir
    }

    /// Waits for the coordinator's queued writes to reach disk.
    private static func settle(_ vm: WorkspaceViewModel) async {
        await vm.flushPendingWrites()
    }

    // MARK: -

    /// The scenario the whole interop fix exists for.
    private static func lightroomFolder(_ t: TestRunner) async throws {
        let dir = try makeShoot(3); defer { TempDir.cleanup(dir) }

        // Lightroom rated two of the three, and left visible .xmp files behind.
        try writeLightroomSidecar(at: dir.appendingPathComponent("IMG_0001.xmp"), rating: 5, label: "Red")
        try writeLightroomSidecar(at: dir.appendingPathComponent("IMG_0002.xmp"), rating: 3, label: "Blue")

        let vm = makeViewModel()
        await vm.openFolder(dir)
        // The background metadata pass is what populates ratings from sidecars.
        for _ in 0..<80 where vm.metadataCache.isEmpty {
            try? await Task.sleep(for: .milliseconds(25))
        }

        t.equal(vm.photos.count, 3, "three RAW+JPEG pairs shown as three items")

        // Sidecars must not appear as broken tiles — this is the 3.3 fix.
        let sidecarTiles = vm.photos.filter { $0.isSidecar }
        t.equal(sidecarTiles.count, 0, "Lightroom's .xmp files are filtered out of the catalog")
        t.check(!vm.availableFileExtensions.contains("xmp"), "xmp not offered as a filterable file type")

        // And the ratings Lightroom wrote must actually show up — the headline interop bug.
        let first = vm.photos.first { $0.url.lastPathComponent == "IMG_0001.CR2" }
        let second = vm.photos.first { $0.url.lastPathComponent == "IMG_0002.CR2" }
        let third = vm.photos.first { $0.url.lastPathComponent == "IMG_0003.CR2" }

        t.equal(first.flatMap { vm.metadataCache[$0.id]?.rating }, 5, "reads Lightroom's 5-star rating")
        t.equal(first.flatMap { vm.metadataCache[$0.id]?.label }, .red, "reads Lightroom's Red label")
        t.equal(second.flatMap { vm.metadataCache[$0.id]?.rating }, 3, "reads Lightroom's 3-star rating")
        t.equal(third.flatMap { vm.metadataCache[$0.id]?.rating }, nil, "unrated photo has no metadata entry")

        t.equal(vm.count(forExtension: "cr2"), 3, "extension counts precomputed (5.7)")
        t.equal(vm.count(forExtension: "jpg"), 3, "paired JPEGs counted too")
    }

    private static func taggingPersists(_ t: TestRunner) async throws {
        let dir = try makeShoot(4); defer { TempDir.cleanup(dir) }
        let vm = makeViewModel()
        await vm.openFolder(dir)

        t.equal(vm.currentPhotoIndex, 0, "focus starts on the first photo")

        // Machine-gun the way a real cull does: rate, label, flag in quick succession.
        vm.applyRating(4)
        vm.applyColorLabel(index: 1)     // Red
        vm.applyFlag(.pick)
        vm.applyRating(2)
        await settle(vm)

        // Whatever the final in-memory state is, disk must agree with it.
        let target = vm.allPhotos.first { $0.url.lastPathComponent == "IMG_0001.CR2" }!
        let sidecarURL = vm.metadataSidecarURL(for: target)
        t.check(sidecarURL.exists, "sidecar written for the tagged photo")
        t.check(!sidecarURL.isHiddenFlag, "sidecar is visible on disk")

        let onDisk = try SidecarManager().read(from: sidecarURL)
        let inMemory = vm.metadataCache[target.id]
        t.equal(onDisk.rating, inMemory?.rating, "on-disk rating matches the view model")
        t.equal(onDisk.label, inMemory?.label, "on-disk label matches the view model")
        t.equal(onDisk.flag, inMemory?.flag, "on-disk flag matches the view model")

        // No scratch files survive a burst.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        t.equal(leftovers.filter { $0.contains(".tmp") }.count, 0, "no temp files left in the shoot folder")
    }

    /// Rating a photo out of the filtered set used to skip the photo that slid into its place.
    private static func autoAdvanceFiltered(_ t: TestRunner) async throws {
        let dir = try makeShoot(5); defer { TempDir.cleanup(dir) }
        let vm = makeViewModel()
        await vm.openFolder(dir)

        vm.autoAdvance = true
        // Show only 3-star-and-up. Nothing is rated, so the list empties as we rate.
        vm.filterSettings.minRating = 3

        // With the filter on and nothing rated, the visible list is empty.
        t.equal(vm.photos.count, 0, "filter hides every unrated photo")

        // Now the realistic case: filter on 1-star-and-up, rate the first photo 1 star.
        vm.filterSettings.minRating = 0
        t.equal(vm.photos.count, 5, "all five visible with the filter off")

        vm.filterSettings.hideRejects = true
        let firstID = vm.photos[0].id
        let secondID = vm.photos[1].id

        // Reject the first photo — it disappears from the list, and focus must land on the
        // photo that took its place, not skip past it.
        vm.applyFlag(.reject)
        await settle(vm)

        t.equal(vm.photos.count, 4, "rejected photo removed from the visible list")
        t.check(!vm.photos.contains { $0.id == firstID }, "the rejected photo is gone")
        t.equal(vm.currentPhoto?.id, secondID, "focus lands on the NEXT photo, not one past it")
    }

    private static func folderSwitch(_ t: TestRunner) async throws {
        let folderA = try makeShoot(6); defer { TempDir.cleanup(folderA) }
        let folderB = try makeShoot(2); defer { TempDir.cleanup(folderB) }

        // Folder A is heavily rated; folder B is untouched.
        for i in 1...6 {
            try writeLightroomSidecar(at: folderA.appendingPathComponent(String(format: "IMG_%04d.xmp", i)),
                                      rating: 5, label: "Red")
        }

        let vm = makeViewModel()
        // Open A and immediately switch to B, without waiting for A's metadata pass.
        async let openA: Void = vm.openFolder(folderA)
        _ = await openA
        await vm.openFolder(folderB)

        // Give any stale task from A every chance to land on B.
        try? await Task.sleep(for: .milliseconds(400))

        t.equal(vm.currentFolder, folderB, "current folder is B")
        t.equal(vm.photos.count, 2, "showing B's two photos, not A's six")

        // The clobber bug: A's ratings appearing against B's photos.
        let ratedInB = vm.photos.filter { (vm.metadataCache[$0.id]?.rating ?? 0) > 0 }
        t.equal(ratedInB.count, 0, "folder A's ratings did not leak onto folder B")

        // Derived caches are reset per folder rather than growing forever.
        t.equal(vm.faceDataCache.count, 0, "face cache cleared on folder change")
        t.equal(vm.sharpnessCache.count, 0, "sharpness cache cleared on folder change")
    }

    /// `@AppStorage` on an ObservableObject never emitted objectWillChange, so ~40 views
    /// reading this property never redrew when it flipped.
    private static func beigeModePublishes(_ t: TestRunner) {
        let vm = makeViewModel()
        let original = vm.isBeigeMode

        var notifications = 0
        let token = vm.objectWillChange.sink { _ in notifications += 1 }

        vm.isBeigeMode = !original
        t.check(notifications > 0, "toggling beige mode emits objectWillChange (views redraw)")
        t.equal(vm.isBeigeMode, !original, "value actually changed")

        // And it persists.
        t.equal(UserDefaults.standard.bool(forKey: "isBeigeMode"), !original, "written through to UserDefaults")

        vm.isBeigeMode = original          // restore
        token.cancel()
    }

    private static func metadataCommit(_ t: TestRunner) async throws {
        let dir = try makeShoot(2); defer { TempDir.cleanup(dir) }
        let vm = makeViewModel()
        await vm.openFolder(dir)

        // Type a caption the way the Metadata Editor does — straight into currentMetadata.
        vm.currentMetadata.headline = "Cup Final"
        vm.currentMetadata.description = "Keeper lifts the trophy"
        vm.currentMetadata.creator = "Braveen Kumar"
        vm.commitCurrentMetadata()
        await settle(vm)

        let target = vm.allPhotos.first { $0.url.lastPathComponent == "IMG_0001.CR2" }!
        let onDisk = try SidecarManager().read(from: vm.metadataSidecarURL(for: target))
        t.equal(onDisk.headline, "Cup Final", "headline persisted")
        t.equal(onDisk.description, "Keeper lifts the trophy", "caption persisted")
        t.equal(onDisk.creator, "Braveen Kumar", "creator persisted")

        // Navigating away must not resurrect the pre-edit state.
        vm.navigateNext()
        vm.navigatePrevious()
        t.equal(vm.currentMetadata.headline, "Cup Final", "edit survives navigating away and back")

        // Stationery pad across a selection.
        vm.selection = Set(vm.photos.map { $0.id })
        vm.applyTemplate(MetadataTemplate(name: "Shoot", copyright: "© KCI"))
        await settle(vm)

        let second = vm.allPhotos.first { $0.url.lastPathComponent == "IMG_0002.CR2" }!
        let secondOnDisk = try SidecarManager().read(from: vm.metadataSidecarURL(for: second))
        t.equal(secondOnDisk.copyright, "© KCI", "template applied across the selection")
    }
}
