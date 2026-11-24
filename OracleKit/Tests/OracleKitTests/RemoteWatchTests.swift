import XCTest
@testable import OracleKit

/// #137: the hub watches machines over ssh (every session on them), merges herdr's saved machines into the same rows,
/// and hides retired machines and logins.
final class RemoteWatchTests: XCTestCase {
    let white = "nat@white.follow-rankine.ts.net"

    func testSessionListParsesHerdrJSON() {
        // shape of `herdr session list --json` on white, 2026-11-24 (herdr 0.9.5), trimmed
        let out = """
        herdr 0.9.5
        {"sessions":[{"default":true,"name":"default","running":false,"session_dir":"/home/nat/.config/herdr"},{"default":false,"name":"laris-co","running":true},{"default":false,"name":"nsm","running":true},{"default":false,"name":"phonebooth","running":false}]}
        """
        let list = RemoteParse.sessionList(out)
        XCTAssertEqual(list?.map(\.name), ["default", "laris-co", "nsm", "phonebooth"])
        XCTAssertEqual(list?.map(\.running), [false, true, true, false])
        XCTAssertNil(RemoteParse.sessionList("herdr 0.9.5\nbash: herdr: command not found"))
    }

    func testDetailsSplitAgentsAndWorkspacesPerSession() {
        let out = """
        @@agents nsm
        {"id":"cli:agent:list","result":{"agents":[{"agent":"claude","agent_status":"idle","pane_id":"wV:p1","workspace_id":"wV","cwd":"/a"},{"agent":"claude","agent_status":"done","pane_id":"wW:p1","workspace_id":"wW","cwd":"/b"},{"agent":"codex","agent_status":"working","pane_id":"wW:p2","workspace_id":"wW","cwd":"/b"}]}}

        @@spaces nsm
        {"id":"cli:workspace:list","result":{"workspaces":[{"workspace_id":"wV","label":"nsm-oracle","agent_status":"idle","pane_count":1},{"workspace_id":"wW","label":"xiaoer","agent_status":"done","pane_count":2}]}}

        @@agents laris-co
        {"error":{"code":"server_not_running","message":"no server"}}

        @@spaces laris-co
        {"error":{"code":"server_not_running","message":"no server"}}
        """
        let d = RemoteParse.details(out, version: "0.9.5")
        XCTAssertEqual(d["nsm"]?.agents, 3)
        XCTAssertEqual(d["nsm"]?.needsYou, 1)
        XCTAssertEqual(d["nsm"]?.working, 1)
        XCTAssertEqual(d["nsm"]?.version, "0.9.5")
        XCTAssertEqual(d["nsm"]?.workspaces.map(\.label), ["nsm-oracle", "xiaoer"])
        XCTAssertEqual(d["laris-co"]?.running, false)
        XCTAssertNil(d["laris-co"]?.problem)   // stopped between the two calls: off, not a problem
    }

    func testDetailCommandOnlyTakesSafeNames() {
        let c = RemoteParse.detailCommand(["nsm", "x; rm -rf ~", "laris-co"])
        XCTAssertTrue(c.contains("herdr --session nsm agent list"))
        XCTAssertTrue(c.contains("herdr --session laris-co workspace list"))
        XCTAssertFalse(c.contains("rm -rf"))
        XCTAssertFalse(c.contains("server stop"))   // read-only
    }

    func testRetiredMachinesAndLogins() {
        XCTAssertTrue(RemoteParse.isRetired("phd-oracle@black.follow-rankine.ts.net"))
        XCTAssertTrue(RemoteParse.isRetired("nm@white.follow-rankine.ts.net"))
        XCTAssertTrue(RemoteParse.isRetired("god@white"))
        XCTAssertFalse(RemoteParse.isRetired(white))
        XCTAssertFalse(RemoteParse.isRetired("gb300"))
    }

    func testWatchTargetsDedupeAndHideRetired() {
        let saved = [RemoteSession(target: white, session: "nsm", label: "white-nsm", profileId: "ab12"),
                     RemoteSession(target: "phd-oracle@black.follow-rankine.ts.net", session: "phd", profileId: "cd34")]
        let attached = [RemoteSession(target: "gb300", session: "default")]
        let t = RemoteParse.watchTargets(hub: [white, " ", "nm@white.follow-rankine.ts.net", "-oProxyCommand=x"],
                                         saved: saved, attached: attached, showRetired: false)
        XCTAssertEqual(t, [white, "gb300"])
        let all = RemoteParse.watchTargets(hub: [white], saved: saved, attached: attached, showRetired: true)
        XCTAssertEqual(all, [white, "phd-oracle@black.follow-rankine.ts.net", "gb300"])
    }

    func testMergeKeepsOneRowPerSessionWithSavedProfile() {
        let listed = [RemoteSession(target: white, session: "laris-co"), RemoteSession(target: white, session: "nsm")]
        let saved = [RemoteSession(target: white, session: "nsm", label: "white-nsm", profileId: "ab12"),
                     RemoteSession(target: "gb300", session: "default", label: "gb300", profileId: "ef56")]
        let attached = [RemoteSession(target: white, session: "laris-co")]
        let m = RemoteParse.merge(listed: listed, saved: saved, attached: attached)
        XCTAssertEqual(m.map(\.id), [white + "|laris-co", white + "|nsm", "gb300|default"])
        XCTAssertEqual(m[1].profileId, "ab12")
        XCTAssertEqual(m[1].label, "white-nsm")
        XCTAssertNil(m[0].profileId)
    }

    func testMergedSessionsGroupByMachine() {
        let rs = RemoteParse.merge(listed: [RemoteSession(target: white, session: "nsm"), RemoteSession(target: white, session: "play")],
                                   saved: [RemoteSession(target: "gb300", session: "default", profileId: "ef56")], attached: [])
        let g = RemoteParse.byMachine(local: [], remotes: rs, localName: "m5")
        XCTAssertEqual(g.map(\.machine), ["gb300", "white"])
        XCTAssertEqual(g[1].places.map(\.name), ["nsm", "play"])
    }
}
