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

final class HumanAskTests: XCTestCase {
    func testFilters() {
        XCTAssertNil(OracleStore.humanAsk("\n\n<pasted_content id=\"d1\">\nPANE w22:p7 widget-titles\n** BUILD"))
        XCTAssertNil(OracleStore.humanAsk("[from Pulse, laris-co:wA:p1, for Nat] Heads-up"))
        XCTAssertEqual(OracleStore.humanAsk("❯ check again cc-chat-ui (Tauri)"), "check again cc-chat-ui (Tauri)")
        XCTAssertEqual(OracleStore.humanAsk("<command-message>impeccable</command-message>\n<command-name>/impeccable</command-name>\n<command-args>styling do /oracle-prism</command-args>"),
                       "/impeccable styling do /oracle-prism")
        XCTAssertEqual(OracleStore.humanAsk("merge all to main"), "merge all to main")
        XCTAssertNil(OracleStore.humanAsk("Another Claude session sent a message:\n<agent-message>…"))
        XCTAssertNil(OracleStore.humanAsk("Base directory for this skill: /Users/me/.claude/skills/impeccable\n\nThis skill…"))
    }
}

final class PrettifyTests: XCTestCase {
    func testStamps() {
        XCTAssertEqual(OracleStore.prettify("2026-10-07_042947_unread-test.txt"), "unread test")
        XCTAssertEqual(OracleStore.prettify("2026-10-05_13-47_fido-key-blocked-on-hardware.md"), "fido key blocked on hardware")
        XCTAssertEqual(OracleStore.prettify("2026-09-30_0834_maw-cli-neo-fleet-restart.md"), "maw cli neo fleet restart")
    }
}

final class WorkParseTests: XCTestCase {
    func testFolderNames() {
        let new = WorkParse.parseFolder("heartrate-ble-nexus-issue11-29sep-tue2026", oracle: "nexus")
        XCTAssertEqual(new.slug, "heartrate-ble"); XCTAssertEqual(new.issue, 11)
        XCTAssertEqual(new.born.map { Calendar(identifier: .gregorian).component(.day, from: $0) }, 29)
        XCTAssertEqual(WorkParse.parseFolder("neo-voice-bot-19sep-sat2026", oracle: "neo").slug, "voice-bot")
        let lead = WorkParse.parseFolder("issue-3-research-lancedb-nexus-24sep-thu2026", oracle: "nexus")
        XCTAssertEqual(lead.slug, "research-lancedb"); XCTAssertEqual(lead.issue, 3)
        XCTAssertEqual(WorkParse.parseFolder("codex-buddy", oracle: "nexus").slug, "codex-buddy")
    }
    func testLocks() {
        let porcelain = "worktree /r/wt/a\nHEAD x\nlocked herdr|beta@m5|2026-09-29T12:24:26+07:00|heartrate-ble|#11|herdr-send\n\nworktree /r/wt/b\n"
        let locks = WorkParse.lockReasons(porcelain)
        XCTAssertEqual(locks.count, 1)
        let l = WorkParse.parseLock(locks["/r/wt/a"]!)
        XCTAssertEqual(l.issue, 11); XCTAssertNotNil(l.born)
        XCTAssertNil(WorkParse.parseLock("herdr|beta@m5|2026-09-14T12:15|retro-locked, created before lock convention").born)
    }
    func testPanesGoToTheDeepestWorktreeAndPRsByBranch() {
        let ls = #"{"worktrees":[{"path":"/c/neo-oracle","branch":"main","state":"running"},{"path":"/c/neo-oracle/wt/x-neo-1oct-wed2026","branch":"x-neo-1oct-wed2026","state":"open"},{"path":"/c/other","state":"running"}]}"#
        let act = [OracleSnapshot.Activity(title: "fix it", status: "working", place: "s:w1:p1", cwd: "/c/neo-oracle/wt/x-neo-1oct-wed2026/src"),
                   OracleSnapshot.Activity(title: "plan", status: "blocked", place: "s:w2:p1", cwd: "/c/neo-oracle")]
        let pr = GHItem(number: 7, title: "x", author: "nazt", updatedAt: nil, url: nil, isDraft: false, branch: "x-neo-1oct-wed2026")
        let items = WorkParse.items(ls: Data(ls.utf8), locks: [:], activity: act, prs: [pr], localPath: "/c/neo-oracle")
        XCTAssertEqual(items.map(\.slug), ["neo-oracle", "x"])                     // needs-you (main, blocked) before working
        XCTAssertEqual(items[0].state, .needsYou); XCTAssertEqual(items[1].state, .working)
        XCTAssertEqual(items[1].panes.map(\.title), ["fix it"]); XCTAssertEqual(items[1].pr?.number, 7)
    }
}

