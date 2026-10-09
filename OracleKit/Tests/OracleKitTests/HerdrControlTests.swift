import XCTest
@testable import OracleKit

#if os(macOS)
/// The oracle app closes its own panes, stops its sessions and opens resumable worktrees (#116 follow-up).
final class HerdrControlTests: XCTestCase {
    func testAPlaceSplitsIntoSessionAndPane() {
        XCTAssertEqual(HerdrControl.split(place: "laris-co:w22:p1")?.session, "laris-co")
        XCTAssertEqual(HerdrControl.split(place: "laris-co:w22:p1")?.pane, "w22:p1")
        XCTAssertEqual(HerdrControl.split(place: "fleet111:w1:p2")?.pane, "w1:p2")
        XCTAssertNil(HerdrControl.split(place: "w22:p1"))          // no session prefix: refuse rather than guess
    }

    func testStopOracleClosesOnlyItsPanesInThatSession() {
        let acts = [OracleSnapshot.Activity(title: "List email in repo", status: "idle", place: "default:wB3:p1"),
                    OracleSnapshot.Activity(title: "issue #31", status: "idle", place: "default:wB6:p1"),
                    OracleSnapshot.Activity(title: "other session", status: "working", place: "board-lab:w2:p1")]
        XCTAssertEqual(WorkPlaces.livePanes(acts, session: "default"), ["default:wB3:p1", "default:wB6:p1"])
        XCTAssertEqual(WorkPlaces.livePanes(acts, session: "board-lab"), ["board-lab:w2:p1"])
        XCTAssertTrue(WorkPlaces.livePanes(acts, session: "laris-co").isEmpty)              // nothing there: no Stop button
        XCTAssertTrue(WorkPlaces.livePanes(acts, session: "default-2").isEmpty)             // a prefix of a name is not the session
    }

    // herdr 0.9.1 on m5, 2026-10-09: Stop on Transcriber's main pane — the last pane of a space with linked worktrees
    func testHerdrErrorReadsTheWorktreeGroupRefusal() {
        let out = #"{"error":{"code":"confirmation_required","message":"closing this pane would close a worktree group"},"id":"cli:pane:close"}"# + "\n"
        XCTAssertEqual(HerdrControl.herdrError(out)?.code, "confirmation_required")
        XCTAssertEqual(HerdrControl.herdrError(out)?.message, "closing this pane would close a worktree group")
        XCTAssertNil(HerdrControl.herdrError(""))
        XCTAssertNil(HerdrControl.herdrError(#"{"id":"cli:pane:close","result":{}}"#))
    }

    func testAgentGroupIsOnlyAnAgentLeadingTheForeground() {
        func info(group: Int, argv0: String) -> String {
            #"{"id":"cli:pane:process_info","result":{"process_info":{"pane_id":"w18:p1","shell_pid":61268,"foreground_process_group_id":\#(group),"foreground_processes":[{"pid":29886,"argv0":"bun","name":"bun"},{"pid":\#(group),"argv0":"\#(argv0)","name":"2.1.295"}]}}}"#
        }
        XCTAssertEqual(HerdrControl.agentGroup(processInfo: info(group: 28921, argv0: "claude")), 28921)
        XCTAssertEqual(HerdrControl.agentGroup(processInfo: info(group: 4242, argv0: "/opt/homebrew/bin/codex")), 4242)
        XCTAssertNil(HerdrControl.agentGroup(processInfo: info(group: 61268, argv0: "-zsh")))   // the shell itself: never signal it
        XCTAssertNil(HerdrControl.agentGroup(processInfo: info(group: 5151, argv0: "vim")))     // not an agent
        XCTAssertNil(HerdrControl.agentGroup(processInfo: "not json"))
    }

    func testForegroundNameIsNilOnlyForTheIdleShell() {
        func info(group: Int, argv0: String) -> String {
            #"{"result":{"process_info":{"shell_pid":61268,"foreground_process_group_id":\#(group),"foreground_processes":[{"pid":\#(group),"argv0":"\#(argv0)"}]}}}"#
        }
        XCTAssertNil(HerdrControl.foregroundName(processInfo: info(group: 61268, argv0: "-zsh")))           // idle: the space may close
        XCTAssertEqual(HerdrControl.foregroundName(processInfo: info(group: 7001, argv0: "/opt/homebrew/bin/bun")), "bun")   // a server: it stays
        XCTAssertNotNil(HerdrControl.foregroundName(processInfo: "not json"))                              // unknown: never close
    }

    func testStopNoteSaysWhatStopDid() {
        XCTAssertEqual(WorkPlaces.stopNote(session: "default", ended: 1, closed: 2, kept: nil), "Stopped 1 agent · closed 2 spaces in default")
        XCTAssertEqual(WorkPlaces.stopNote(session: "laris-co", ended: 4, closed: 0, kept: "kept open: laris-co:w25:p2 runs bun"),
                       "Stopped 4 agents in laris-co · kept open: laris-co:w25:p2 runs bun")
    }

    func testTicketShAnswerOkIsNil() {
        XCTAssertNil(HerdrControl.outcome(status: 0, json: #"{"ok":true,"live":false,"pane":"wB:p1"}"#, command: "x"))
    }

    func testTicketShErrorCarriesItsFirstFix() {
        let json = #"{"ok":false,"error":"session 0bec504c is open in a claude outside herdr","fix":["claude attach 0bec504c"]}"#
        XCTAssertEqual(HerdrControl.outcome(status: 1, json: json, command: "bash ticket.sh open x"),
                       "session 0bec504c is open in a claude outside herdr — run:  claude attach 0bec504c")
    }

    func testANonJSONFailureFallsBackToTheCommand() {
        XCTAssertEqual(HerdrControl.outcome(status: 2, json: "boom", command: "bash ticket.sh open x"),
                       "ticket.sh exited 2 without saying why — run:  bash ticket.sh open x")
    }
}
#endif
