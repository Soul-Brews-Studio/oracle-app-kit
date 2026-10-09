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