final class WorkLinkTests: XCTestCase {
    func testNextIssuesAndTwins() {
        let pr = GHItem(number: 7, title: "report", author: "copilot", updatedAt: nil, url: nil, isDraft: false,
                        branch: "copilot/x", closes: [6])
        let issues = [6, 8].map { GHItem(number: $0, title: "i\($0)", author: "", updatedAt: nil, url: nil, isDraft: false) }
        let ls = #"{"worktrees":[{"path":"/c/nexus-oracle/wt/influxdb3-s3-nexus-28sep-mon2026","branch":"b","state":"resumable","resume":{"provider":"claude","id":"1358"}}]}"#
        let locks = ["/c/nexus-oracle/wt/influxdb3-s3-nexus-28sep-mon2026": "herdr|beta@m5|2026-09-28T05:45:11+07:00|influxdb3-s3|#8"]
        let work = WorkParse.items(ls: Data(ls.utf8), locks: locks, activity: [], prs: [pr], localPath: "/c/nexus-oracle")
        XCTAssertEqual(work.first?.issue, 8)
        XCTAssertEqual(work.first?.resumeCommand, "cd '/c/nexus-oracle/wt/influxdb3-s3-nexus-28sep-mon2026' && claude --resume 1358")
        let next = WorkParse.unstarted(issues: issues, prs: [pr], work: work)
        XCTAssertEqual(next.map(\.id), [6]); XCTAssertEqual(next.first?.pr?.number, 7)
        let a = OracleSnapshot.Activity(title: "x", status: "working", place: "laris-co:w22:pA", session: "d4e8")
        let b = OracleSnapshot.Activity(title: "x", status: "idle", place: "default:wD:p4", session: "d4e8")
        XCTAssertEqual(WorkParse.twins([b, a]), ["default:wD:p4": "laris-co:w22:pA"])
    }
}

final class HubParseTests: XCTestCase {
    func testNamesSessionsOraclesAndRegistry() {
        XCTAssertEqual(HubParse.displayName("neo-oracle"), "Neo")
        XCTAssertEqual(HubParse.displayName("DustBoy-Phd-Oracle"), "DustBoy-Phd")
        XCTAssertEqual(HubParse.displayName("pulse"), "Pulse")
        let s = HubParse.sessions(Data(#"{"sessions":[{"name":"laris-co","running":true},{"name":"phd","running":false}]}"#.utf8))
        XCTAssertEqual(s.map(\.name), ["laris-co", "phd"]); XCTAssertEqual(s.map(\.running), [true, false])
        let ls = #"{"workspaces":[{"session":"laris-co","id":"w28","label":"nexus-oracle","number":13,"status":"done","repo":"nexus-oracle","panes":1,"agents":1}],"worktrees":[{"path":"/c/nexus-oracle","repo":"nexus-oracle","repoRoot":"/c/nexus-oracle","linked":false,"state":"running","resume":{"provider":"claude","id":"16bed"}},{"path":"/c/nexus-oracle/wt/a","repo":"nexus-oracle","linked":true,"state":"resumable"},{"path":"/c/haos-oracle","repo":"haos-oracle","linked":false,"state":"cold"}]}"#
        let p = HubParse.parse(ls: Data(ls.utf8))
        XCTAssertEqual(p.oracles.map(\.repo), ["nexus-oracle", "haos-oracle"])          // needs-you first
        XCTAssertEqual(p.oracles[0].status, "done"); XCTAssertEqual(p.oracles[0].resumable, 1)
        XCTAssertEqual(p.oracles[0].resume, "cd '/c/nexus-oracle' && claude --resume 16bed")
        XCTAssertEqual(p.oracles[1].status, "cold"); XCTAssertEqual(p.spaces.first?.spaceId, "w28")
        let reg = HubParse.registry(Data(#"{"oracles":[{"name":"--help","repo":"--help-oracle"},{"name":"pulse","repo":"pulse","local_path":"/c/pulse"},{"name":"pulse","repo":"pulse"}]}"#.utf8))
        XCTAssertEqual(reg.map(\.repo), ["pulse"]); XCTAssertEqual(reg.first?.path, "/c/pulse")
    }
}

final class WezTermTests: XCTestCase {
    func testHerdrClientSession() {
        XCTAssertEqual(WezTerm.herdrSession(of: "herdr --session laris-co"), "laris-co")
        XCTAssertEqual(WezTerm.herdrSession(of: "/Users/me/.local/bin/herdr"), "default")
        XCTAssertNil(WezTerm.herdrSession(of: "herdr --remote nat@white --session infra-team"))
        XCTAssertNil(WezTerm.herdrSession(of: "herdr --session ccdc agent list"))   // a one-shot CLI call, not a client
        XCTAssertNil(WezTerm.herdrSession(of: "-zsh"))
    }
}

final class HeyCommandTests: XCTestCase {
    func testHeyCommandSplitsSessionAndQuotes() {
        XCTAssertEqual(OracleStore.heyCommand(place: "laris-co:w22:p2", message: "it's done"),
                       "maw herdr hey --session laris-co w22:p2 'it'\\''s done'")
    }

    func testIndexSlugFromCheckout() {
        XCTAssertEqual(GHIndex.slug(fromCheckout: "/opt/Code/github.com/laris-co/neo-oracle"), "laris-co/neo-oracle")
        XCTAssertEqual(GHIndex.slug(fromCheckout: "/Users/me/Code/github.com/Soul-Brews-Studio/oracle-app-kit/wt/x"), "Soul-Brews-Studio/oracle-app-kit")
        XCTAssertNil(GHIndex.slug(fromCheckout: "/tmp/somewhere"))
    }
}
