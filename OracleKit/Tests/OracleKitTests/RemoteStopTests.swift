import XCTest
@testable import OracleKit

/// Saved herdr machines on the Network page: `herdr --machine <id>` answers, read back (#100, herdr-machines).
final class RemoteStopTests: XCTestCase {
    func testStatusServerFields() {
        let out = "status: running\nversion: 0.9.1\nendpoint_compatible: yes\nsocket: machine:c0acfe15/infra-teamexit\n"
        XCTAssertEqual(RemoteParse.statusField("status", in: out), "running")
        XCTAssertEqual(RemoteParse.statusField("version", in: out), "0.9.1")
        XCTAssertNil(RemoteParse.statusField("pid", in: out))
    }

    func testSavedMachinesCarryTheirProfileId() {
        let json = #"[{"id":"c0acfe15786dc11998248c59315ff1b8","label":"white","target":"nat@white.example","session":"infra-teamexit","enabled":true,"selected":false},{"id":"off","label":"x","target":"a@b","session":"default","enabled":false}]"#
        let m = RemoteParse.machines(Data(json.utf8))
        XCTAssertEqual(m.map(\.profileId), ["c0acfe15786dc11998248c59315ff1b8"])   // a disabled profile is not listed
        XCTAssertEqual(m.first?.id, "nat@white.example|infra-teamexit")
        XCTAssertEqual(m.first?.label, "white")
    }

    func testWorkspacesAreReadInHerdrsOrder() {
        // black's phd session, as `herdr --machine black workspace list` answered on 2026-10-08
        let json = #"{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[{"workspace_id":"w5","label":"~","agent_status":"unknown","pane_count":1},{"workspace_id":"w8","label":"dustboy-phd-oracle","agent_status":"done","pane_count":1}]}}"#
        let w = RemoteParse.workspaces(json)
        XCTAssertEqual(w.map(\.label), ["~", "dustboy-phd-oracle"])
        XCTAssertEqual(w.map(\.status), ["unknown", "done"])
        XCTAssertTrue(RemoteParse.workspaces("not json").isEmpty)
    }

    func testResumeSplitsAgentsWithASavedSessionFromPlainShells() {
        // m5 records agent_session through its claude hook; white (no integration) records none (#100)
        let m5 = #"{"result":{"agents":[{"agent":"claude","name":"neo","agent_session":{"source":"herdr:claude","kind":"id","value":"8f3a"}},{"agent":"codex","pane_id":"w2:p1"}]}}"#
        let white = #"{"result":{"agents":[{"agent":"claude","name":"a"},{"agent":"claude","name":"b"}]}}"#
        XCTAssertEqual(RemoteParse.resume(agentList: m5)?.resumes, ["claude": 1])
        XCTAssertEqual(RemoteParse.resume(agentList: m5)?.lost, ["w2:p1 (codex)"])
        XCTAssertEqual(RemoteParse.resume(agentList: white)?.resumes, [:])
        XCTAssertEqual(RemoteParse.resume(agentList: white)?.lost, ["a (claude)", "b (claude)"])
        XCTAssertNil(RemoteParse.resume(agentList: #"{"error":{"code":"server_not_running"}}"#))
    }
}
