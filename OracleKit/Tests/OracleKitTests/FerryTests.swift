#if os(macOS)
import XCTest
@testable import OracleKit

/// Send / Bring back (Nat 2026-10-08: "send … go and back", "2 places at a same time but different session id"):
/// the scripts the hub writes out, the far folder a send reports, the machine a session mirrors.
final class FerryTests: XCTestCase {
    func testScriptsCarryTheFlagsFilterAndParse() throws {
        for (name, body) in [("send", Ferry.send), ("back", Ferry.back)] {
            let s = Ferry.script(body)
            XCTAssertFalse(s.contains("FLAGS_AWK"), "\(name): placeholder left in")
            XCTAssertTrue(s.hasPrefix("#!/usr/bin/env bash"), "\(name): the dedent left the shebang indented")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-\(name)-\(UUID().uuidString).sh")
            try s.write(to: url, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: url) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-n", url.path]
            try p.run(); p.waitUntilExit()
            XCTAssertEqual(p.terminationStatus, 0, "\(name): bash -n failed")
        }
    }

    func testFlagsKeepOnlyLaunchFlagsOnce() throws {
        // m5 transcriber after the first bring-back carried its flags twice (2026-10-08, pid 13103)
        let argv = "claude --dangerously-skip-permissions --channels=plugin:discord@claude-plugins-official "
            + "--dangerously-skip-permissions --channels=plugin:discord@claude-plugins-official --model opus "
            + "--resume a912a8cc-0d7d-4522-bb38-bf206f5231e6 --fork-session do the thing"
        let awk = Ferry.flagsAwk.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = Process(); let out = Pipe(); let input = Pipe()
        p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = ["-c", "tr ' ' '\\n' | " + awk]
        p.standardInput = input; p.standardOutput = out
        try p.run()
        input.fileHandleForWriting.write(Data(argv.utf8)); try input.fileHandleForWriting.close()
        p.waitUntilExit()
        XCTAssertEqual(String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                       "--dangerously-skip-permissions --channels=plugin:discord@claude-plugins-official --model opus ")
    }

    func testFarFolderIsReadFromTheLog() {
        let log = "--- nexus-oracle → nat@white (laris-co)\n  lands      …\nFERRY-FAR /opt/Code/github.com/laris-co/nexus-oracle/wt/ferry-from-m5-20261008-2214\n  ✓ done\n"
        XCTAssertEqual(Ferry.far(in: log), "/opt/Code/github.com/laris-co/nexus-oracle/wt/ferry-from-m5-20261008-2214")
        XCTAssertNil(Ferry.far(in: "  ✗ no Claude agent with a saved session in /x\n"))
    }
}
#endif
