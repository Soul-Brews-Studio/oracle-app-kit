import XCTest
@testable import OracleKit

/// The widget snapshot is written off the main thread (#46: a failing write held the main thread ~72 s a refresh).
final class SnapshotWriterTests: XCTestCase {
    func testBackoffDoublesToHalfAnHour() {
        XCTAssertEqual(SnapshotWriter.backoff(1), 60)
        XCTAssertEqual(SnapshotWriter.backoff(2), 120)
        XCTAssertEqual(SnapshotWriter.backoff(5), 960)
        XCTAssertEqual(SnapshotWriter.backoff(6), 1800)
        XCTAssertEqual(SnapshotWriter.backoff(40), 1800)
    }

    func testAReadOnlyFolderFailsWithItsCode() throws {
        let dir = try readOnlyFolder()
        defer { unlock(dir) }
        let why = SnapshotWriter.write(Data("{}".utf8), to: dir.appendingPathComponent("snapshot.json"))
        XCTAssertNotNil(why)
        XCTAssertTrue(why?.hasPrefix(NSCocoaErrorDomain) == true, why ?? "")
        let ok = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: ok) }
        XCTAssertNil(SnapshotWriter.write(Data("{}".utf8), to: ok))
    }

    /// A failing target waits out its back-off; the others are still written on every snapshot.
    func testAFailingTargetIsSkippedUntilItsTime() throws {
        let dir = try readOnlyFolder()
        defer { unlock(dir) }
        let bad = dir.appendingPathComponent("snapshot.json")
        let good = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: good) }
        let w = SnapshotWriter()
        for n in 0..<2 {
            let wrote = expectation(description: "snapshot \(n)")
            w.submit(Data("{\"n\":\(n)}".utf8), then: { wrote.fulfill() }, targets: { [bad, good] })
            wait(for: [wrote], timeout: 5)
            XCTAssertEqual(try String(contentsOf: good, encoding: .utf8), "{\"n\":\(n)}")
            XCTAssertEqual(w.failing[bad]?.count, 1)   // the second snapshot did not try it again
            XCTAssertEqual(w.failing[bad]?.retry.timeIntervalSinceNow ?? 0, 60, accuracy: 5)
            XCTAssertNil(w.failing[good])
        }
    }

    /// `then` runs on the main thread after the newest snapshot is on disk; the caller never waits for the write.
    func testThenRunsOnMainAfterTheNewestWrite() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let w = SnapshotWriter()
        let wrote = expectation(description: "the last snapshot's then")
        for i in 0..<5 {
            var done: (@MainActor @Sendable () -> Void)?
            if i == 4 {
                done = {
                    XCTAssertTrue(Thread.isMainThread)
                    XCTAssertEqual(try? String(contentsOf: file, encoding: .utf8), "{\"n\":4}")
                    wrote.fulfill()
                }
            }
            w.submit(Data("{\"n\":\(i)}".utf8), then: done, targets: { [file] })
        }
        wait(for: [wrote], timeout: 5)
    }

    private func readOnlyFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        return dir
    }

    private func unlock(_ dir: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }
}
