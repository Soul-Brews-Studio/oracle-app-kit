import XCTest
@testable import OracleKit

/// The relic rules SessionHistory follows (agent-relic-v3 shapes.ts, roles.ts, tiers.ts, repo.ts), on small
/// transcripts written here: whose a session is, which records are prose, what host text is dropped.
final class SessionHistoryTests: XCTestCase {
    func testRepoKeyFromCwd() {
        XCTAssertEqual(SessionHistory.repoKey("/opt/Code/github.com/laris-co/pulse"), "laris-co/pulse")
        XCTAssertEqual(SessionHistory.repoKey("/opt/Code/github.com/laris-co/pulse/wt/discord-keishu-files-pulse-issue285"), "laris-co/pulse")
        XCTAssertEqual(SessionHistory.repoKey("/Users/me/Code/github.com/laris-co/neo-oracle.wt-5-freelance/src"), "laris-co/neo-oracle")
        XCTAssertEqual(SessionHistory.repoKey("/Users/me/.herdr/worktrees/neo-oracle/worktree-silver"), nil)
        XCTAssertEqual(SessionHistory.repoKey("/tmp"), nil)
    }

    func testRoleByBlockNotEnvelope() {
        var m = SessionHistory.Mark(size: 0, mtime: 0, offset: 0, ours: false, session: "", cwd: "", title: "")
        let toolResult: [String: Any] = ["type": "user", "cwd": "/opt/Code/github.com/laris-co/pulse",
                                         "message": ["role": "user", "content": [["type": "tool_result", "content": "ok"]]]]
        XCTAssertEqual(SessionHistory.claude(toolResult, &m).role, "tool_result")
        XCTAssertEqual(m.cwd, "/opt/Code/github.com/laris-co/pulse")
        let thinking: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": [["type": "thinking", "thinking": "hm"]]]]
        XCTAssertEqual(SessionHistory.claude(thinking, &m).role, "thinking")
        let said: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "Done — the index is built."]]]]
        let l = SessionHistory.claude(said, &m)
        XCTAssertEqual(l.role, "assistant"); XCTAssertEqual(l.text, "Done — the index is built.")
        let meta: [String: Any] = ["type": "user", "isMeta": true, "message": ["role": "user", "content": "Caveat: …"]]
        XCTAssertTrue(SessionHistory.claude(meta, &m).host)
    }

    func testHostTextIsDropped() {
        XCTAssertEqual(SessionHistory.clean("fix the bug<system-reminder>be careful</system-reminder>"), "fix the bug")
        XCTAssertEqual(SessionHistory.clean("<command-name>/recap</command-name>\n<command-message>recap</command-message>\n<command-args>--now</command-args>"), "/recap\n\n --now")
        XCTAssertEqual(SessionHistory.clean("<local-command-stdout>noise</local-command-stdout>"), "")
        XCTAssertTrue(SessionHistory.isHostPreamble("# AGENTS.md instructions for /x"))
        XCTAssertFalse(SessionHistory.isHostPreamble("build the app"))
    }

    func testCodexDeveloperAndPreambleAreHost() {
        var m = SessionHistory.Mark(size: 0, mtime: 0, offset: 0, ours: false, session: "", cwd: "", title: "")
        _ = SessionHistory.codex(["type": "session_meta", "payload": ["id": "abc", "cwd": "/opt/Code/github.com/laris-co/pulse"]], &m)
        XCTAssertEqual(m.session, "abc"); XCTAssertEqual(m.cwd, "/opt/Code/github.com/laris-co/pulse")
        let dev = SessionHistory.codex(["type": "response_item", "payload": ["type": "message", "role": "developer", "content": [["text": "rules"]]]], &m)
        XCTAssertTrue(dev.host)
        let pre = SessionHistory.codex(["type": "response_item", "payload": ["type": "message", "role": "user",
                                                                            "content": [["text": "<environment_context>cwd</environment_context>"]]]], &m)
        XCTAssertTrue(pre.host)
        let ask = SessionHistory.codex(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["text": "index the vault please"]]]], &m)
        XCTAssertEqual(ask.role, "user"); XCTAssertFalse(ask.host)
        XCTAssertEqual(SessionHistory.codex(["type": "response_item", "payload": ["type": "function_call"]], &m).role, "tool_use")
    }

    func testEmbedTextIsThePieceAlone() {
        XCTAssertEqual(SessionHistory.embedText("the ledger keeps byte offsets"), "title: none | text: the ledger keeps byte offsets")
        XCTAssertEqual(SessionHistory.minChars, 40)
    }

    func testChunksKeepWordsWhole() {
        let text = String(repeating: "word ", count: 800)   // 4,000 chars
        let parts = SessionHistory.chunks(text, size: 1600)
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 1600 && !$0.hasSuffix("wor") })
        XCTAssertEqual(SessionHistory.chunks("short").count, 1)
    }

    /// A whole transcript on disk: only this repo's prose survives, tools are counted, the appended tail is read once.
    func testReadFileAndAppend() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("s.jsonl")
        func line(_ o: [String: Any]) -> String { String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)! + "\n" }
        let cwd = "/opt/Code/github.com/laris-co/pulse"
        var body = line(["type": "user", "cwd": cwd, "sessionId": "s1", "timestamp": "2026-10-07T01:00:00Z",
                         "message": ["role": "user", "content": "please index the whole history of pulse, every session"]])
        body += line(["type": "assistant", "cwd": cwd, "message": ["role": "assistant", "content": [["type": "tool_use", "name": "Bash", "input": [:]]]]])
        body += line(["type": "user", "cwd": cwd, "message": ["role": "user", "content": [["type": "tool_result", "content": "x"]]]])
        body += line(["type": "assistant", "cwd": cwd, "timestamp": "2026-10-07T01:01:00Z",
                      "message": ["role": "assistant", "content": [["type": "text", "text": "Indexed 3,585 texts of pulse's history, embedded on the GPU."]]]])
        try body.write(to: f, atomically: true, encoding: .utf8)
        let size = (try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
        let ref = SessionHistory.FileRef(path: f.path, kind: "claude", source: "test", size: size, mtime: 1)
        let r = SessionHistory.read(ref, repo: "laris-co/pulse", mark: nil)
        XCTAssertEqual(r.said.map(\.role), ["user", "assistant"])
        XCTAssertEqual(r.counts.toolUse, 1); XCTAssertEqual(r.counts.toolResult, 1)
        XCTAssertTrue(r.mark.ours); XCTAssertEqual(r.mark.session, "s1"); XCTAssertEqual(r.mark.offset, size)
        // someone else's repo: nothing
        XCTAssertTrue(SessionHistory.read(ref, repo: "laris-co/neo-oracle", mark: nil).said.isEmpty)
        // append one line: only it is read
        let more = line(["type": "user", "cwd": cwd, "message": ["role": "user", "content": "and now search it by meaning, from the Memory page"]])
        let h = try FileHandle(forWritingTo: f); try h.seekToEnd(); try h.write(contentsOf: Data(more.utf8)); try h.close()
        let size2 = (try FileManager.default.attributesOfItem(atPath: f.path)[.size] as? Int) ?? 0
        let r2 = SessionHistory.read(SessionHistory.FileRef(path: f.path, kind: "claude", source: "test", size: size2, mtime: 2),
                                     repo: "laris-co/pulse", mark: r.mark)
        XCTAssertEqual(r2.said.map(\.text), ["and now search it by meaning, from the Memory page"])
        XCTAssertEqual(r2.mark.offset, size2)
    }
}
