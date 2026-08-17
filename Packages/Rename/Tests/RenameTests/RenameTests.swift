import XCTest
import Foundation
@testable import Rename

final class RenameTests: XCTestCase {
    func testRenameFormatting() {
        let formatter = RenameFormatter()
        
        let url = URL(fileURLWithPath: "/path/to/IMG_1234.CR2")
        let context = RenameContext(
            originalURL: url,
            sequence: 42,
            rating: "5★",
            color: "Red",
            camera: "Canon",
            lens: "50mm",
            iso: "800"
        )
        
        // Simple sequence and name
        let res1 = formatter.format(template: "Wedding-{seq:000}-{name:lower}", context: context)
        // extension is auto-appended
        XCTAssertEqual(res1, "Wedding-042-img_1234.cr2")
        
        // Explicit extension
        let res2 = formatter.format(template: "New_{seq}_{ext:upper}", context: context)
        XCTAssertEqual(res2, "New_0042_CR2")
        
        // Metadata
        let res3 = formatter.format(template: "{name}_{rating}_{color}", context: context)
        XCTAssertEqual(res3, "IMG_1234_5★_Red.cr2")
    }

    func testBatchRenamerCollisions() {
        let renamer = BatchRenamer()
        
        let url1 = URL(fileURLWithPath: "/path/to/A.jpg")
        let url2 = URL(fileURLWithPath: "/path/to/B.jpg")
        
        let ctx1 = RenameContext(originalURL: url1, sequence: 1)
        let ctx2 = RenameContext(originalURL: url2, sequence: 1) // deliberate collision
        
        let result = renamer.preview(items: [ctx1, ctx2], template: "SameName")
        
        XCTAssertEqual(result.operations.count, 2)
        XCTAssertEqual(result.collisions.count, 1) // url2 collides with url1's new name
        XCTAssertEqual(result.collisions.first, url2)
    }
}
