import XCTest
@testable import OracleKit

/// The map's groups (#35): planted clusters are found, the elbow lands on them, titles survive a re-grouping that
/// barely moved a group, Thai keywords and model answers are handled.
final class MapClustersTests: XCTestCase {
    /// n points around each of `centres` random unit directions in `dim` dimensions, normalised (row-major).
    private func planted(_ centres: Int, each: Int, dim: Int, spread: Float = 0.35, seed: UInt64 = 7) -> (X: [Float], truth: [Int]) {
        var g = Seeded(seed)
        let C = (0..<centres).map { _ in unit((0..<dim).map { _ in g.gauss() }) }
        var X: [Float] = [], truth: [Int] = []
        for c in 0..<centres { for _ in 0..<each { X += unit(C[c].map { $0 + spread * g.gauss() / Float(dim).squareRoot() }); truth.append(c) } }
        return (X, truth)
    }
    private func unit(_ v: [Float]) -> [Float] { let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot(); return v.map { $0 / n } }

    func testThreePlantedClustersAreFound() {
        let (X, truth) = planted(3, each: 100, dim: 32)
        let (labels, C) = MapClusters.sphericalKMeans(X, n: 300, dim: 32, k: 3)
        XCTAssertEqual(C.count, 3 * 32)
        // every planted cluster maps onto exactly one found cluster
        for c in 0..<3 {
            let found = Set(truth.indices.filter { truth[$0] == c }.map { labels[$0] })
            XCTAssertEqual(found.count, 1, "planted cluster \(c) split over \(found)")
        }
        XCTAssertEqual(Set(labels).count, 3)
    }

    func testSameInputSameGroups() {
        let (X, _) = planted(3, each: 100, dim: 32)
        XCTAssertEqual(MapClusters.sphericalKMeans(X, n: 300, dim: 32, k: 3).labels, MapClusters.sphericalKMeans(X, n: 300, dim: 32, k: 3).labels)
    }

    func testElbowNearPlantedCount() {
        let (X, _) = planted(12, each: 60, dim: 48)
        let k = MapClusters.elbow(X, n: 720, dim: 48)
        XCTAssert((10...14).contains(k), "elbow at \(k) for 12 planted groups")
    }

    func testTwoLevels() {
        let (X, _) = planted(12, each: 60, dim: 48)
        let texts = (0..<720).map { "doc \($0 / 60) word\($0 / 60) topic\($0 / 60)" }   // the text of each planted group
        let g = MapClusters.group(X, n: 720, dim: 48, texts: texts, shown: texts)
        XCTAssertEqual(g.labels.count, 720); XCTAssertEqual(g.leafLabels.count, 720)
        XCTAssert(g.leaves.count >= g.groups.count, "\(g.leaves.count) leaves for \(g.groups.count) regions")
        // a leaf never straddles two regions
        for l in g.leaves { XCTAssertEqual(Set(g.leafLabels.indices.filter { g.leafLabels[$0] == l.id }.map { g.labels[$0] }), [l.parent!]) }
        XCTAssertEqual(g.groups.map(\.count).reduce(0, +), 720)
        XCTAssertFalse(g.groups[0].keywords.isEmpty)
        XCTAssertEqual(g.groups[0].examples?.count, 1)   // three examples asked, all texts of a group are the same one
    }

    func testZeroRowsAreNeverSeeds() {
        // one doc without a vector first: farthest-first must not seed on it (it would win every round)
        let (P, _) = planted(3, each: 100, dim: 32)
        let X = [Float](repeating: 0, count: 32) + P
        let (labels, _) = MapClusters.sphericalKMeans(X, n: 301, dim: 32, k: 3)
        XCTAssertEqual(Set(labels.dropFirst()).count, 3, "the three planted groups are still found")
    }

    func testSeededRegroupKeepsGroups() {
        // 300 docs grouped, 30 more added: started from the old centres, the old groups stay and carry their titles
        let (X, _) = planted(3, each: 110, dim: 32)
        let ids = (0..<330).map { "d\($0)" }
        let m = 300, old = MapClusters.group(Array(X.prefix(m * 32)), n: m, dim: 32, texts: Array(repeating: "", count: m), shown: Array(repeating: "", count: m))
        let seed = MapClusters.seed(oldIds: Array(ids.prefix(m)), labels: old.labels, groups: old.groups, leafLabels: old.leafLabels,
                                    leaves: old.leaves, newIds: ids, X: X, dim: 32)
        XCTAssertNotNil(seed)
        let new = MapClusters.group(X, n: 330, dim: 32, texts: Array(repeating: "", count: 330), shown: Array(repeating: "", count: 330), seed: seed)
        var g = new.groups
        let titled = old.groups.map { var x = $0; x.title = "T\(x.id)"; x.model = "apple-fm"; return x }
        // 8 regions at least, on 3 planted groups: a planted group is split somewhere, and that split may move a little
        let kept = MapClusters.carry(into: &g, labels: new.labels, ids: ids, from: titled, labels: old.labels, ids: Array(ids.prefix(m)))
        XCTAssertGreaterThanOrEqual(kept * 5, old.groups.count * 4, "\(kept) of \(old.groups.count) titles kept")
    }

