import Foundation
import AppKit
import UI
import Catalog
import Decode
import Sidecar
import Shortcuts

@MainActor
enum UXSuite {
    static func run(_ t: TestRunner) async throws {
        t.suite("UX — distinct workspace states and filter recovery")
        try await workspaceStates(t)
        t.suite("UX — photo focus refreshes the inspector and explicit save persists")
        try await focusAndSave(t)
        t.suite("UX — failed metadata save can be retried")
        try await saveRetry(t)
        t.suite("UX — editor save keeps its captured photo and ignores unrelated errors")
        try await capturedSave(t)
        t.suite("UX — template targets follow shared sidecars")
        try await sharedTemplateTargets(t)
        t.suite("UX — Tab belongs to native focus outside compare")
        shortcuts(t)
        t.suite("UX — enabled ingest options cannot silently disappear")
        ingestValidation(t)
    }

    private static func model() -> WorkspaceViewModel {
        WorkspaceViewModel(scanner: CatalogScanner(), folderManager: FolderManager(), imageProvider: ImageProvider(),
                           sidecarManager: SidecarManager(), shortcutManager: ShortcutManager())
    }

    private static func workspaceStates(_ t: TestRunner) async throws {
        let folder = try TempDir.make("ux-states"); defer { TempDir.cleanup(folder) }
        let vm = model()
        t.equal(vm.contentState, .welcome, "first run has its own state")
        await vm.openFolder(folder)
        t.equal(vm.contentState, .emptyFolder, "empty folder does not masquerade as first run")
        for name in ["one.CR2", "one.JPG", "two.JPG"] { try folder.appendingPathComponent(name).writeText("media") }
        await vm.openFolder(folder)
        t.equal(vm.contentState, .ready, "populated folder reaches ready")
        vm.selection = Set(vm.photos.map(\.id))
        vm.sortOption = .size
        vm.filterSettings.keepRAWAndJPEGPairsTogether = false
        vm.filterSettings.minRating = 5
        vm.filterSettings.colors = [.red]
        vm.filterSettings.hideRejects = true
        vm.clearFileExtensions()
        t.equal(vm.contentState, .filteredEmpty, "filters have a distinct recoverable empty state")
        t.check(vm.hasActiveFilters, "active filters are reported")
        t.check(vm.selection.isEmpty, "hidden photos do not remain selected")
        vm.clearFilters()
        t.equal(vm.photos.count, 3, "clear filters restores all separate media items")
        t.equal(vm.contentState, .ready, "clear filters recovers ready")
        t.check(!vm.hasActiveFilters, "all filtering dimensions reset")
        t.check(!vm.filterSettings.keepRAWAndJPEGPairsTogether, "pair preference survives clearing filters")
        t.equal(vm.sortOption, .size, "sort choice survives clearing filters")

        let unavailable = folder.appendingPathComponent("not-yet-mounted")
        await vm.openFolder(unavailable)
        if case .folderError = vm.contentState { t.check(true, "unavailable folder exposes a persistent error state") }
        else { t.fail("missing folder must not appear as an empty successful scan") }
        try FileManager.default.createDirectory(at: unavailable, withIntermediateDirectories: true)
        await vm.openFolder(unavailable)
        t.equal(vm.contentState, .emptyFolder, "retry clears the prior error once the folder is available")
        await vm.openFolder(folder.appendingPathComponent("one.CR2"))
        if case .folderError(let message) = vm.contentState {
            t.check(message.contains("isn’t a folder"), "opening a file gives a meaningful folder-selection error")
        } else { t.fail("a file URL must not be accepted as an empty folder") }
    }

    private static func focusAndSave(_ t: TestRunner) async throws {
        let folder = try TempDir.make("ux-focus"); defer { TempDir.cleanup(folder) }
        for name in ["one.CR2", "two.CR2"] { try folder.appendingPathComponent(name).writeText("raw") }
        let sidecars = SidecarManager()
        try sidecars.write(PhotoMetadata(rating: 4, headline: "First"), to: folder.appendingPathComponent("one.xmp"))
        try sidecars.write(PhotoMetadata(rating: 2, headline: "Second"), to: folder.appendingPathComponent("two.xmp"))
        let vm = model()
        await vm.openFolder(folder)
        let second = vm.photos.first { $0.url.lastPathComponent == "two.CR2" }!
        vm.focusPhoto(second.id)
        t.equal(vm.currentPhoto?.id, second.id, "direct photo selection changes focus")
        t.equal(vm.currentMetadata.rating, 2, "direct selection refreshes the inspector rating")
        t.equal(vm.currentMetadata.headline, "Second", "direct selection refreshes IPTC fields")
        vm.currentMetadata.headline = "Saved by explicit action"
        try await vm.saveCurrentMetadata()
        t.equal(try sidecars.read(from: folder.appendingPathComponent("two.xmp")).headline,
                "Saved by explicit action", "explicit save awaits disk persistence")
        t.equal(try sidecars.read(from: folder.appendingPathComponent("one.xmp")).headline,
                "First", "saving focused photo leaves the other photo untouched")
        let blank = model()
        do { try await blank.saveCurrentMetadata(); t.fail("saving with no photo must fail explicitly") }
        catch { t.check(true, "saving without a photo returns an actionable error") }
    }

