import XCTest
@testable import OracleKit

/// An oracle's team body: a checkout of another repo whose CLAUDE.local.md imports the oracle's own CLAUDE.md.
/// Its panes are the oracle's, through the one roots list (home, herdr worktrees, bodies) every reader shares.
final class TeamBodyTests: XCTestCase {
    private var dir = ""
    private var home: String { dir + "/alpha-oracle" }
    private var team: String { dir + "/team-desk" }
    private var body: String { team + "/wt/alpha-oracle" }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("teambody-\(UUID().uuidString)").path
        for d in [home, team + "/.git", body, team + "/wt/beta-oracle", team + "/wt/plain"] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        try "gitdir: x".write(toFile: body + "/.git", atomically: true, encoding: .utf8)
        try "# soul\n\n@\(home)/CLAUDE.md\n".write(toFile: body + "/CLAUDE.local.md", atomically: true, encoding: .utf8)
        try "@\(dir)/beta-oracle/CLAUDE.md\n".write(toFile: team + "/wt/beta-oracle/CLAUDE.local.md", atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(atPath: dir) }

    private func ls(_ paths: [String]) -> Data {
        let wts = paths.map { #"{"path":"\#($0)","repo":"team-desk","repoRoot":"\#(team)","branch":"wt/x","state":"running"}"# }
        return Data(#"{"worktrees":[\#(wts.joined(separator: ","))]}"#.utf8)
    }

    func testABodyImportsHome() throws {
        XCTAssertTrue(TeamBody.imports(checkout: body, home: home))
        XCTAssertTrue(TeamBody.imports(checkout: body, home: home + "/"))
        XCTAssertFalse(TeamBody.imports(checkout: team + "/wt/beta-oracle", home: home))      // imports another oracle
        XCTAssertFalse(TeamBody.imports(checkout: team + "/wt/plain", home: home))            // no CLAUDE.local.md
        XCTAssertFalse(TeamBody.imports(checkout: team, home: home))
        XCTAssertFalse(TeamBody.imports(checkout: body, home: dir + "/alpha"))                // a prefix is not home
        // an edit is seen: the cache is keyed by mtime
        try "nothing\n".write(toFile: body + "/CLAUDE.local.md", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: body + "/CLAUDE.local.md")
        XCTAssertFalse(TeamBody.imports(checkout: body, home: home))
    }

    /// A symlinked root (a ghq tree reached through a link) still matches: both sides are compared resolved.
    func testASymlinkedHomeStillMatches() throws {
        let link = dir + "/linked-root"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: dir)
        XCTAssertTrue(TeamBody.imports(checkout: body, home: link + "/alpha-oracle"))          // home through the link
        let other = team + "/wt/other"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try "@\(link)/alpha-oracle/CLAUDE.md\n".write(toFile: other + "/CLAUDE.local.md", atomically: true, encoding: .utf8)
        XCTAssertTrue(TeamBody.imports(checkout: other, home: home))                          // the @ line through the link
        XCTAssertFalse(TeamBody.imports(checkout: other, home: dir + "/beta-oracle"))
    }

    /// Stop's confirm lists the oracle's live panes, a body pane among them; LIVES IN flags a saved agent whose
    /// conversation is already live in a body pane, so Start never opens that body a second time.
    func testLivesInAndStopSeeTheBody() {
        let roots = [home, body]
        // the activity loadActivity keeps (HerdrParse.belongs over roots) is what Stop's confirm names
        let agents = [("s:w1:p1", home), ("s:w9:p1", body), ("s:w8:p1", team + "/wt/beta-oracle")]
        let acts = agents.filter { HerdrParse.belongs(AgentPane(session: "s", paneId: "", name: "", agent: "", status: "", cwd: $0.1, title: ""), roots: roots) }
            .map { OracleSnapshot.Activity(title: "", status: "idle", place: $0.0, cwd: $0.1) }
        XCTAssertEqual(SessionHeader.livePanes(acts, session: "s"), ["s:w1:p1", "s:w9:p1"])
        // a stopped session saved the body's agent; that conversation now runs in a body pane elsewhere
        let saved = #"{"version":1,"workspaces":[{"id":"a","custom_name":"","identity_cwd":"\#(body)","tabs":[{"panes":{"1":{"cwd":"\#(body)","#
            + #""agent_name":"alpha","agent_session":{"agent":"claude","kind":"id","value":"body-conv-1"}}}}]}]}"#
        let live = HerdrPlaces.liveIds(agentList: Data(#"{"result":{"agents":[{"pane_id":"w9:p1","agent_session":{"value":"body-conv-1"}}]}}"#.utf8))
        let withBody = HerdrPlaces.parse(sessionJSON: Data(saved.utf8), roots: roots)
        XCTAssertEqual(withBody.spaces, ["alpha-oracle"])
        XCTAssertEqual(HerdrPlaces.duplicates(withBody.agents, live: live).map(\.sessionId), ["body-conv-1"])
        // home alone does not see that session at all: it would say "stopped" while the body runs
        XCTAssertTrue(HerdrPlaces.parse(sessionJSON: Data(saved.utf8), roots: [home]).spaces.isEmpty)
    }

    func testBodiesComeFromTheWorktreeList() {
        let all = [team, body, team + "/wt/beta-oracle", team + "/wt/plain", home]
        XCTAssertEqual(TeamBody.bodies(ls: ls(all), home: home), [body])
    }

    func testRootsInBelongsAndMine() {
        let roots = [home, "/h/.herdr/worktrees/alpha-oracle", body]
        let p = { (cwd: String) in AgentPane(session: "s", paneId: "p1", name: "", agent: "claude", status: "idle", cwd: cwd, title: "") }
        XCTAssertTrue(HerdrParse.belongs(p(body + "/src"), roots: roots))
        XCTAssertTrue(HerdrParse.belongs(p(home), roots: roots))
        XCTAssertFalse(HerdrParse.belongs(p(team + "/wt/beta-oracle"), roots: roots))
        XCTAssertTrue(HerdrParse.belongs(p("/h/.herdr/worktrees/alpha-oracle/worktree-x"), roots: roots))
        XCTAssertFalse(HerdrParse.belongs(p("/h/.herdr/worktrees/beta-oracle/worktree-x"), roots: roots))     // another repo
        XCTAssertFalse(HerdrParse.belongs(p("/h/.herdr/worktrees/alpha-oracle-2/worktree-x"), roots: roots))  // same-prefix sibling
        XCTAssertFalse(HerdrParse.belongs(p(body), to: home))                                  // home alone misses the body
        let spaces = [space("w1", checkout: body, [pane("s:w1:p1", cwd: body)]),
                      space("w2", checkout: team, [pane("s:w2:p1", cwd: team)])]
        XCTAssertEqual(HerdrSnapshot.mine(spaces, roots: roots).map(\.workspaceId), ["w1"])
        XCTAssertEqual(HerdrSnapshot.mine(spaces, roots: [home]).map(\.workspaceId), [])
    }

    /// A pane working in the body counts 0 without the body roots (the old rule) and 1 with them; its row is a body.
    func testItemsListABodyWithItsPanes() {
        let agent = OracleSnapshot.Activity(title: "work", status: "working", place: "s:w9:p1", cwd: body)
        let data = ls([home, team, body, team + "/wt/beta-oracle"])
        let before = WorkParse.items(ls: data, locks: [:], activity: [agent], prs: [], localPath: home)
        XCTAssertEqual(before.flatMap(\.panes).count, 0)
        let bodies = TeamBody.bodies(ls: data, home: home)
        let after = WorkParse.items(ls: data, locks: [:], activity: [agent], prs: [], localPath: home, bodies: bodies)
        XCTAssertEqual(after.flatMap(\.panes).count, 1)
        XCTAssertEqual(after.map(\.path), [body, home])                                       // working first, team root left out
        let b = after[0]
        XCTAssertTrue(b.isBody); XCTAssertFalse(b.isMain)
        XCTAssertEqual(b.slug, "body · team-desk")
        XCTAssertEqual(b.repoRoot, team)
        XCTAssertNil(b.issue); XCTAssertNil(b.pr)
        // a body's shells come from the same deepest-owner rule
        let spaces = [space("w9", checkout: body, [pane("s:w9:p1", cwd: body, agent: "claude"), pane("s:w9:p2", cwd: body + "/docs")])]
        XCTAssertEqual(WorkParse.shells(of: b, work: after, spaces: spaces).map(\.place), ["s:w9:p2"])
    }

    /// Stop closes only spaces wholly this oracle's: never a room with other agents, never a team's main space.
    func testStopNeverClosesARoomOrTheTeamSpace() {
        let roots = [home, body]
        let spaces = [
            space("w1", checkout: home, [pane("s:w1:p1", cwd: home)]),
            space("w9", checkout: body, [pane("s:w9:p1", cwd: body)], linked: true),
            space("w7", checkout: team, [pane("s:w7:p1", cwd: team)]),                                        // team main
            space("w8", checkout: nil, [pane("s:w8:p1", cwd: body), pane("s:w8:p2", cwd: team + "/wt/beta-oracle")]),   // a room
            space("w5", checkout: body, [pane("s:w5:p1", cwd: body)], session: "other"),
        ]
        XCTAssertEqual(HerdrControl.closable(spaces, session: "s", roots: roots).map(\.workspaceId), ["w9", "w1"])
    }

    private func pane(_ place: String, cwd: String, agent: String? = nil) -> HerdrPaneBox {
        HerdrPaneBox(place: place, paneId: String(place.split(separator: ":").last ?? ""), rect: HerdrRect(x: 0, y: 0, width: 80, height: 24),
                     focused: false, agent: agent, name: nil, status: agent == nil ? "unknown" : "working", cwd: cwd, label: nil)
    }
    private func space(_ id: String, checkout: String?, _ panes: [HerdrPaneBox], linked: Bool = false, session: String = "s") -> HerdrSpace {
        HerdrSpace(place: "\(session):\(id)", session: session, workspaceId: id, label: id, number: 1, status: "idle",
                   checkout: checkout, linked: linked, repoRoot: nil, activeTab: "\(session):\(id):t1",
                   tabs: [HerdrTab(place: "\(session):\(id):t1", tabId: "\(id):t1", label: "", area: HerdrRect(x: 0, y: 0, width: 80, height: 24),
                                   zoomed: false, panes: panes)])
    }
}
