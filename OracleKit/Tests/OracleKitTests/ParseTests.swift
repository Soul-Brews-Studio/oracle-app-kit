import XCTest
@testable import OracleKit

final class ParseTests: XCTestCase {
    func testAgentsAndBelongs() {
        let json = #"{"result":{"agents":[{"pane_id":"w22:p1","name":"neo-oracle","agent":"claude","agent_status":"working","cwd":"/r/neo-oracle"},{"pane_id":"w9:p1","agent":"claude","agent_status":"idle","cwd":"/r/neo-oracle-x"},{"pane_id":"w3:p2","agent":"codex","agent_status":"idle","cwd":"/r/neo-oracle/wt/a"}]}}"#
        let panes = HerdrParse.agents(json: Data(json.utf8), session: "laris-co")
        XCTAssertEqual(panes.count, 3)
        let mine = panes.filter { HerdrParse.belongs($0, to: "/r/neo-oracle") }
        XCTAssertEqual(mine.map(\.paneId), ["w22:p1", "w3:p2"])   // a sibling dir with the same prefix is not ours
    }
    func testRunningSessions() {
        let t = "name status directory socket\ndefault running /a /a.sock\nold stopped /b /b.sock\nlaris-co running /c /c.sock\n"
        XCTAssertEqual(HerdrParse.runningSessions(table: t), ["default", "laris-co"])
    }
    func testGHBothShapes() {
        let cli = #"[{"number":7,"title":"x","author":{"login":"nazt"},"updatedAt":"2026-10-07T01:02:03Z","url":"https://g/7","isDraft":true}]"#
        let rest = #"[{"number":8,"title":"y","user":{"login":"bot"},"updated_at":"2026-10-07T01:02:03Z","html_url":"https://g/8","draft":false}]"#
        XCTAssertEqual(GHParse.items(json: Data(cli.utf8)).first?.author, "nazt")
        XCTAssertEqual(GHParse.items(json: Data(cli.utf8)).first?.isDraft, true)
        XCTAssertEqual(GHParse.items(json: Data(rest.utf8)).first?.author, "bot")
    }
}

final class MawParseTests: XCTestCase {
    func testTreeShape() {
        let ls = #"{"workspaces":[{"session":"laris-co","id":"w22","label":"neo-oracle","panes":4,"status":"working","checkout":"/r/neo"}],"worktrees":[{"path":"/r/neo","branch":"main","linked":false,"state":"running","agents":1},{"path":"/r/neo/wt/a","branch":"a","linked":true,"state":"cold","agents":0},{"path":"/r/neo-other","branch":"x","linked":false,"state":"running","agents":3}]}"#
        let ag = #"{"agents":[{"session":"laris-co","pane":"w22:p1","agent":"claude","name":"neo","status":"working","tabLabel":"neo"},{"session":"default","pane":"w22:p9","agent":"codex","status":"idle"}]}"#
        let rows = MawParse.rows(ls: Data(ls.utf8), agents: Data(ag.utf8), localPath: "/r/neo")
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 0])          // checkout, its space, its pane, then the worktree
        XCTAssertEqual(rows.last?.glyph, "└─")
        XCTAssertFalse(rows.contains { $0.title.contains("codex") })   // same pane id in another session is not ours
        XCTAssertFalse(rows.contains { $0.id.contains("neo-other") })  // sibling repo with the same prefix is not ours
    }
}