    private static func saveRetry(_ t: TestRunner) async throws {
        let folder = try TempDir.make("ux-save-retry"); defer { TempDir.cleanup(folder) }
        try folder.appendingPathComponent("one.CR2").writeText("raw")
        let sidecar = folder.appendingPathComponent("one.xmp")
        let unavailable = folder.appendingPathExtension("temporarily-unavailable")
        defer { TempDir.cleanup(unavailable) }
        let vm = model()
        await vm.openFolder(folder)
        try FileManager.default.moveItem(at: folder, to: unavailable)
        vm.currentMetadata.headline = "Retry me"
        do { try await vm.saveCurrentMetadata(); t.fail("unavailable folder must report a save failure") }
        catch { t.check(true, "write failure reaches the caller instead of dismissing as success") }
        try FileManager.default.moveItem(at: unavailable, to: folder)
        try await vm.saveCurrentMetadata()
        t.equal(try SidecarManager().read(from: sidecar).headline, "Retry me",
                "retry submits the same draft even if the optimistic cache already matches")
    }

    private static func event(_ code: UInt16, _ chars: String, _ modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    private static func sharedTemplateTargets(_ t: TestRunner) async throws {
        let folder = try TempDir.make("ux-template-targets"); defer { TempDir.cleanup(folder) }
        for name in ["pair.CR2", "pair.JPG", "other.CR2"] { try folder.appendingPathComponent(name).writeText("media") }
        let vm = model()
        await vm.openFolder(folder)
        vm.filterSettings.keepRAWAndJPEGPairsTogether = false
        let raw = vm.photos.first { $0.url.lastPathComponent == "pair.CR2" }!
        let jpeg = vm.photos.first { $0.url.lastPathComponent == "pair.JPG" }!
        let other = vm.photos.first { $0.url.lastPathComponent == "other.CR2" }!
        vm.selection = [jpeg.id]
        vm.focusPhoto(raw.id)
        let targets = vm.applyTemplate(MetadataTemplate(name: "Credit", copyright: "QA credit"))
        await vm.flushPendingWrites()
        t.check(targets.contains(vm.metadataSidecarURL(for: raw)), "a selected JPEG's target includes its deselected RAW sidecar")
        t.check(!targets.contains(vm.metadataSidecarURL(for: other)), "unrelated deselected photo is outside the template targets")
        t.equal(vm.metadataCache[raw.id]?.copyright, "QA credit", "shared RAW metadata is updated with the selected JPEG")
        t.equal(vm.metadataCache[other.id]?.copyright, nil, "unrelated photo metadata is untouched")
    }

    private static func capturedSave(_ t: TestRunner) async throws {
        let folder = try TempDir.make("ux-captured"); defer { TempDir.cleanup(folder) }
        for name in ["one.CR2", "two.CR2"] { try folder.appendingPathComponent(name).writeText("raw") }
        let vm = model()
        await vm.openFolder(folder)
        let first = vm.photos.first { $0.url.lastPathComponent == "one.CR2" }!
        let second = vm.photos.first { $0.url.lastPathComponent == "two.CR2" }!
        vm.cacheMetadata(PhotoMetadata(headline: "Keep B intact"), for: second)
        vm.focusPhoto(second.id)
        let draft = PhotoMetadata(rating: 3, flag: .reject, headline: "Draft belongs to A")
        try await vm.saveMetadata(draft, for: first)
        t.equal(try SidecarManager().read(from: vm.metadataSidecarURL(for: first)).headline, "Draft belongs to A", "save targets the captured photo after focus changes")
        t.equal(vm.currentMetadata.headline, "Keep B intact", "saving A does not overwrite B's inspector state")
        t.check(!vm.metadataSidecarURL(for: second).exists, "saving A does not create B's sidecar")

        let badURL = folder.appendingPathComponent("missing-parent/failed.xmp")
        vm.writeCoordinator.submit(.init(metadata: PhotoMetadata(rating: 5), sidecarURL: badURL, imageURL: first.url))
        await vm.flushPendingWrites()
        try await vm.saveMetadata(PhotoMetadata(headline: "Successful B save"), for: second)
        t.equal(try SidecarManager().read(from: vm.metadataSidecarURL(for: second)).headline, "Successful B save", "historical failure does not fail another photo's successful save")
        t.equal(vm.writeCoordinator.consumeLastError()?.url, badURL, "legacy error reporting retains the unrelated failure")

        // Every coalesced caller must receive a completion, not disappear with a pending value.
        let coordinator = MetadataWriteCoordinator()
        let output = folder.appendingPathComponent("coalesced.xmp")
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<30 {
                group.addTask {
                    try await coordinator.writeAndWait(.init(metadata: PhotoMetadata(rating: i % 6), sidecarURL: output, imageURL: first.url))
                }
            }
            try await group.waitForAll()
        }
        t.check(output.exists, "all coalesced save waiters complete and persist a valid sidecar")
        _ = try SidecarManager().read(from: output)
        t.equal(coordinator.consumeLastError()?.url, nil, "coalesced successful saves do not invent an error")
    }

