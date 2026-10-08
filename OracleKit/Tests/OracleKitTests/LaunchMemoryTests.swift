import XCTest
@testable import OracleKit

/// How remote agents were started (Nat: "it start with this command, the important thing is …"): read from the
/// machine's process table, kept per folder, quoted safely when Start runs it again.
final class LaunchMemoryTests: XCTestCase {
    func testLaunchesAreReadPerFolderNewestWins() {
        // xiaoer on nm@white, as /proc answered on 2026-10-08 (pid 3358121)
        let out = "/opt/Code/github.com/Soul-Brews-Studio/xiaoer-oracle\tclaude --continue \n"
            + "/opt/Code/github.com/Soul-Brews-Studio/xiaoer-oracle\tclaude --channels plugin:discord@claude-plugins-official --continue --dangerously-skip-permissions \n"
            + "\tnot a folder\n"
        let l = RemoteParse.launches(out)
        XCTAssertEqual(l.count, 1)
        XCTAssertEqual(l.first?.command, "claude --channels plugin:discord@claude-plugins-official --continue --dangerously-skip-permissions")
    }

    func testACommandCrossesTheShellAsOneWord() {
        XCTAssertEqual(RemoteParse.shellQuote("claude --channels plugin:discord@x --continue"), "'claude --channels plugin:discord@x --continue'")
        XCTAssertEqual(RemoteParse.shellQuote("echo it's"), "'echo it'\\''s'")
    }

    func testAgentsArePlacedByWorkspaceAndFolder() {
        let json = #"{"result":{"agents":[{"agent":"claude","agent_status":"idle","cwd":"/opt/Code/github.com/Soul-Brews-Studio/xiaoer-oracle","pane_id":"w7:p1","workspace_id":"w7"}]}}"#
        let st = RemoteParse.probe(json)
        XCTAssertEqual(st.agentList, [RemoteAgent(workspace: "w7", pane: "w7:p1", cwd: "/opt/Code/github.com/Soul-Brews-Studio/xiaoer-oracle", kind: "claude")])
    }
}
