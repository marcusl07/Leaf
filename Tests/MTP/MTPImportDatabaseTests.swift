import GRDB
import XCTest
@testable import Leaf

final class MTPImportDatabaseTests: XCTestCase {
    func testDownloadedClippingsUseRealParserPersistenceAndReconnectDeduplication() throws {
        let queue = try DatabaseQueue()
        try DatabaseSchema.initialize(in: queue)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LeafMTPDatabaseTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ImportCoordinator(
            parseClippings: ClippingsParser.parseClippings(fileURL:),
            upsertBook: { $0.id }, insertHighlightIfNew: { _ in }, totalHighlightCount: { 0 },
            persistImport: { books, highlights in
                try queue.write { database in
                    try ImportRepository.persistImport(books: books, highlights: highlights, database: database)
                }
            }
        )
        let service = MTPImportService(root: root, download: { _, file in
            try """
            Test Book (Test Author)
            - Your Highlight on Location 10-11 | Added on Thursday, October 15, 2026 9:00:00 AM

            A synthetic highlight used only by the test suite.
            ==========

            """.write(to: file, atomically: true, encoding: .utf8)
        }, importFile: coordinator.importFile(at:))

        let first = service.sync("1-9981-3")
        XCTAssertNil(first.error)
        XCTAssertEqual(first.newHighlightCount, 1)
        XCTAssertEqual(first.librarySnapshot?.totalHighlightCount, 1)
        let second = service.sync("1-9981-3")
        XCTAssertNil(second.error)
        XCTAssertEqual(second.newHighlightCount, 0)
        XCTAssertEqual(second.librarySnapshot?.totalHighlightCount, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}
