import XCTest
@testable import Catalog

final class CatalogTests: XCTestCase {
    func testScannerPairsRAWAndJPEGByBaseName() async throws {
        let folder = try makeTemporaryFolder()
        try Data("raw".utf8).write(to: folder.appendingPathComponent("DSCF0001.RAF"))
        try Data("jpg".utf8).write(to: folder.appendingPathComponent("DSCF0001.JPG"))
        try Data("jpg".utf8).write(to: folder.appendingPathComponent("DSCF0002.JPG"))

        let items = try await CatalogScanner().scan(folderURL: folder)

        let paired = try XCTUnwrap(items.first { $0.url.lastPathComponent == "DSCF0001.RAF" })
        XCTAssertTrue(paired.isRAW)
        XCTAssertTrue(paired.isRAWJPEGPair)
        XCTAssertEqual(paired.pairedURL?.lastPathComponent, "DSCF0001.JPG")

        let standaloneJPEG = try XCTUnwrap(items.first { $0.url.lastPathComponent == "DSCF0002.JPG" })
        XCTAssertTrue(standaloneJPEG.isJPEG)
        XCTAssertNil(standaloneJPEG.pairedURL)
    }

    func testMediaTypeClassificationIncludesCommonCanonRawAndVideo() {
        let raw = PhotoItem(url: URL(fileURLWithPath: "/tmp/IMG_0001.CR3"), modificationDate: Date(), fileSize: 10)
        let video = PhotoItem(url: URL(fileURLWithPath: "/tmp/clip.MP4"), modificationDate: Date(), fileSize: 10)

        XCTAssertTrue(raw.isRAW)
        XCTAssertFalse(raw.isJPEG)
        XCTAssertTrue(video.isVideo)
    }

    func testScannerIncludesUnknownFileExtensionsForUserFiltering() async throws {
        let folder = try makeTemporaryFolder()
        try Data("custom raw".utf8).write(to: folder.appendingPathComponent("frame.CUSTOMRAW"))

        let items = try await CatalogScanner().scan(folderURL: folder)

        XCTAssertEqual(items.map(\.fileExtension), ["customraw"])
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
