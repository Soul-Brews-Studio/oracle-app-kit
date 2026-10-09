import XCTest
@testable import OracleKit

/// #116: after a reboot only herdr's `default` session runs; the Work page reads the stopped sessions' session.json to
/// say where the oracle lives, and never resumes a conversation that is already live (measured 2026-10-09: laris-co's
/// saved Neo pane held the same Claude session that was running in `default`).
final class HerdrPlacesTests: XCTestCase {
    let repo = "/opt/Code/github.com/laris-co/neo-oracle"
    let json = #"""
    {"version":1,"workspaces":[
      {"id":"a","custom_name":"neo-oracle-main","identity_cwd":"/opt/Code/github.com/laris-co/neo-oracle",
       "tabs":[{"panes":{"1":{"cwd":"/opt/Code/github.com/laris-co/neo-oracle","agent_name":"neo-recap",
         "agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"0bec504c-aaaa"}}}}]},
      {"id":"b","custom_name":"","identity_cwd":"/Users/x/.herdr/worktrees/neo-oracle/worktree-calm-meadow",
       "tabs":[{"panes":{"1":{"cwd":"/Users/x/.herdr/worktrees/neo-oracle/worktree-calm-meadow"},
                         "2":{"cwd":"/tmp"}}}]},
      {"id":"c","custom_name":"athena-oracle","identity_cwd":"/opt/Code/github.com/laris-co/athena-oracle",
       "tabs":[{"panes":{"1":{"cwd":"/opt/Code/github.com/laris-co/athena-oracle",
         "agent_session":{"agent":"claude","value":"cbe25d87-bbbb"}}}}]}
    ]}
    """#

    func testParseKeepsOnlyTheRepoSpacesAndTheirSavedAgents() {
        let p = HerdrPlaces.parse(sessionJSON: Data(json.utf8), roots: [repo, "/Users/x/.herdr/worktrees/neo-oracle"])
        XCTAssertEqual(p.spaces, ["neo-oracle-main", "worktree-calm-meadow"])   // custom name, else the folder's name
        XCTAssertEqual(p.agents, [SavedAgent(name: "neo-recap", agent: "claude", sessionId: "0bec504c-aaaa", space: "neo-oracle-main",
                                             cwd: "/opt/Code/github.com/laris-co/neo-oracle")])
    }

    func testNilRootsTakesEverySpace() {
        let p = HerdrPlaces.parse(sessionJSON: Data(json.utf8), roots: nil)
        XCTAssertEqual(p.spaces.count, 3)
        XCTAssertEqual(Set(p.agents.map(\.sessionId)), ["0bec504c-aaaa", "cbe25d87-bbbb"])
    }

    func testARootIsNotAPrefixOfASiblingRepo() {
        XCTAssertFalse(HerdrPlaces.belongs("/opt/Code/github.com/laris-co/neo-oracle-2", roots: [repo]))
        XCTAssertTrue(HerdrPlaces.belongs(repo + "/wt/x", roots: [repo]))
    }

    func testASavedAgentAlreadyLiveIsADuplicate() {
        let saved = HerdrPlaces.parse(sessionJSON: Data(json.utf8), roots: nil).agents
        let live = HerdrPlaces.liveIds(agentList: Data(#"{"result":{"agents":[{"pane_id":"wAT:p1","agent_session":{"value":"0bec504c-aaaa"}},{"pane_id":"wB:p1"}]}}"#.utf8))
        XCTAssertEqual(live, ["0bec504c-aaaa"])
        XCTAssertEqual(HerdrPlaces.duplicates(saved, live: live).map(\.name), ["neo-recap"])
    }

    func testOnlySessionsSavedAsTheMacWentDownWereRunning() {
        let boot = Date(timeIntervalSince1970: 1_760_000_000)
        let saved: [String: Date] = [
            "laris-co": boot.addingTimeInterval(-31),          // written as its server exited, 31 s before boot
            "nsm": boot.addingTimeInterval(-10 * 60),          // inside the 15 min window
            "ccdc": boot.addingTimeInterval(-3 * 86_400),      // stopped days ago: stays stopped
            "late": boot.addingTimeInterval(5 * 60)]           // written after boot: not a shutdown write
        XCTAssertEqual(HerdrPlaces.runningAtShutdown(stopped: saved, boot: boot), ["laris-co", "nsm"])
    }

    func testSavedSpacesListsEverySpaceWithItsPanesAndAgents() {
        let rows = HerdrPlaces.savedSpaces(sessionJSON: Data(json.utf8))
        XCTAssertEqual(rows.map(\.label), ["neo-oracle-main", "worktree-calm-meadow", "athena-oracle"])
        XCTAssertEqual(rows.map(\.panes), [1, 2, 1])
        XCTAssertEqual(rows[0].agents.map(\.name), ["neo-recap"])
        XCTAssertTrue(rows[1].agents.isEmpty)                         // comes back as plain shells
        XCTAssertEqual(rows[2].cwd, "/opt/Code/github.com/laris-co/athena-oracle")
    }

    func testResumeBringsBackOnlyTheAgentsNotLiveAndHidesOnceAllRun() {
        let a = SavedAgent(name: "", agent: "claude", sessionId: "a912a8cc", space: "transcriber-oracle", cwd: "/r/t")
        let b = SavedAgent(name: "", agent: "claude", sessionId: "76134b27", space: "queue-backend", cwd: "/r/t/wt/q")
        var stopped = SessionPlace(session: "laris-co", running: false, savedAt: nil, spaces: ["t", "q"], agents: [a, b])
        XCTAssertEqual(HerdrPlaces.toResume(stopped), [a, b])
        stopped.alreadyLive = [a]
        XCTAssertEqual(HerdrPlaces.toResume(stopped), [b])
        stopped.alreadyLive = [a, b]
        XCTAssertTrue(HerdrPlaces.toResume(stopped).isEmpty)                     // all running again: no button
        let running = SessionPlace(session: "default", running: true, savedAt: nil, spaces: ["t"], agents: [a])
        XCTAssertTrue(HerdrPlaces.toResume(running).isEmpty)                     // a running session never offers Resume
        XCTAssertEqual(HerdrPlaces.resumeTarget([stopped, running]), "default")
        XCTAssertEqual(HerdrPlaces.resumeTarget([stopped]), "default")
        let lab = SessionPlace(session: "board-lab", running: true, savedAt: nil, spaces: [], agents: [])
        XCTAssertEqual(HerdrPlaces.resumeTarget([lab, running]), "board-lab")
    }

    func testClearingAgentsBlanksOnlyThoseRecordsAndKeepsTheRest() throws {
        let out = try XCTUnwrap(HerdrPlaces.clearingAgents(sessionJSON: Data(json.utf8), ids: ["0bec504c-aaaa"]))
        let rows = HerdrPlaces.savedSpaces(sessionJSON: out)
        XCTAssertEqual(rows.map(\.label), ["neo-oracle-main", "worktree-calm-meadow", "athena-oracle"])   // every space kept
        XCTAssertEqual(rows.map(\.panes), [1, 2, 1])                                                     // every pane kept
        XCTAssertTrue(rows[0].agents.isEmpty)                                    // comes back as a shell
        XCTAssertEqual(rows[2].agents.map(\.sessionId), ["cbe25d87-bbbb"])       // another agent untouched
        XCTAssertNil(HerdrPlaces.clearingAgents(sessionJSON: Data("not json".utf8), ids: ["x"]))
    }

    func testStoppedSinceSaysTheTimeTodayAndTheDayBefore() {
        let now = Date()
        XCTAssertTrue(HerdrPlaces.stoppedSince(now.addingTimeInterval(-60), now: now).hasPrefix("stopped since "))
        XCTAssertEqual(HerdrPlaces.stoppedSince(nil), "stopped")
    }
}
