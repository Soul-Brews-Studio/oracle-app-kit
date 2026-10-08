import XCTest
@testable import OracleKit

/// Stopping remote sessions from the Network page (#100): the command, what failed, and the resume check.
final class RemoteStopTests: XCTestCase {
    func testStopCommandStopsEachSessionAndReportsItsStatus() {
        let cmd = RemoteParse.stopCommand(sessions: ["default", "infra-team"])
        XCTAssertTrue(cmd.hasPrefix(RemoteParse.remotePath))
        XCTAssertTrue(cmd.contains("echo @@stop default; herdr session stop default >/dev/null 2>&1; echo rc=$?"))
        XCTAssertTrue(cmd.contains("echo @@stop infra-team; herdr session stop infra-team >/dev/null 2>&1; echo rc=$?"))
    }

    func testFailuresAreTheSessionsWithoutAZeroStatus() {
        let out = "@@stop default\nrc=0\n@@stop infra-team\nrc=1\n"
        XCTAssertEqual(RemoteParse.stopFailures(out, asked: ["default", "infra-team"]), ["infra-team"])
        XCTAssertEqual(RemoteParse.stopFailures("", asked: ["default"]), ["default"])   // ssh said nothing: not stopped
    }

    func testResumeSplitsAgentsWithASavedSessionFromPlainShells() {
        // m5 records agent_session through its claude hook; white (no integration) records none (#100)
        let m5 = #"{"result":{"agents":[{"agent":"claude","name":"neo","agent_session":{"source":"herdr:claude","kind":"id","value":"8f3a"}},{"agent":"codex","pane_id":"w2:p1"}]}}"#
        let white = #"{"result":{"agents":[{"agent":"claude","name":"a"},{"agent":"claude","name":"b"}]}}"#
        let r = RemoteParse.resume("@@session default\n\(m5)\n@@session infra-team\n\(white)\n")
        XCTAssertEqual(r["default"]?.resumes, ["claude": 1])
        XCTAssertEqual(r["default"]?.lost, ["w2:p1 (codex)"])
        XCTAssertEqual(r["infra-team"]?.resumes, [:])
        XCTAssertEqual(r["infra-team"]?.lost, ["a (claude)", "b (claude)"])
        XCTAssertNil(RemoteParse.resume(agentList: #"{"error":{"code":"server_not_running"}}"#))
    }
}
