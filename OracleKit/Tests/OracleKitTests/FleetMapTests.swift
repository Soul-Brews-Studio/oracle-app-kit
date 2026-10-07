import XCTest
@testable import OracleKit

/// The fleet map (#37): which oracle a point belongs to, and a region named after the oracle that holds it.
final class FleetMapTests: XCTestCase {
    func testOracleOfIndex() {
        XCTAssertEqual(FleetMap.oracle(ofIndex: "history/laris-co__neo-oracle"), "Neo")
        XCTAssertEqual(FleetMap.oracle(ofIndex: "history/laris-co__pulse"), "Pulse")
        XCTAssertEqual(FleetMap.oracle(ofIndex: "history/laris-co__nexus-oracle"), "Nexus")
        XCTAssertEqual(FleetMap.oracle(ofIndex: "gh-index"), "Fleet")
    }

    func testOracleOfRepo() {
        let known: Set<String> = ["Neo", "Pulse", "Nexus"]
        XCTAssertEqual(FleetMap.oracle(ofRepo: "laris-co/nexus-oracle", known: known), "Nexus")
        XCTAssertEqual(FleetMap.oracle(ofRepo: "laris-co/pulse", known: known), "Pulse")
        XCTAssertEqual(FleetMap.oracle(ofRepo: "Soul-Brews-Studio/oracle-app-kit", known: known), "Fleet")   // no oracle of that name
        XCTAssertEqual(FleetMap.oracle(ofRepo: "", known: known), "Fleet")
    }

    @MainActor
    func testDominantNeedsEightyPercent() {
        let fleet = FleetMap()
        fleet.setOracles(["a": "Neo", "b": "Neo", "c": "Neo", "d": "Neo", "e": "Pulse", "f": "Pulse", "g": "Neo", "h": "Pulse"])
        // region 0: 4 of 5 Neo (80 %) → Neo; region 1: 1 Neo, 2 Pulse (67 %) → none
        let d = fleet.dominant(labels: [0, 0, 0, 0, 0, 1, 1, 1], ids: ["a", "b", "c", "d", "e", "f", "g", "h"])
        XCTAssertEqual(d[0], "Neo")
        XCTAssertNil(d[1])
        XCTAssertTrue(fleet.dominant(labels: [0], ids: []).isEmpty)   // misaligned: nothing
    }

    func testBroadcastHashIsStableAndOpaque() {
        let id = "note:file:///opt/Code/github.com/laris-co/nexus-oracle/%CF%88/memory/traces/2026-08-31/2101_dig-nexus-oracle-deep.md"
        XCTAssertEqual(QueryBroadcast.hash(id), QueryBroadcast.hash(id))            // the same in every process
        XCTAssertNotEqual(QueryBroadcast.hash(id), QueryBroadcast.hash(id + "#2"))
        XCTAssertLessThanOrEqual(QueryBroadcast.hash(id).count, 16)
        XCTAssertFalse(QueryBroadcast.hash(id).contains("nexus"))                   // no path, no title
        XCTAssertEqual(QueryBroadcast.hash(""), "cbf29ce484222325")                 // FNV-1a 64 offset basis
    }

    func testColoursAreTheOraclesOwn() {
        XCTAssertEqual(FleetMap.color("Pulse").redComponent, 0.94, accuracy: 0.01)
        XCTAssertEqual(FleetMap.color("Someone"), FleetMap.color("Someone"))   // made from the name: the same every time
    }
}
