import XCTest
@testable import OracleKit

/// The Issues page and /herdr-ticket's one-shot mode meet in two places: the words the page puts in the message box,
/// and the worktree name and lock the skill writes, which must flip the card to "in a worktree".
final class PickUpTests: XCTestCase {
    func testActionsFollowTheWorktree() {
        // stateful first, the one-shot is the option; once a worktree names the issue, open its session
        XCTAssertEqual(PickUp.actions(inWorktree: false).map(\.action), [.agent, .oneshot])
        XCTAssertEqual(PickUp.actions(inWorktree: false).first?.label, "Pick up")
        XCTAssertEqual(PickUp.actions(inWorktree: true).map(\.action), [.open])
    }

    func testArgumentsRunTheTicketScript() {
        XCTAssertEqual(PickUp.arguments(.agent, issue: 4, repo: "/r/maeon-craft-oracle").dropFirst(),
                       ["pick", "4", "--repo", "/r/maeon-craft-oracle", "--json"])
        XCTAssertEqual(PickUp.arguments(.oneshot, issue: 4, repo: "/r/m").dropFirst(), ["pick", "4", "--oneshot", "--repo", "/r/m", "--json"])
        XCTAssertEqual(PickUp.arguments(.open, issue: 7, repo: "/r/m").dropFirst(), ["open", "7", "--repo", "/r/m", "--json"])
        XCTAssertTrue(PickUp.arguments(.agent, issue: 4, repo: "/r/m")[0].hasSuffix("/.claude/skills/herdr-ticket/ticket.sh"))
        XCTAssertEqual(PickUp.command(.oneshot, issue: 4), "ticket.sh pick 4 --oneshot")
    }

    func testOutcomeReadsTheScriptsJSON() {
        // the lines ticket.sh printed in the 2026-10-08 runs
        XCTAssertEqual(PickUp.outcome(status: 0, json: #"{"ok":true,"issue":153,"worktree":"/r/wt/x","pane":"w2X:p1","session":"377275b4","mode":"agent","started":true}"#),
                       .started(pane: "w2X:p1"))
        XCTAssertEqual(PickUp.outcome(status: 0, json: #"{"ok":true,"existing":true,"issue":4,"worktree":"/r/wt/x","session":"u","pane":""}"#), .existing)
        XCTAssertEqual(PickUp.outcome(status: 1, json: #"{"ok":false,"error":"cannot read issue #99999 in o/r","fix":["gh issue view 99999 -R o/r"]}"#),
                       .failed("cannot read issue #99999 in o/r\ngh issue view 99999 -R o/r"))
        if case .failed(let why) = PickUp.outcome(status: 2, json: "") { XCTAssertTrue(why.contains("exited 2")) } else { XCTFail("no JSON must fail") }
    }

    func testOneShotWorktreeNamesItsIssue() {
        // what `oneshot.sh pick` cuts: wt/<slug>-<owner>-issue<N>-<day>
        let f = WorkParse.parseFolder("recipes-full-editor-maeon-craft-issue4-8oct-thu2026", oracle: "maeon-craft")
        XCTAssertEqual(f.slug, "recipes-full-editor")
        XCTAssertEqual(f.issue, 4)
        XCTAssertNotNil(f.born)
        // a repo that is not an oracle keeps its whole basename as the owner
        let kit = WorkParse.parseFolder("pickup-oneshot-oracle-app-kit-issue81-8oct-thu2026", oracle: "oracle-app-kit")
        XCTAssertEqual(kit.slug, "pickup-oneshot")
        XCTAssertEqual(kit.issue, 81)
    }

    func testOneShotLockCarriesIssueAndSession() {
        // herdr|who|when|<slug>|#N|claude:<uuid> — the 6th field is extra and must not hide #N
        let l = WorkParse.parseLock("herdr|beta@m5|2026-10-08T13:30:39+07:00|docs-app-census-mac|#150|claude:4bf8b259-f7f3-4189-b45d-a922bc42eaa5")
        XCTAssertEqual(l.slug, "docs-app-census-mac")
        XCTAssertEqual(l.issue, 150)
        XCTAssertNotNil(l.born)
        // the old /herdr-ticket lock wrote issue-N there, which never named an issue
        XCTAssertNil(WorkParse.parseLock("herdr|beta@m5|2026-10-08T13:30:39+07:00|issue-150").issue)
    }

    func testPickedUpIssueLeavesNext() {
        let ls = #"{"worktrees":[{"path":"/r/maeon-craft-oracle","branch":"main","state":"running"},{"path":"/r/maeon-craft-oracle/wt/recipes-full-editor-maeon-craft-issue4-8oct-thu2026","branch":"recipes-full-editor-maeon-craft-issue4-8oct-thu2026","state":"resumable","resume":{"provider":"claude","id":"4bf8b259-f7f3-4189-b45d-a922bc42eaa5"}}]}"#
        let work = WorkParse.items(ls: Data(ls.utf8), locks: [:], activity: [], prs: [], localPath: "/r/maeon-craft-oracle")
        XCTAssertEqual(work.compactMap(\.issue), [4])
        XCTAssertEqual(work.first { $0.issue == 4 }?.resumeCommand,
                       "cd '/r/maeon-craft-oracle/wt/recipes-full-editor-maeon-craft-issue4-8oct-thu2026' && claude --resume 4bf8b259-f7f3-4189-b45d-a922bc42eaa5")
        let issues = [4, 5].map { GHItem(number: $0, title: "t\($0)", author: "nazt", updatedAt: nil, url: nil, isDraft: false, branch: nil, closes: []) }
        XCTAssertEqual(WorkParse.unstarted(issues: issues, prs: [], work: work).map(\.issue.number), [5])
    }
}