    private static func shortcuts(_ t: TestRunner) {
        let vm = model()
        let manager = vm.shortcutManager
        t.equal(manager.action(for: event(48, "\t")), nil, "Tab is not swallowed in loupe")
        vm.viewMode = .grid
        t.equal(manager.action(for: event(48, "\t", .shift)), nil, "Shift-Tab remains native in grid")
        vm.viewMode = .compare
        t.equal(manager.action(for: event(48, "\t")), .cycleComparePane(forward: true), "Tab cycles compare panes")
        t.equal(manager.action(for: event(48, "\t", .shift)), .cycleComparePane(forward: false), "Shift-Tab cycles backwards in compare")
        t.equal(manager.action(for: event(48, "\t", .command)), nil, "Command-Tab remains owned by macOS")
        vm.viewMode = .loupe
        t.equal(manager.action(for: event(48, "\t")), nil, "leaving compare restores native Tab")
        t.equal(manager.action(for: event(18, "1")), .setRating(1), "rating shortcut is preserved")
        t.equal(manager.action(for: event(29, "0")), .clearRating, "clear rating is preserved")
        t.equal(manager.action(for: event(18, "1", .command)), .setLabel(1), "color shortcut is preserved")
        t.equal(manager.action(for: event(124, "")), .navigateNext(shift: false, command: false), "arrow navigation is preserved")
        t.equal(manager.action(for: event(18, "1", .control)), nil, "assistive control-modified shortcuts pass through")
        t.equal(manager.action(for: event(18, "1", .option)), nil, "option-modified shortcuts pass through")
    }

    private static func ingestValidation(_ t: TestRunner) {
        let source = URL(fileURLWithPath: "/tmp/pcqa-source")
        let primary = URL(fileURLWithPath: "/tmp/pcqa-primary")
        let backup = URL(fileURLWithPath: "/tmp/pcqa-backup")
        func message(_ source: URL?, _ primary: URL?, _ secondary: URL? = nil, backup: Bool = false,
                     template: Bool = false, hasTemplate: Bool = false, rename: Bool = false, name: String = "") -> String? {
            IngestSetupValidation.message(source: source, primary: primary, secondary: secondary, useSecondary: backup,
                                          applyTemplate: template, hasTemplate: hasTemplate, useRename: rename, renameTemplate: name)
        }
        t.check(message(nil, primary) != nil, "source is required")
        t.check(message(source, nil) != nil, "primary destination is required")
        t.check(message(source, primary, backup: true) != nil, "enabled backup requires a folder")
        t.check(message(source, primary, template: true) != nil, "enabled metadata requires a template")
        t.check(message(source, primary, rename: true, name: " \n") != nil, "enabled rename requires a nonblank template")
        t.check(message(source, primary, primary, backup: true) != nil, "identical primary and backup are refused")
        t.check(message(source, source) != nil, "source cannot also be destination")
        t.check(message(source, source.appendingPathComponent("nested")) != nil, "destination cannot live inside recursive source")
        t.equal(message(source, primary), nil, "primary-only import is valid")
        t.equal(message(source, primary, backup, backup: true, template: true, hasTemplate: true, rename: true, name: "{name}_{seq}"), nil,
                "fully configured dual-destination import is valid")
        t.equal(message(source, URL(fileURLWithPath: "/tmp/pcqa-source-other")), nil,
                "similarly prefixed sibling destination is valid")
    }
}
