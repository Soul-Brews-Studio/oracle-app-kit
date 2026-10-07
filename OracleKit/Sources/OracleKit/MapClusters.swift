import Foundation
import Accelerate

/// The map's groups (issue #35): docs clustered in the 768-d space (spherical k-means — cosine, deterministic),
/// each group named by its c-TF-IDF keywords (the words that are frequent in it and rare elsewhere). Computed in
/// the background after a layout, cached in <index>.clusters.json, recomputed when the layout is refitted.
@MainActor
public final class MapClusters: ObservableObject {
    public struct Group: Codable, Sendable, Identifiable {
        public var id: Int
        public var count: Int
        public var keywords: [String]
        public var name: String { keywords.prefix(3).joined(separator: " · ") }
    }
    struct File: Codable { var built: Date; var n: Int; var labels: [Int]; var groups: [Group]; var version: Int? }
    static let version = 2   // bump when naming changes: cached groups are renamed

    @Published public private(set) var groups: [Group] = []
    /// group per layout row (same order as MapLayout.ids)
    @Published public private(set) var labels: [Int] = []
    @Published public private(set) var running = false
    private let url: URL
    private var built: Date?
    private var version = 0

    init(stem: URL) {
        url = URL(fileURLWithPath: stem.path + ".clusters.json")
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let f = try? d.decode(File.self, from: data) {
            groups = f.groups; labels = f.labels; built = f.built; version = f.version ?? 1
        }
    }

    /// Group the layout's docs when the layout is newer than the groups (or there are none). k grows with the
    /// memory: about √(n/40), 8…24 groups.
    public func refresh(layout: MapLayout, docs: [IndexDoc]) async {
        guard let meta = layout.meta, !running, layout.ids.count >= 50 else { return }
        if built == meta.built, labels.count == layout.ids.count, version == Self.version { return }
        running = true
        let byId = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = layout.ids.map { byId[$0] }
        let dim = rows.first(where: { $0 != nil })??.vec.count ?? 0
        guard dim > 0 else { running = false; return }
        var X = [Float](); X.reserveCapacity(rows.count * dim)
        var texts: [String] = []
        for r in rows {
            // a session piece is named by what was said (its snippet), not the session's title; a /command says nothing
            if let r, r.vec.count == dim { X.append(contentsOf: r.vec); texts.append(r.kind == "history" ? (r.snippet.hasPrefix("/") ? "" : r.snippet) : r.title + " " + r.snippet) }
            else { X.append(contentsOf: [Float](repeating: 0, count: dim)); texts.append("") }
        }
        let n = rows.count
        let k = min(24, max(8, Int((Double(n) / 40).squareRoot())))
        let t0 = Date()
        let result = await Task.detached(priority: .utility) { () -> ([Int], [[String]]) in
            let labels = Self.sphericalKMeans(X, n: n, dim: dim, k: k)
            let words = texts.map { SearchCloud.words($0) }
            return (labels, Self.keywords(labels: labels, words: words, k: k))
        }.value
        labels = result.0
        groups = (0..<k).map { g in Group(id: g, count: result.0.filter { $0 == g }.count, keywords: result.1[g]) }
            .filter { $0.count > 0 }
        built = meta.built; version = Self.version
        save()
        HubLog.shared.add(.info, String(format: "map groups: %d docs in %d groups in %.1f s", n, groups.count, Date().timeIntervalSince(t0)))
        running = false
    }

    private func save() {
        guard let built else { return }
        let f = File(built: built, n: labels.count, labels: labels, groups: groups, version: Self.version), url = url
        Task.detached(priority: .utility) {
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            try? e.encode(f).write(to: url, options: .atomic)
        }
    }

