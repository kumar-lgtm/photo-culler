import XCTest
import Foundation
@testable import Sidecar

final class SidecarTests: XCTestCase {
    func testReadWriteRoundTrip() throws {
        let manager = SidecarManager()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xmp")
        
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        let initialMetadata = PhotoMetadata(rating: 4, label: .red)
        try manager.write(initialMetadata, to: tempURL)
        
        let readMetadata = try manager.read(from: tempURL)
        
        XCTAssertEqual(initialMetadata, readMetadata)
    }

    func testPreserveUnknownFields() throws {
        let manager = SidecarManager()
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".xmp")
        
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        // Write initial file with extra data
        let initialXML = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="PhotoCuller 1.0">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
              <xmp:Rating>3</xmp:Rating>
              <xmp:Label>Blue</xmp:Label>
              <photoshop:ColorMode>3</photoshop:ColorMode>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try initialXML.write(to: tempURL, atomically: true, encoding: .utf8)
        
        // Read it
        let readMetadata = try manager.read(from: tempURL)
        XCTAssertEqual(readMetadata.rating, 3)
        XCTAssertEqual(readMetadata.label, .blue)
        
        // Update it
        let newMetadata = PhotoMetadata(rating: 5, label: .green)
        try manager.write(newMetadata, to: tempURL)
        
        // Read it back
        let readMetadata2 = try manager.read(from: tempURL)
        XCTAssertEqual(readMetadata2.rating, 5)
        XCTAssertEqual(readMetadata2.label, .green)
        
        // Ensure unknown field is preserved
        let updatedXML = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(updatedXML.contains("<photoshop:ColorMode>3</photoshop:ColorMode>"))
    }
}