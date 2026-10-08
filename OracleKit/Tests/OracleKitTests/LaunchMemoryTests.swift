import XCTest
@testable import OracleKit

/// How remote agents were started (Nat: "it start with this command, the important thing is …"): read from the
/// machine's process table, kept per folder, quoted safely when Start runs it again.
final class LaunchMemoryTests: XCTestCase {
    func testLaunchesAreReadPerFolderNewestWins() {
        // xiaoer on nm@white, as /proc answered on 2026-10-08 (pid 3358121)
        let out = "3358001\t/opt/Code/github.com/Soul-Brews-Studio/xiaoer-oracle\tclaude --continue \n"
            + "3358121\t/opt/Code/github.com/Soul-Brews-Studio/xiaoer-oracle\tclaude --channels plugin:discord@claude-plugins-official --continue --dangerously-skip-permissions \n"
            + "12\tnot a folder\tx\n"
        let l = RemoteParse.launches(out)
        XCTAssertEqual(l.count, 1)
        XCTAssertEqual(l.first?.command, "claude --channels plugin:discord@claude-plugins-official --continue --dangerously-skip-permissions")
    }

    func testHerdrsPlainResumeGetsTheRememberedFlagsBack() {
        // phd on black, as /proc answered on 2026-10-08; herdr's own resume is plain `claude --resume <id>`
        let phd = AgentLaunch(cwd: "/home/phd-oracle/DustBoy-Phd-Oracle",
                              command: "claude --resume 262dbd0e --dangerously-skip-permissions --model claude-opus-5-5 --channels plugin:discord@claude-plugins-official",
                              seen: Date())
        XCTAssertEqual(phd.flags, ["--dangerously-skip-permissions", "--model", "claude-opus-5-5", "--channels", "plugin:discord@claude-plugins-official"])
        XCTAssertEqual(AgentLaunch.resumedId("claude --resume 7a1c9"), "7a1c9")
        XCTAssertEqual(phd.restoring("claude --resume 7a1c9"),
                       "claude --resume 7a1c9 --dangerously-skip-permissions --model claude-opus-5-5 --channels plugin:discord@claude-plugins-official")
        XCTAssertNil(phd.restoring("claude"), "no conversation named: nothing to keep")
        // xiaoer's --continue is a conversation pick, not a flag
        let xiaoer = AgentLaunch(cwd: "/x", command: "claude --channels plugin:discord@claude-plugins-official --continue --dangerously-skip-permissions", seen: Date())
        XCTAssertEqual(xiaoer.flags, ["--channels", "plugin:discord@claude-plugins-official", "--dangerously-skip-permissions"])
    }

    func testChannelsAreReadInEveryForm() {
        XCTAssertEqual(AgentLaunch.channels(in: "claude --channels plugin:discord@claude-plugins-official --continue"), ["discord"])
        XCTAssertEqual(AgentLaunch.channels(in: "claude --channels plugin:discord@x plugin:telegram@x --resume 1"), ["discord", "telegram"])
        XCTAssertEqual(AgentLaunch.channels(in: "claude --channels=plugin:imessage@x,plugin:fakechat@x"), ["imessage", "fakechat"])
        XCTAssertEqual(AgentLaunch.channels(in: "claude --channels plugin:discord@x --model m --channels plugin:discord@x server:relay"), ["discord", "relay"])
        XCTAssertEqual(AgentLaunch.channels(in: "claude --resume 1 --dangerously-skip-permissions"), [])
    }

    func testParamsSayWhatTheCommandSays() {
        let phd = AgentLaunch(cwd: "/p", command: "claude --resume 262dbd0e --dangerously-skip-permissions --model claude-opus-5-5 --channels plugin:discord@claude-plugins-official", seen: Date())
        XCTAssertEqual(phd.params.map(\.text), ["discord", "opus-5-5", "skip perms", "resume 262d…"])
        let xiaoer = AgentLaunch(cwd: "/x", command: "claude --channels plugin:discord@claude-plugins-official --continue --dangerously-skip-permissions", seen: Date())
        XCTAssertEqual(xiaoer.params.map(\.text), ["discord", "skip perms", "continue"])
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
