#if os(macOS)
import XCTest
@testable import OracleKit

final class SidebarByMachineTests: XCTestCase {
    func testThisMacFirstThenHostsSessionsByName() {
        let local = [HubSession(name: "laris-co", running: true), HubSession(name: "default", running: true)]
        let remotes = [RemoteSession(target: "nat@white", session: "laris-co"), RemoteSession(target: "phd@black", session: "phd"),
                       RemoteSession(target: "nat@white", session: "infra-teamexit")]
        let g = RemoteParse.byMachine(local: local, remotes: remotes, localName: "m5")
        XCTAssertEqual(g.map(\.machine), ["m5", "black", "white"])
        XCTAssertEqual(g[0].places.map(\.name), ["default", "laris-co"])
        XCTAssertEqual(g[2].places.map(\.name), ["infra-teamexit", "laris-co"])
    }
}
#endif