    func testTitlesCarryOnlyWhenMembersStay() {
        let ids = (0..<100).map { "d\($0)" }
        let old = [MapClusters.Group(id: 0, count: 50, keywords: ["a"], title: "Old A", model: "apple-fm"),
                   MapClusters.Group(id: 1, count: 50, keywords: ["b"], title: "Old B", model: "apple-fm")]
        let oldLabels = (0..<100).map { $0 < 50 ? 0 : 1 }
        // the new grouping swaps the ids and moves 5 docs of B into A: A' = 55 (50 of A), B' = 45 (all of B)
        var new = [MapClusters.Group(id: 7, count: 55, keywords: ["a"]), MapClusters.Group(id: 3, count: 45, keywords: ["b"])]
        let newLabels = (0..<100).map { $0 < 55 ? 7 : 3 }
        let kept = MapClusters.carry(into: &new, labels: newLabels, ids: ids, from: old, labels: oldLabels, ids: ids)
        XCTAssertEqual(kept, 2)                                  // 50/55 = 0.91 and 45/50 = 0.9 ≥ 0.8
        XCTAssertEqual(new.map(\.title), ["Old A", "Old B"])
        // half of A moves: A'' = 25 of A — titled again
        var moved = [MapClusters.Group(id: 0, count: 25, keywords: ["a"]), MapClusters.Group(id: 1, count: 75, keywords: ["b"])]
        let kept2 = MapClusters.carry(into: &moved, labels: (0..<100).map { $0 < 25 ? 0 : 1 }, ids: ids, from: old, labels: oldLabels, ids: ids)
        XCTAssertEqual(kept2, 0)
        XCTAssertNil(moved[0].model)
    }

    func testThaiKeywordsKeepShortWords() {
        XCTAssertTrue(MapClusters.keyword("บท"))      // two letters, Thai: a word
        XCTAssertFalse(MapClusters.keyword("ab"))     // two letters, Latin: too short
        XCTAssertFalse(MapClusters.keyword("ทำ"))     // filler
        XCTAssertTrue(ClusterTitler.mostlyThai(["หนังสือ", "บท", "pdf"]))
        XCTAssertFalse(ClusterTitler.mostlyThai(["map", "layout", "ภาพ"]))
        XCTAssertTrue(ClusterTitler.isThai("การเขียนหนังสือ"))
        XCTAssertFalse(ClusterTitler.isThai("Book writing"))
    }

    func testCleanTitle() {
        XCTAssertEqual(ClusterTitler.clean("Title: \"Session Management.\"\nmore"), "Session Management")
        XCTAssertEqual(ClusterTitler.clean("**Map Layout**"), "Map Layout")
        XCTAssertEqual(ClusterTitler.clean("one two three four five six seven eight"), "one two three four five six")
        XCTAssertNil(ClusterTitler.clean("  \"\"  "))
        XCTAssertLessThanOrEqual(ClusterTitler.clean(String(repeating: "abcdefghij ", count: 6))!.count, 48)
        XCTAssertTrue(ClusterTitler.same("Cheapest Flights DMK Sep", "cheapest DMK flights sep"))
        XCTAssertFalse(ClusterTitler.same("Session Retrospective", "Session Index Retrospective"))
    }

