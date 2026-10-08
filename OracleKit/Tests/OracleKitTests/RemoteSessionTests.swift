import XCTest
@testable import OracleKit

/// Remote herdr sessions (Nat, 2026-10-08): the command line, herdr's socket name and hash, the traces m5 holds.
final class RemoteSessionTests: XCTestCase {
    func testTheCommandLineNamesTheRemote() {
        let r = RemoteParse.remote(of: "herdr --remote phd-oracle@black.follow-rankine.ts.net --session phd")
        XCTAssertEqual(r?.target, "phd-oracle@black.follow-rankine.ts.net")
        XCTAssertEqual(r?.session, "phd")
        XCTAssertEqual(r?.shortTarget, "phd-oracle@black")
        XCTAssertEqual(r?.command, "herdr --remote phd-oracle@black.follow-rankine.ts.net --session phd")
        XCTAssertEqual(RemoteParse.remote(of: "/Users/x/.local/bin/herdr --remote white")?.session, "default")
        XCTAssertNil(RemoteParse.remote(of: "herdr --session phd remote-client-bridge"), "the far side's bridge is not an attach")
        XCTAssertNil(RemoteParse.remote(of: "ssh white herdr --remote x"), "only herdr's own command line")
        XCTAssertNil(RemoteParse.remote(of: "herdr --remote --session phd"))
    }

    /// herdr's short_socket_hash, against the two traces on m5 (~/.config/herdr/sessions/*/herdr-client.log).
    func testAProbeReadsAgentsOrAStoppedServer() {
        let running = RemoteParse.probe("""
        herdr 0.9.3
        {"id":"cli:agent:list","result":{"agents":[{"agent_status":"working"},{"agent_status":"done"},{"agent_status":"idle"}]}}
        herdr-rc=0
        """)
        XCTAssertEqual(running, RemoteState(running: true, agents: 3, working: 1, needsYou: 1, version: "0.9.3", checked: running.checked))
        let stopped = RemoteParse.probe("""
        herdr 0.9.1
        {"id":"cli:agent:list","error":{"code":"server_not_running","message":"no herdr server is running"}}
        herdr-rc=1
        """)
        XCTAssertFalse(stopped.running); XCTAssertNil(stopped.problem)
        XCTAssertNotNil(RemoteParse.probe("herdr-rc=127").problem, "no herdr there")
    }

    func testOnlySafeTargetsReachAShell() {
        XCTAssertTrue(RemoteSession(target: "phd-oracle@black.follow-rankine.ts.net", session: "phd").isSafe)
        XCTAssertFalse(RemoteSession(target: "-oProxyCommand=evil", session: "phd").isSafe)
        XCTAssertFalse(RemoteSession(target: "white", session: "phd; rm -rf ~").isSafe)
        XCTAssertFalse(RemoteSession(target: "white $(id)", session: "x").isSafe)
    }

    func testMachinesAreSavedRemotes() {
        let json = #"[{"id":"m1","label":"Build","target":"you@box","session":"agents","enabled":true,"selected":false},"# +
                   #"{"id":"m2","label":"Off","target":"x@y","session":"default","enabled":false,"selected":false}]"#
        let m = RemoteParse.machines(Data(json.utf8))
        XCTAssertEqual(m.map(\.id), ["you@box|agents"])
        XCTAssertEqual(m.first?.label, "Build")
    }
}

/// Remote sessions grouped by machine (Nat: "if we have many machines, group, show machine").
final class RemoteMachineTests: XCTestCase {
    func testAMachineIsItsHostAndItsUser() {
        let r = RemoteSession(target: "phd-oracle@black.follow-rankine.ts.net", session: "phd")
        XCTAssertEqual(r.host, "black"); XCTAssertEqual(r.user, "phd-oracle")
        XCTAssertEqual(RemoteSession(target: "white.local", session: "x").host, "white")
        XCTAssertNil(RemoteSession(target: "white", session: "x").user)
    }

    func testGroupsAreMachinesWithRunningSessionsFirst() {
        let rs = [RemoteSession(target: "nat@white.follow-rankine.ts.net", session: "infra-teamexit"),
                  RemoteSession(target: "phd-oracle@black.follow-rankine.ts.net", session: "phd"),
                  RemoteSession(target: "nat@white.follow-rankine.ts.net", session: "default"),
                  RemoteSession(target: "nm@white.local", session: "default")]
        let off: Set<String> = ["nat@white.follow-rankine.ts.net|default"]
        let g = RemoteParse.groups(rs, running: { !off.contains($0.id) })
        XCTAssertEqual(g.map(\.host), ["black", "white"])
        XCTAssertEqual(g[1].sessions.map(\.session), ["default", "infra-teamexit", "default"])
        XCTAssertEqual(g[1].sessions.last?.target, "nat@white.follow-rankine.ts.net", "the stopped one last")
    }
}
