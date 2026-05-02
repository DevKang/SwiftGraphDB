import XCTest
import Foundation

/// Verifies the DocC catalog structure shipped with each product. Symbol-level docs are
/// enforced by `Scripts/check-doc-coverage.sh`; this suite covers the catalog files and
/// articles that DocC needs to render landing pages.
final class DocCStructureTests: XCTestCase {

    private var repoRoot: URL {
        // Tests run from the package root; URL(fileURLWithPath:) lets us walk the source tree.
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func assertExists(_ relativePath: String, file: StaticString = #file, line: UInt = #line) {
        let url = repoRoot.appendingPathComponent(relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "missing required documentation file: \(relativePath)",
                      file: file, line: line)
    }

    func testCoreDocCCatalogIsPresent() {
        assertExists("Sources/SwiftGraphDB/SwiftGraphDB.docc/SwiftGraphDB.md")
        assertExists("Sources/SwiftGraphDB/SwiftGraphDB.docc/ModelingYourData.md")
        assertExists("Sources/SwiftGraphDB/SwiftGraphDB.docc/Querying.md")
        assertExists("Sources/SwiftGraphDB/SwiftGraphDB.docc/ConcurrencyModel.md")
        assertExists("Sources/SwiftGraphDB/SwiftGraphDB.docc/SyncProtocol.md")
    }

    func testCloudKitDocCCatalogIsPresent() {
        assertExists("Sources/SwiftGraphDBCloudKit/SwiftGraphDBCloudKit.docc/SwiftGraphDBCloudKit.md")
        assertExists("Sources/SwiftGraphDBCloudKit/SwiftGraphDBCloudKit.docc/EnablingCloudKitSync.md")
        assertExists("Sources/SwiftGraphDBCloudKit/SwiftGraphDBCloudKit.docc/ConflictResolution.md")
        assertExists("Sources/SwiftGraphDBCloudKit/SwiftGraphDBCloudKit.docc/OfflineBehaviour.md")
    }

    func testLandingPagesLinkToProjectDocs() throws {
        let coreLanding = repoRoot.appendingPathComponent("Sources/SwiftGraphDB/SwiftGraphDB.docc/SwiftGraphDB.md")
        let core = try String(contentsOf: coreLanding, encoding: .utf8)
        XCTAssertTrue(core.contains("README.md"), "core landing should link the README")
        XCTAssertTrue(core.contains("SPEC.md"), "core landing should link the SPEC")
        XCTAssertTrue(core.contains("CHANGELOG.md"), "core landing should link the CHANGELOG")
        XCTAssertTrue(core.contains("CONTRIBUTING.md"), "core landing should link CONTRIBUTING")

        let ckLanding = repoRoot.appendingPathComponent("Sources/SwiftGraphDBCloudKit/SwiftGraphDBCloudKit.docc/SwiftGraphDBCloudKit.md")
        let ck = try String(contentsOf: ckLanding, encoding: .utf8)
        XCTAssertTrue(ck.contains("README.md"))
        XCTAssertTrue(ck.contains("SPEC.md"))
        XCTAssertTrue(ck.contains("CHANGELOG.md"))
        XCTAssertTrue(ck.contains("CONTRIBUTING.md"))
    }
}
