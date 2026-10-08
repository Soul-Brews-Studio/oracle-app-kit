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
    func testTheSocketHashIsHerdrs() {
        XCTAssertEqual(RemoteParse.socketHash(target: "phd-oracle@black.follow-rankine.ts.net", session: "phd"), "2636df18a3e9f21e")
        XCTAssertEqual(RemoteParse.socketHash(target: "nat@white.follow-rankine.ts.net", session: "infra-teamexit"), "83d6a3c15cac58aa")
        XCTAssertEqual(RemoteParse.sanitized("user@host:22"), "user-host-22")   // herdr's own test
    }

    func testATraceIsReadBackToItsTarget() {
        let log = """
        2026-10-06T02:55:16.897680Z  INFO herdr::client: connecting to server path=/var/folders/41/x/T/herdr-r-75311-phd-orac-2636df18a3e9f21e.sock
        2026-10-06T04:35:06.592958Z  INFO herdr::client: connecting to server path=/var/folders/41/x/T/herdr-r-16741-phd-orac-2636df18a3e9f21e.sock
        """
        let t = RemoteParse.trace(clientLog: log)
        XCTAssertEqual(t?.prefix, "phd-orac"); XCTAssertEqual(t?.hash, "2636df18a3e9f21e")
        XCTAssertTrue(RemoteParse.left(t!, RemoteSession(target: "phd-oracle@black.follow-rankine.ts.net", session: "phd")))
        XCTAssertFalse(RemoteParse.left(t!, RemoteSession(target: "phd-oracle@black.follow-rankine.ts.net", session: "list")))
    }

    /// A trace nothing remembered: ssh hosts × users × the domains known targets use.
    func testCandidatesFindTheTargetNoOneTyped() {
        let config = """
        Host white white.local
          HostName white.local
          User nat
        Host black-phd-oracle
          HostName black.follow-rankine.ts.net
          User phd-oracle
        Host *
          ServerAliveInterval 30
        """
        let c = RemoteParse.candidates(sshConfig: config, knownTargets: ["phd-oracle@black.follow-rankine.ts.net"])
        XCTAssertTrue(c.contains("nat@white.follow-rankine.ts.net"))
        XCTAssertTrue(c.contains("phd-oracle@black.follow-rankine.ts.net"))
        XCTAssertFalse(c.contains { $0.contains("*") })
        let trace = (prefix: "nat-whit", hash: "83d6a3c15cac58aa")
        XCTAssertEqual(c.map { RemoteSession(target: $0, session: "infra-teamexit") }.first { RemoteParse.left(trace, $0) }?.target,
                       "nat@white.follow-rankine.ts.net")
    }

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

    func testAMachineListsItsSessions() {
        let m = RemoteParse.machine("""
        herdr 0.9.1
        {"sessions":[{"default":true,"name":"default","running":true},{"name":"homekeeper","running":false},{"name":"infra-team","running":true}]}
        herdr-rc=0
        """)
        XCTAssertEqual(m?.version, "0.9.1")
        XCTAssertEqual(m?.sessions.map(\.name), ["default", "homekeeper", "infra-team"])
        XCTAssertEqual(m?.sessions.map(\.running), [true, false, true])
        XCTAssertNil(RemoteParse.machine("herdr-rc=127"), "no herdr there")
    }

    func testTheAgentsOfEachSession() {
        let a = RemoteParse.agents("""
        @@session default
        {"result":{"agents":[{"agent_status":"working"},{"agent_status":"idle"}]}}
        @@session infra-team
        {"result":{"agents":[{"agent_status":"done"}]}}
        """, version: "0.9.1")
        XCTAssertEqual(a["default"]?.agents, 2); XCTAssertEqual(a["default"]?.working, 1)
        XCTAssertEqual(a["infra-team"]?.needsYou, 1); XCTAssertEqual(a["infra-team"]?.version, "0.9.1")
        XCTAssertEqual(RemoteParse.agentsCommand(sessions: ["default", "infra-team"]).components(separatedBy: "@@session").count, 3)
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