    /// Spherical k-means on unit vectors: assign by the largest dot product (one sgemm per pass), centroids =
    /// normalised member means. Seeded farthest-first, so the same input gives the same groups.
    nonisolated static func sphericalKMeans(_ X: [Float], n: Int, dim: Int, k: Int, iters: Int = 15) -> [Int] {
        var C = [Float](repeating: 0, count: k * dim)
        // farthest-first: start at row 0, then repeatedly the row least similar to every chosen centroid
        var best = [Float](repeating: -.infinity, count: n)
        var pick = 0
        for c in 0..<k {
            for j in 0..<dim { C[c * dim + j] = X[pick * dim + j] }
            var low: Float = .infinity, lowRow = 0
            for i in 0..<n {
                var s: Float = 0
                X.withUnsafeBufferPointer { x in C.withUnsafeBufferPointer { cc in
                    vDSP_dotpr(x.baseAddress! + i * dim, 1, cc.baseAddress! + c * dim, 1, &s, vDSP_Length(dim)) } }
                best[i] = max(best[i], s)
                if best[i] < low { low = best[i]; lowRow = i }
            }
            pick = lowRow
        }
        var labels = [Int](repeating: 0, count: n)
        var S = [Float](repeating: 0, count: n * k)   // n × k similarities
        for _ in 0..<iters {
            X.withUnsafeBufferPointer { x in C.withUnsafeBufferPointer { c in S.withUnsafeMutableBufferPointer { s in
                cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(n), Int32(k), Int32(dim), 1,
                            x.baseAddress, Int32(dim), c.baseAddress, Int32(dim), 0, s.baseAddress, Int32(k))
            } } }
            var changed = 0
            for i in 0..<n {
                var bi = 0; var bs = S[i * k]
                for c in 1..<k where S[i * k + c] > bs { bs = S[i * k + c]; bi = c }
                if labels[i] != bi { labels[i] = bi; changed += 1 }
            }
            C = [Float](repeating: 0, count: k * dim)
            for i in 0..<n { let c = labels[i]; for j in 0..<dim { C[c * dim + j] += X[i * dim + j] } }
            for c in 0..<k {
                var norm: Float = 0
                C.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + c * dim, 1, &norm, vDSP_Length(dim)) }
                let r = norm > 0 ? 1 / norm.squareRoot() : 0
                for j in 0..<dim { C[c * dim + j] *= r }
            }
            if changed == 0 { break }
        }
        return labels
    }

    /// c-TF-IDF (BERTopic's class-based TF-IDF): tf of a word in the group × log(1 + mean words per group / its
    /// frequency over all groups). The top 6 words per group.
    /// Chat filler that is frequent everywhere and names nothing (SearchCloud's stop list covers the shortest words).
    nonisolated static let filler: Set<String> = ["now", "let", "lets", "clear", "yes", "okay", "please", "can", "just", "use", "like",
        "make", "need", "want", "get", "see", "also", "still", "one", "two", "new", "run", "done", "good", "will", "would", "should",
        "could", "its", "this", "that", "with", "from", "the", "and", "for", "are", "you", "your", "not", "but", "have", "has", "what",
        "how", "why", "when", "where", "which", "there", "here", "then", "than", "into", "out", "all", "any", "some", "more", "most",
        "very", "much", "many", "only", "been", "being", "was", "were", "did", "does", "doing", "go", "going", "next", "first", "last",
        "way", "thing", "things", "something", "think", "know", "look", "try", "work", "working", "sure", "right", "well", "back",
        "keep", "check", "show", "tell", "said", "says", "say", "way", "time", "file", "files", "full", "start", "starting", "following",
        "ทำ", "ให้", "แล้ว", "ครับ", "นะ", "ไม่", "ได้", "มี", "ที่", "จะ", "เป็น", "ก็", "ด้วย", "อยู่", "ว่า", "ไป", "มา", "ดู", "ลอง", "อัน", "เลย"]

    nonisolated static func keywords(labels: [Int], words: [[String]], k: Int, top: Int = 6) -> [[String]] {
        var tf = [[String: Int]](repeating: [:], count: k)
        var total: [String: Int] = [:]
        var size = [Int](repeating: 0, count: k)
        for (i, ws) in words.enumerated() {
            let g = labels[i]
            for w in ws where w.count > 2 && !w.allSatisfy(\.isNumber) && !filler.contains(w) { tf[g][w, default: 0] += 1; total[w, default: 0] += 1; size[g] += 1 }
        }
        let mean = Double(size.reduce(0, +)) / Double(max(1, k))
        return (0..<k).map { g in
            tf[g].map { (w, c) -> (String, Double) in
                (w, Double(c) / Double(max(1, size[g])) * log(1 + mean / Double(total[w] ?? 1)))
            }
            .sorted { $0.1 > $1.1 }.prefix(top).map(\.0)
        }
    }
}

extension GHIndex {
    /// This index's groups (lazy, one per index).
    public var clusters: MapClusters {
        if let c = GHIndex.clusterSets[name] { return c }
        let c = MapClusters(stem: URL(fileURLWithPath: filePath).deletingPathExtension())
        GHIndex.clusterSets[name] = c
        return c
    }
    static var clusterSets: [String: MapClusters] = [:]
}
