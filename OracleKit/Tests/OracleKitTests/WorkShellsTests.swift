import XCTest
@testable import OracleKit

/// Which card a herdr pane is drawn on (#88). Worktrees live at <main>/wt/…, so "the pane's cwd starts with the card's
/// path" gave the main checkout every worktree's panes — agents included, drawn as "shell". The rule is the one agents
/// already follow: the DEEPEST work item holding the pane's cwd.
final class WorkShellsTests: XCTestCase {
    private func pane(_ place: String, cwd: String, agent: String? = nil) -> HerdrPaneBox {
        HerdrPaneBox(place: place, paneId: String(place.split(separator: ":").last ?? ""), rect: HerdrRect(x: 0, y: 0, width: 80, height: 24),
                     focused: false, agent: agent, name: nil, status: agent == nil ? "unknown" : "working", cwd: cwd, label: nil)
    }
    private func space(_ id: String, checkout: String?, _ panes: [HerdrPaneBox]) -> HerdrSpace {
        HerdrSpace(place: "laris-co:\(id)", session: "laris-co", workspaceId: id, label: id, number: 1, status: "idle",
                   checkout: checkout, linked: checkout?.contains("/wt/") ?? false, repoRoot: nil, activeTab: "laris-co:\(id):t1",
                   tabs: [HerdrTab(place: "laris-co:\(id):t1", tabId: "\(id):t1", label: "", area: HerdrRect(x: 0, y: 0, width: 80, height: 24),
                                   zoomed: false, panes: panes)])
    }

    func testAPaneIsDrawnOnlyOnTheDeepestCard() {
        let main = "/r/nexus-oracle", wt = "/r/nexus-oracle/wt/beer-nexus-issue45-8oct-thu2026"
        let ls = #"{"worktrees":[{"path":"\#(main)","branch":"main","state":"running"},{"path":"\#(wt)","branch":"beer","state":"open"}]}"#
        let agent = OracleSnapshot.Activity(title: "BeerVadsadu", status: "working", place: "laris-co:w20:p1", cwd: wt)
        let work = WorkParse.items(ls: Data(ls.utf8), locks: [:], activity: [agent], prs: [], localPath: main)
        let spaces = [
            space("w1", checkout: main, [pane("laris-co:w1:p1", cwd: main)]),                          // main's own shell
            space("w20", checkout: wt, [pane("laris-co:w20:p1", cwd: wt, agent: "claude"),             // the agent
                                        pane("laris-co:w20:p2", cwd: wt + "/OracleKit"),                // a shell inside the wt
                                        pane("laris-co:w20:p3", cwd: "/Users/someone")]),               // a shell cd'd away
        ]
        let byPath = Dictionary(uniqueKeysWithValues: work.map { ($0.path, $0) })
        XCTAssertEqual(WorkParse.shells(of: byPath[main]!, work: work, spaces: spaces).map(\.place), ["laris-co:w1:p1"])
        XCTAssertEqual(WorkParse.shells(of: byPath[wt]!, work: work, spaces: spaces).map(\.place), ["laris-co:w20:p2", "laris-co:w20:p3"])
        // the agent is a pane of its worktree (items), never a shell of anyone
        XCTAssertEqual(byPath[wt]!.panes.map(\.place), ["laris-co:w20:p1"])

        // the old Mac rule, kept here as the regression it was: main claimed the worktree's space, agent and all
        let old = spaces.filter { $0.checkout == main || $0.panes.contains { $0.cwd == main || $0.cwd.hasPrefix(main + "/") } }
            .flatMap(\.panes).map(\.place)
        XCTAssertEqual(old, ["laris-co:w1:p1", "laris-co:w20:p1", "laris-co:w20:p2", "laris-co:w20:p3"])
    }

    func testThePhoneReadsTheSameShells() {
        let main = "/r/maeon-craft-oracle", wt = "/r/maeon-craft-oracle/wt/recipes-maeon-craft-issue4-8oct-thu2026"
        let ls = #"{"worktrees":[{"path":"\#(main)","branch":"main","state":"running"},{"path":"\#(wt)","branch":"r","state":"open"}]}"#
        let work = WorkParse.items(ls: Data(ls.utf8), locks: [:], activity: [], prs: [], localPath: main)
        let spaces = [space("w2Z", checkout: wt, [pane("laris-co:w2Z:p1", cwd: wt)])]
        let mainItem = work.first { $0.isMain }!
        XCTAssertTrue(CompanionServer.shells(of: mainItem, work: work, spaces: spaces).isEmpty)
        XCTAssertEqual(CompanionServer.shells(of: work.first { !$0.isMain }!, work: work, spaces: spaces).map(\.place), ["laris-co:w2Z:p1"])
    }
}
