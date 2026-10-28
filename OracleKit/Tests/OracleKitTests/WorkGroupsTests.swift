import XCTest
@testable import OracleKit

/// The Work page grouped by herdr session: each session heads the rows it holds, every worktree once.
final class WorkGroupsTests: XCTestCase {
    private func item(_ path: String, state maw: String, panes: [String] = [], status: String = "idle", resumeId: String? = nil) -> WorkItem {
        WorkItem(path: path, isMain: false, slug: (path as NSString).lastPathComponent, folder: (path as NSString).lastPathComponent,
                 branch: "", born: nil, issue: nil, pr: nil, mawState: maw,
                 panes: panes.map { OracleSnapshot.Activity(title: "", status: status, place: $0, cwd: path) }, resumeId: resumeId)
    }
    private func agent(_ id: String, cwd: String) -> SavedAgent {
        SavedAgent(name: "", agent: "claude", sessionId: id, space: "s", cwd: cwd)
    }

    func testSessionsHeadTheirWorktreesOnce() {
        let live = item("/r/a", state: "running", panes: ["laris-co:w1:p1"], status: "working")
        let loose = item("/r/b", state: "running")                                               // open, no pane in a session
        let byId = item("/r/wt/c", state: "resumable", resumeId: "conv-c")
        let byCwd = item("/r/wt/d", state: "cold")
        let spare = item("/r/wt/e", state: "resumable", resumeId: "conv-e")
        let cold = item("/r/wt/f", state: "cold")
        let places = [
            SessionPlace(session: "laris-co", running: true, savedAt: nil, spaces: ["a"], agents: []),
            SessionPlace(session: "default", running: false, savedAt: nil, spaces: ["c", "d"],
                         agents: [agent("conv-c", cwd: "/elsewhere"), agent("conv-d", cwd: "/r/wt/d/src"), agent("conv-x", cwd: "/tmp")]),
            // a second stopped session saved conv-c too: it is not listed twice
            SessionPlace(session: "old", running: false, savedAt: nil, spaces: ["c"], agents: [agent("conv-c", cwd: "/r/wt/c")]),
            // every saved conversation already live elsewhere: nothing to head
            SessionPlace(session: "gone", running: false, savedAt: nil, spaces: ["e"], agents: [agent("conv-e", cwd: "/r/wt/e")],
                         alreadyLive: [agent("conv-e", cwd: "/r/wt/e")]),
        ]
        let g = WorkGroups.make(work: [live, loose, byId, byCwd, spare, cold], places: places)
        XCTAssertEqual(g.running.map(\.place.session), ["laris-co"])
        XCTAssertEqual(g.running[0].live.map(\.path), ["/r/a"])
        XCTAssertEqual(g.live.map(\.path), ["/r/b"])
        XCTAssertEqual(g.stopped.map(\.place.session), ["default", "old"])
        XCTAssertEqual(g.stopped[0].rows.map(\.path), ["/r/wt/c", "/r/wt/d"])                 // by id, then by folder
        XCTAssertEqual(g.stopped[0].toResume.count, 3)                                        // an unmatched one still resumes
        XCTAssertEqual(g.stopped[1].rows.map(\.path), [])
        XCTAssertEqual(g.resumable.map(\.path), ["/r/wt/e"])
        XCTAssertEqual(g.cold.map(\.path), ["/r/wt/f"])
        let all = g.running.flatMap(\.live) + g.live + g.stopped.flatMap(\.rows) + g.resumable + g.cold
        XCTAssertEqual(all.count, Set(all.map(\.path)).count)                                // no worktree twice
        XCTAssertEqual(all.count, 6)
    }

    /// A conversation saved in a team body reopens under the body's own repo; the rest under home.
    func testResumeReposSplitBodyFromHome() {
        var body = item("/t/team/wt/alpha", state: "resumable", resumeId: "conv-b")
        body.isBody = true; body.repoRoot = "/t/team"
        let wt = item("/r/home/wt/x", state: "resumable")
        let agents = [agent("conv-h", cwd: "/r/home"), agent("conv-b", cwd: "/elsewhere"), agent("conv-w", cwd: "/r/home/wt/x/src")]
        let g = WorkGroups.resumeRepos(agents, work: [body, wt], home: "/r/home")
        XCTAssertEqual(g.map(\.repo), ["/r/home", "/t/team"])
        XCTAssertEqual(g.map { $0.agents.map(\.sessionId) }, [["conv-h", "conv-w"], ["conv-b"]])
    }

    func testLabels() {
        XCTAssertEqual(WorkGroups.resumeLabel(2, into: "laris-co"), "Resume 2 in laris-co")
        XCTAssertEqual(WorkGroups.startLabel("default"), "Start default")
        XCTAssertEqual(WorkGroups.coldLine(13), "13 worktrees with no session to resume · Review cleanup")
        XCTAssertEqual(WorkGroups.coldLine(1), "1 worktree with no session to resume · Review cleanup")
        XCTAssertEqual(WorkItem.State.open.label, "idle")
    }

    func testCleanCommandPlansUnlessGo() {
        XCTAssertEqual(WorkFormat.cleanCommand(["/r/wt/a b"]), "maw herdr clean '/r/wt/a b'")
        XCTAssertEqual(WorkFormat.cleanCommand(["/r/wt/a", "/r/wt/b"], go: true), "maw herdr clean '/r/wt/a' '/r/wt/b' --go")
        XCTAssertEqual(WorkFormat.cleanArgs(["/r/wt/a"], go: false), ["herdr", "clean", "/r/wt/a"])
        XCTAssertEqual(WorkFormat.cleanArgs(["/r/wt/a"], go: true), ["herdr", "clean", "/r/wt/a", "--go"])
    }
}