    /// The real memories, titled for the PR (run by hand): MAP_REAL_INDEX=history/laris-co__pulse swift test --filter Real
    @MainActor
    func testRealIndexTitles() async throws {
        guard let name = ProcessInfo.processInfo.environment["MAP_REAL_INDEX"] else { throw XCTSkip("set MAP_REAL_INDEX to title a real index") }
        let index = GHIndex(name: name)
        let ids = index.layout.ids
        let byId = Dictionary(index.docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = ids.map { byId[$0] }
        let dim = rows.first(where: { $0 != nil })??.vec.count ?? 0
        try XCTSkipIf(dim == 0 || ids.isEmpty, "\(name): no layout or no vectors")
        var X: [Float] = [], texts: [String] = [], shown: [String] = []
        for r in rows {
            if let r, r.vec.count == dim {
                X += r.vec
                let said = r.snippet.hasPrefix("/") ? "" : r.snippet
                texts.append(r.kind == "history" ? said : r.title + " " + r.snippet); shown.append(r.kind == "history" ? said : r.title)
            } else { X += [Float](repeating: 0, count: dim); texts.append(""); shown.append("") }
        }
        let t0 = Date()
        let n = ids.count
        if let add = Int(ProcessInfo.processInfo.environment["MAP_REAL_CARRY"] ?? "") {   // #35: N docs added, then a re-group
            let m = n - add, Xm = Array(X.prefix(m * dim)), tm = Array(texts.prefix(m)), sm = Array(shown.prefix(m))
            let before = await Task.detached { MapClusters.group(Xm, n: m, dim: dim, texts: tm, shown: sm) }.value
            let oldIds = Array(ids.prefix(m))
            let after = await Task.detached { () -> MapClusters.Grouping in
                let seed = MapClusters.seed(oldIds: oldIds, labels: before.labels, groups: before.groups, leafLabels: before.leafLabels,
                                            leaves: before.leaves, newIds: ids, X: X, dim: dim)
                return MapClusters.group(X, n: n, dim: dim, texts: texts, shown: shown, seed: seed)
            }.value
            var old = before.groups.map { var x = $0; x.title = "T\(x.id)"; x.model = "apple-fm"; return x }
            var oldLeaves = before.leaves.map { var x = $0; x.title = "L\(x.id)"; x.model = "apple-fm"; return x }
            var g = after.groups, l = after.leaves
            let kept = MapClusters.carry(into: &g, labels: after.labels, ids: ids, from: old, labels: before.labels, ids: Array(ids.prefix(m)))
                + MapClusters.carry(into: &l, labels: after.leafLabels, ids: ids, from: oldLeaves, labels: before.leafLabels, ids: Array(ids.prefix(m)))
            old = []; oldLeaves = []
            let total = g.count + l.count
            let out = "\(name): +\(add) docs → regions \(before.groups.count)→\(after.groups.count), leaves \(before.leaves.count)→\(after.leaves.count): relabelled \(total - kept) of \(total) (kept \(kept))\n"
            try out.write(toFile: (ProcessInfo.processInfo.environment["MAP_REAL_OUT"] ?? NSTemporaryDirectory() + "map-carry.txt"), atomically: true, encoding: .utf8)
            print(out); return
        }
        let g = await Task.detached { MapClusters.group(X, n: n, dim: dim, texts: texts, shown: shown) }.value
        let secs = Date().timeIntervalSince(t0)
        var out = String(format: "%@: %d docs → %d regions (k %d at the elbow), %d leaves in %.1f s (%@)\n", name, n, g.groups.count, g.k, g.leaves.count, secs, g.timing)
        let leafLimit = Int(ProcessInfo.processInfo.environment["MAP_REAL_LEAVES"] ?? "") ?? 0
        let t1 = Date()
        for r in g.groups.sorted(by: { $0.count > $1.count }) {
            let t = await ClusterTitler.title(keywords: r.keywords, examples: r.examples ?? [])
            out += "\n\(String(format: "%6d", r.count))  \(t.title ?? "—")  [\(t.model)]  ← \(r.keywords.joined(separator: " · "))"
            var taken = t.title.map { [$0] } ?? []
            for l in g.leaves.filter({ $0.parent == r.id }).sorted(by: { $0.count > $1.count }).prefix(leafLimit) {
                let lt = await ClusterTitler.title(keywords: l.keywords, examples: l.examples ?? [], within: t.title, avoiding: taken)
                if let x = lt.title { taken.append(x) }
                out += "\n        \(String(format: "%5d", l.count))  \(lt.title ?? "—")  [\(lt.model)]  ← \(l.keywords.joined(separator: " · "))"
            }
        }
        out += String(format: "\n\ntitled in %.0f s\n", Date().timeIntervalSince(t1))
        let path = ProcessInfo.processInfo.environment["MAP_REAL_OUT"] ?? NSTemporaryDirectory() + "map-titles.txt"
        try out.write(toFile: path, atomically: true, encoding: .utf8)
        print(out)
    }
}

/// A small deterministic generator (SplitMix64) with a Box–Muller normal.
private struct Seeded {
    var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) }
    mutating func uniform() -> Float { Float(next() >> 40) / Float(1 << 24) }
    mutating func gauss() -> Float { let u = max(uniform(), 1e-7), v = uniform(); return (-2 * log(u)).squareRoot() * cos(2 * .pi * v) }
}
