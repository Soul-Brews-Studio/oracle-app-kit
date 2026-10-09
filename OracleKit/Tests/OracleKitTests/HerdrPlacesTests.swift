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
        XCTAssertEqual(p.agents, [SavedAgent(name: "neo-recap", agent: "claude", sessionId: "0bec504c-aaaa", space: "neo-oracle-main")])
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

    /// A place as `load` builds it from the fixture: parsed, plus (stopped only) the saved agents live elsewhere.
    private func place(running: Bool = false, roots: [String]?, live: Set<String>) -> SessionPlace {
        let p = HerdrPlaces.parse(sessionJSON: Data(json.utf8), roots: roots)
        var place = SessionPlace(session: "laris-co", running: running, savedAt: nil,
                                 spaces: p.spaces, agents: p.agents)
        if !running { place.alreadyLive = HerdrPlaces.duplicates(p.agents, live: live) }
        return place
    }

    func testAStoppedSessionWhoseAgentsAreAllLiveElsewhereHasNothingToRestore() {
        // laris-co as the Work page showed it: neo-recap saved, and that conversation already running in `default`
        let p = place(roots: [repo, "/Users/x/.herdr/worktrees/neo-oracle"], live: ["0bec504c-aaaa"])
        XCTAssertEqual(p.agents.map(\.name), ["neo-recap"])
        XCTAssertEqual(p.alreadyLive, p.agents)
        XCTAssertTrue(HerdrPlaces.nothingToRestore(p))
    }

    func testAStoppedSessionKeepsItsRowWhileASavedAgentIsNotLiveElsewhere() {
        let p = place(roots: nil, live: ["0bec504c-aaaa"])   // neo-recap is live elsewhere, the athena agent is not
        XCTAssertEqual(p.agents.count, 2)
        XCTAssertEqual(p.alreadyLive.map(\.name), ["neo-recap"])   // the warning still names the one that is
        XCTAssertFalse(HerdrPlaces.nothingToRestore(p))
    }

    func testAStoppedSessionWithNoSavedAgentsKeepsItsRow() {
        let p = place(roots: ["/Users/x/.herdr/worktrees/neo-oracle"], live: ["0bec504c-aaaa"])
        XCTAssertEqual(p.spaces, ["worktree-calm-meadow"])
        XCTAssertTrue(p.agents.isEmpty)   // Start brings its spaces back as plain shells
        XCTAssertFalse(HerdrPlaces.nothingToRestore(p))
    }

    func testARunningSessionIsNeverDropped() {
        var p = place(running: true, roots: [repo, "/Users/x/.herdr/worktrees/neo-oracle"], live: ["0bec504c-aaaa"])
        XCTAssertTrue(p.alreadyLive.isEmpty)   // only a stopped session is checked for duplicates
        XCTAssertFalse(HerdrPlaces.nothingToRestore(p))
        p.alreadyLive = p.agents   // every agent live elsewhere, and it still runs
        XCTAssertFalse(HerdrPlaces.nothingToRestore(p))
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

    func testStoppedSinceSaysTheTimeTodayAndTheDayBefore() {
        let now = Date()
        XCTAssertTrue(HerdrPlaces.stoppedSince(now.addingTimeInterval(-60), now: now).hasPrefix("stopped since "))
        XCTAssertEqual(HerdrPlaces.stoppedSince(nil), "stopped")
    }
}
