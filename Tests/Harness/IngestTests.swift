import Foundation
import Ingest
import Catalog
import Sidecar

/// The module that had no tests at all — and the one that copies files off a card.
enum IngestSuite {

    static func run(_ t: TestRunner) async throws {
        t.suite("Ingest — duplicate destination names rejected (2.5)")
        try await duplicateNames(t)

        t.suite("Ingest — both destinations receive files (2.6)")
        try await dualDestination(t)

        t.suite("Ingest — secondary repaired independently of primary (2.6)")
        try await secondaryRepair(t)

        t.suite("Ingest — sidecars and templates")
        try await sidecarsAndTemplates(t)

        t.suite("Ingest — discovery filters")
        try await discoveryFilters(t)

        t.suite("Ingest — cancellation (4.13)")
        try await cancellation(t)
    }

    // MARK: - Fixtures

    @discardableResult
    private static func makeCard(_ count: Int, ext: String = "CR2") throws -> URL {
        let dir = try TempDir.make("card")
        for i in 1...count {
            let name = String(format: "IMG_%04d.%@", i, ext)
            try Data(String(repeating: "x", count: 64).utf8)
                .write(to: dir.appendingPathComponent(name))
        }
        return dir
    }

    private static func contents(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    // MARK: -

    private static func duplicateNames(_ t: TestRunner) async throws {
        let card = try makeCard(5); defer { TempDir.cleanup(card) }
        let dest = try TempDir.make("dest"); defer { TempDir.cleanup(dest) }

        // A template with no sequence token: every file maps onto one name.
        let job = IngestJob(sourceURL: card,
                            primaryDestination: dest,
                            renameTemplate: "wedding_{date}")

        do {
            _ = try await IngestManager().run(job: job) { _ in }
            t.fail("expected a duplicate-name error, but the ingest ran")
        } catch let error as IngestError {
            if case .duplicateDestinationNames(_, let count) = error {
                t.equal(count, 5, "refuses up front, naming how many files collide")
                let message = error.errorDescription ?? ""
                t.check(message.contains("Sequence"), "error tells the user which token to add")
            } else {
                t.fail("wrong IngestError case: \(error)")
            }
        }

        // Nothing should have been copied — this used to copy 1 and report 4 "skipped".
        t.equal(contents(dest).count, 0, "no partial copy performed before refusing")

        // With a sequence token it proceeds.
        let ok = IngestJob(sourceURL: card,
                           primaryDestination: dest,
                           renameTemplate: "wedding_{Sequence(0001)}")
        let result = try await IngestManager().run(job: ok) { _ in }
        t.equal(result.copiedFiles.count, 5, "all five copied once the template is unambiguous")
        t.equal(contents(dest).count, 5, "five distinct files on disk")
    }

    private static func dualDestination(_ t: TestRunner) async throws {
        let card = try makeCard(4); defer { TempDir.cleanup(card) }
        let primary = try TempDir.make("primary"); defer { TempDir.cleanup(primary) }
        let backup = try TempDir.make("backup"); defer { TempDir.cleanup(backup) }

        let job = IngestJob(sourceURL: card, primaryDestination: primary, secondaryDestination: backup)
        let result = try await IngestManager().run(job: job) { _ in }

        t.equal(result.destinationReports.count, 2, "one report per destination")
        t.equal(result.destinationReports[0].copied.count, 4, "primary received all files")
        t.equal(result.destinationReports[1].copied.count, 4, "backup received all files")
        t.equal(contents(primary), contents(backup), "primary and backup hold identical file sets")
        t.equal(result.failedFiles.count, 0, "no failures")
    }

    /// The backup-integrity bug: a file present on primary used to make the loop `continue`,
    /// so the secondary never got it and re-running could never repair the backup.
    private static func secondaryRepair(_ t: TestRunner) async throws {
        let card = try makeCard(3); defer { TempDir.cleanup(card) }
        let primary = try TempDir.make("primary"); defer { TempDir.cleanup(primary) }
        let backup = try TempDir.make("backup"); defer { TempDir.cleanup(backup) }

        // Simulate a completed primary import with no backup (or a backup that died).
        let firstPass = IngestJob(sourceURL: card, primaryDestination: primary)
        _ = try await IngestManager().run(job: firstPass) { _ in }
        t.equal(contents(primary).count, 3, "primary populated by the first pass")
        t.equal(contents(backup).count, 0, "backup starts empty")

        // Re-run WITH the secondary attached — this must repair the backup.
        let repair = IngestJob(sourceURL: card, primaryDestination: primary, secondaryDestination: backup)
        let result = try await IngestManager().run(job: repair) { _ in }

        t.equal(result.destinationReports[0].skipped.count, 3, "primary correctly reports 3 already present")
        t.equal(result.destinationReports[1].copied.count, 3, "backup receives all 3 despite primary being complete")
        t.equal(contents(backup).count, 3, "backup is now repaired on disk")
        t.equal(contents(primary), contents(backup), "destinations back in sync")
    }

    private static func sidecarsAndTemplates(_ t: TestRunner) async throws {
        let card = try TempDir.make("card"); defer { TempDir.cleanup(card) }
        let primary = try TempDir.make("primary"); defer { TempDir.cleanup(primary) }
        let backup = try TempDir.make("backup"); defer { TempDir.cleanup(backup) }

        let image = card.appendingPathComponent("IMG_0001.CR2")
        try Data("raw".utf8).write(to: image)
        try SidecarManager().write(PhotoMetadata(rating: 4, label: .red),
                                   to: card.appendingPathComponent("IMG_0001.xmp"))

        let template = MetadataTemplate(name: "Shoot", headline: "Cup Final",
                                        creator: "Braveen Kumar", copyright: "© KCI")
        let job = IngestJob(sourceURL: card,
                            primaryDestination: primary,
                            secondaryDestination: backup,
                            metadataTemplate: template)
        _ = try await IngestManager().run(job: job) { _ in }

        for (label, dest) in [("primary", primary), ("backup", backup)] {
            let sidecar = dest.appendingPathComponent("IMG_0001.xmp")
            t.check(sidecar.exists, "\(label): sidecar carried across")
            let meta = try SidecarManager().read(from: sidecar)
            t.equal(meta.rating, 4, "\(label): existing rating preserved through ingest")
            t.equal(meta.headline, "Cup Final", "\(label): template headline applied")
            t.equal(meta.creator, "Braveen Kumar", "\(label): template creator applied")
        }
    }

    private static func discoveryFilters(_ t: TestRunner) async throws {
        let card = try TempDir.make("card"); defer { TempDir.cleanup(card) }
        let dest = try TempDir.make("dest"); defer { TempDir.cleanup(dest) }

        try Data("raw".utf8).write(to: card.appendingPathComponent("IMG_0001.CR2"))
        try Data("jpg".utf8).write(to: card.appendingPathComponent("IMG_0002.JPG"))
        try Data("heic".utf8).write(to: card.appendingPathComponent("IMG_0003.HEIC"))
        try Data("notes".utf8).write(to: card.appendingPathComponent("readme.txt"))
        // A directory that looks like media — must not be treated as a file.
        try FileManager.default.createDirectory(at: card.appendingPathComponent("bogus.jpg"),
                                                withIntermediateDirectories: true)

        let result = try await IngestManager().run(
            job: IngestJob(sourceURL: card, primaryDestination: dest)
        ) { _ in }

        t.equal(result.copiedFiles.count, 3, "copies the three media files")
        t.check(!contents(dest).contains("readme.txt"), "non-media file ignored")
        t.check(!contents(dest).contains("bogus.jpg"), "directory named like an image ignored")
        t.check(contents(dest).contains("IMG_0003.HEIC"), "HEIC recognized as media")
    }

    private static func cancellation(_ t: TestRunner) async throws {
        let card = try makeCard(60); defer { TempDir.cleanup(card) }
        let dest = try TempDir.make("dest"); defer { TempDir.cleanup(dest) }

        let job = IngestJob(sourceURL: card, primaryDestination: dest)
        let manager = IngestManager()

        let task = Task { () -> IngestResult in
            try await manager.run(job: job) { _ in }
        }
        // Cancel almost immediately; the run must observe it and stop.
        task.cancel()

        do {
            let result = try await task.value
            t.check(result.wasCancelled || result.copiedFiles.count < 60,
                    "cancellation observed (copied \(result.copiedFiles.count)/60)")
        } catch is CancellationError {
            t.check(true, "cancellation surfaced as CancellationError")
        }

        t.check(contents(dest).count < 60, "stopped before copying the whole card")
    }
}
