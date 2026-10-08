#if os(macOS)
import Foundation
import Accelerate
import NaturalLanguage

extension MapClusters {
    // MARK: the grouping (pure, off the main actor)

    struct Grouping: Sendable {
        var k: Int; var labels: [Int]; var groups: [Group]; var leafLabels: [Int]; var leaves: [Group]
        /// Where the time went: "elbow 0.4 s · regions 0.6 s · leaves 0.9 s · words 2.1 s"
        var timing = ""
    }

    /// Where a re-grouping starts: the old regions' centres (k × dim) and, per region, its old leaves' centres —
    /// each the mean of its old members' vectors now.
    struct Seed: Sendable { var k: Int; var regions: [Float]; var leaves: [[Float]] }

    /// The seed from an old grouping, when at least half the docs were in it (else a fresh grouping is better).
    nonisolated static func seed(oldIds: [String], labels: [Int], groups: [Group], leafLabels: [Int], leaves: [Group],
                                 newIds: [String], X: [Float], dim: Int) -> Seed? {
        guard !groups.isEmpty, oldIds.count == labels.count, labels.count == leafLabels.count else { return nil }
        let regionAt = Dictionary(uniqueKeysWithValues: groups.map(\.id).sorted().enumerated().map { ($1, $0) })
        let leafIds = leaves.map(\.id).sorted(), leafAt = Dictionary(uniqueKeysWithValues: leafIds.enumerated().map { ($1, $0) })
        var was: [String: (Int, Int)] = [:]
        was.reserveCapacity(oldIds.count)
        for (i, id) in oldIds.enumerated() { was[id] = (labels[i], leafLabels[i]) }
        var top = [Int](repeating: -1, count: newIds.count), leaf = [Int](repeating: -1, count: newIds.count), known = 0
        for (i, id) in newIds.enumerated() {
            guard let w = was[id], let r = regionAt[w.0] else { continue }
            top[i] = r; leaf[i] = leafAt[w.1] ?? -1; known += 1
        }
        guard known * 2 >= newIds.count else { return nil }
        let k = regionAt.count
        let C = centres(X, n: newIds.count, labels: top, k: k, dim: dim), LC = centres(X, n: newIds.count, labels: leaf, k: leafIds.count, dim: dim)
        var perRegion = [[Float]](repeating: [], count: k)
        for l in leaves { if let j = leafAt[l.id], let p = l.parent, let r = regionAt[p] { perRegion[r] += LC[(j * dim)..<((j + 1) * dim)] } }
        return Seed(k: k, regions: C, leaves: perRegion)
    }

    /// The k × dim centres of labelled rows of a flat matrix (a label < 0 is skipped).
    nonisolated static func centres(_ X: [Float], n: Int, labels: [Int], k: Int, dim: Int) -> [Float] {
        var C = [Float](repeating: 0, count: k * dim)
        X.withUnsafeBufferPointer { x in C.withUnsafeMutableBufferPointer { c in
            for i in 0..<n where labels[i] >= 0 && labels[i] < k {
                vDSP_vadd(c.baseAddress! + labels[i] * dim, 1, x.baseAddress! + i * dim, 1, c.baseAddress! + labels[i] * dim, 1, vDSP_Length(dim))
            }
        } }
        normaliseRows(&C, k: k, dim: dim)
        return C
    }

    /// Regions at the elbow, each split into leaves (about n / 80 docs a leaf on a big memory; a region under 40 docs
    /// stays one leaf), then keywords and the texts nearest each centre.
    nonisolated static func group(_ X: [Float], n: Int, dim: Int, texts: [String], shown: [String], seed: Seed? = nil) -> Grouping {
        var clock = Date(), timing: [String] = []
        func lap(_ what: String) { timing.append(String(format: "%@ %.1f s", what, Date().timeIntervalSince(clock))); clock = Date() }
        let k = seed?.k ?? elbow(X, n: n, dim: dim)
        lap(seed == nil ? "elbow" : "seeded")
        let (top, C) = sphericalKMeans(X, n: n, dim: dim, k: k, start: seed?.regions)
        lap("regions")
        let target = Double(min(80, max(24, Int((Double(n) / 8).squareRoot()))))
        var members = [[Int]](repeating: [], count: k)
        for i in 0..<n { members[top[i]].append(i) }
        var leaf = [Int](repeating: 0, count: n), parentOf: [Int] = [], LC: [Float] = []
        for g in 0..<k where !members[g].isEmpty {
            let m = members[g]
            let start = seed.map { $0.leaves[g] } ?? [], seeded = start.count / dim
            let kg = m.count < 40 ? 1 : seeded >= 2 ? seeded : max(2, min(12, Int((Double(m.count) * target / Double(n)).rounded())))
            let sl: [Int], sc: [Float]
            if kg == 1 { sl = [Int](repeating: 0, count: m.count); sc = Array(C[(g * dim)..<((g + 1) * dim)]) } else {
                var sub = [Float](); sub.reserveCapacity(m.count * dim)
                for i in m { sub.append(contentsOf: X[(i * dim)..<((i + 1) * dim)]) }
                let (raw, c) = sphericalKMeans(sub, n: m.count, dim: dim, k: kg, start: seeded == kg ? start : nil)
                sl = mergeTiny(raw, sub, dim: dim, centroids: c, k: kg); sc = c
            }
            let base = parentOf.count
            for (j, i) in m.enumerated() { leaf[i] = base + sl[j] }
            parentOf += [Int](repeating: g, count: kg); LC += sc
        }
        let L = parentOf.count
        lap("leaves")
        // the words of every doc, in 8 slices at once, one tokenizer per slice
        var words = [[String]](repeating: [], count: n)
        let slices = 8, per = (n + slices - 1) / slices
        words.withUnsafeMutableBufferPointer { out in
            let base = SlicePointer(out.baseAddress!)   // each slice writes only its own rows
            DispatchQueue.concurrentPerform(iterations: slices) { s in
                let t = NLTokenizer(unit: .word)
                for i in (s * per)..<min(n, (s + 1) * per) { base.p[i] = SearchCloud.words(texts[i], using: t) }
            }
        }
        let topWords = keywords(labels: top, words: words, k: k), leafWords = keywords(labels: leaf, words: words, k: L)
        let topEx = examples(X, dim: dim, labels: top, centroids: C, k: k, shown: shown)
        let leafEx = examples(X, dim: dim, labels: leaf, centroids: LC, k: L, shown: shown)
        var topCount = [Int](repeating: 0, count: k), leafCount = [Int](repeating: 0, count: L)
        for i in 0..<n { topCount[top[i]] += 1; leafCount[leaf[i]] += 1 }
        lap("words")
        return Grouping(
            k: k, labels: top,
            groups: (0..<k).filter { topCount[$0] > 0 }.map { Group(id: $0, count: topCount[$0], keywords: topWords[$0], examples: topEx[$0]) },
            leafLabels: leaf,
            leaves: (0..<L).filter { leafCount[$0] > 0 }.map { Group(id: $0, count: leafCount[$0], keywords: leafWords[$0], parent: parentOf[$0], examples: leafEx[$0]) },
            timing: timing.joined(separator: " · "))
    }

    /// A leaf of fewer than 5 docs (k-means seeds on outliers) is no group: its docs join the closest bigger leaf.
    nonisolated static func mergeTiny(_ labels: [Int], _ X: [Float], dim: Int, centroids C: [Float], k: Int, least: Int = 5) -> [Int] {
        var count = [Int](repeating: 0, count: k)
        for l in labels { count[l] += 1 }
        let big = (0..<k).filter { count[$0] >= least }
        guard !big.isEmpty, big.count < k else { return labels }
        var out = labels
        X.withUnsafeBufferPointer { x in C.withUnsafeBufferPointer { c in
            for i in labels.indices where count[labels[i]] < least {
                var best = big[0], bs = -Float.infinity
                for g in big { var s: Float = 0; vDSP_dotpr(x.baseAddress! + i * dim, 1, c.baseAddress! + g * dim, 1, &s, vDSP_Length(dim)); if s > bs { bs = s; best = g } }
                out[i] = best
            }
        } }
        return out
    }

    /// k for the regions: spherical k-means on a sample (≤ ~3,000 rows) for k = 8, 10, …, 16, the cohesion (mean
    /// cosine to the own centre) of each, and the elbow — the k farthest above the straight line from the first
    /// cohesion to the last (kneedle).
    nonisolated static func elbow(_ X: [Float], n: Int, dim: Int, ks: [Int] = [8, 10, 12, 14, 16]) -> Int {
        let step = max(1, n / 3_000)
        let rows = Array(stride(from: 0, to: n, by: step))
        guard rows.count >= ks.last! * 10 else { return ks[0] }
        var S = [Float](); S.reserveCapacity(rows.count * dim)
        for r in rows { S.append(contentsOf: X[(r * dim)..<((r + 1) * dim)]) }
        let m = rows.count
        let cohesion = ks.map { k -> Double in
            let (lab, C) = sphericalKMeans(S, n: m, dim: dim, k: k)
            var sum: Float = 0
            S.withUnsafeBufferPointer { s in C.withUnsafeBufferPointer { c in
                for i in 0..<m { var d: Float = 0; vDSP_dotpr(s.baseAddress! + i * dim, 1, c.baseAddress! + lab[i] * dim, 1, &d, vDSP_Length(dim)); sum += d }
            } }
            return Double(sum) / Double(m)
        }
        guard let lo = cohesion.first, let hi = cohesion.last, hi > lo else { return ks[ks.count / 2] }
        var best = ks[0], bd = -Double.infinity
        for (j, k) in ks.enumerated() {
            let d = (cohesion[j] - lo) / (hi - lo) - Double(j) / Double(ks.count - 1)
            if d > bd { bd = d; best = k }
        }
        return best
    }

    /// Spherical k-means on unit vectors: assign by the largest dot product (one sgemm per pass), centroids =
    /// normalised member means. Seeded farthest-first, so the same input gives the same groups. Returns the label
    /// per row and the k × dim centroids.
    nonisolated static func sphericalKMeans(_ X: [Float], n: Int, dim: Int, k: Int, iters: Int = 40, start: [Float]? = nil) -> (labels: [Int], centroids: [Float]) {
        var C = [Float](repeating: 0, count: k * dim)
        if let start, start.count == k * dim { C = start } else { seedFarthestFirst(X, n: n, dim: dim, k: k, into: &C) }
        var labels = [Int](repeating: 0, count: n)
        var S = [Float](repeating: 0, count: n * k)   // n × k similarities
        var Ct = [Float](repeating: 0, count: dim * k) // the centroids transposed, dim × k
        for _ in 0..<iters {
            // S = X · Cᵀ, with vDSP (cblas_sgemm is deprecated since macOS 13.3): row-major, so transpose C first
            vDSP_mtrans(C, 1, &Ct, 1, vDSP_Length(dim), vDSP_Length(k))
            vDSP_mmul(X, 1, Ct, 1, &S, 1, vDSP_Length(n), vDSP_Length(k), vDSP_Length(dim))
            var changed = 0
            for i in 0..<n {
                var bi = 0; var bs = S[i * k]
                for c in 1..<k where S[i * k + c] > bs { bs = S[i * k + c]; bi = c }
                if labels[i] != bi { labels[i] = bi; changed += 1 }
            }
            C = [Float](repeating: 0, count: k * dim)
            for i in 0..<n { let c = labels[i]; for j in 0..<dim { C[c * dim + j] += X[i * dim + j] } }
            normaliseRows(&C, k: k, dim: dim)
            if changed * 2_000 <= n { break }   // settled: fewer than 0.05 % still move
        }
        return (labels, C)
    }

    nonisolated static func seedFarthestFirst(_ X: [Float], n: Int, dim: Int, k: Int, into C: inout [Float]) {
        // farthest-first: start at the first row, then repeatedly the row least similar to every chosen centroid. A row
        // without a vector (all zeros: cosine 0 to everything) is never a seed, or it would win every later round.
        var best = [Float](repeating: -.infinity, count: n)
        X.withUnsafeBufferPointer { x in
            for i in 0..<n { var q: Float = 0; vDSP_svesq(x.baseAddress! + i * dim, 1, &q, vDSP_Length(dim)); if q == 0 { best[i] = .infinity } }
        }
        var pick = best.firstIndex { $0 != .infinity } ?? 0
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
    }

    nonisolated static func normaliseRows(_ C: inout [Float], k: Int, dim: Int) {
        for c in 0..<k {
            var norm: Float = 0
            C.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + c * dim, 1, &norm, vDSP_Length(dim)) }
            let r = norm > 0 ? 1 / norm.squareRoot() : 0
            for j in 0..<dim { C[c * dim + j] *= r }
        }
    }

    /// The k × dim centres of labelled vectors (rows without a vector are skipped).
    nonisolated static func centres(_ vecs: [[Float]], labels: [Int], k: Int, dim: Int) -> [Float] {
        var C = [Float](repeating: 0, count: k * dim)
        for (i, g) in labels.enumerated() where i < vecs.count && vecs[i].count == dim && g >= 0 && g < k {
            vecs[i].withUnsafeBufferPointer { v in for j in 0..<dim { C[g * dim + j] += v[j] } }
        }
        normaliseRows(&C, k: k, dim: dim)
        return C
    }

    /// Of the candidate groups, the one whose centre is closest in cosine (the first candidate for an empty vector).
    nonisolated static func nearest(_ v: [Float], in C: [Float], dim: Int, among candidates: [Int]) -> Int {
        guard v.count == dim, var best = candidates.first else { return candidates.first ?? 0 }
        var bs = -Float.infinity
        for g in candidates where (g + 1) * dim <= C.count {
            var s: Float = 0
            C.withUnsafeBufferPointer { c in vDSP_dotpr(v, 1, c.baseAddress! + g * dim, 1, &s, vDSP_Length(dim)) }
            if s > bs { bs = s; best = g }
        }
        return best
    }

    /// Per group, the 3 different texts nearest its centre, for the model to read.
    nonisolated static func examples(_ X: [Float], dim: Int, labels: [Int], centroids C: [Float], k: Int, shown: [String], top: Int = 3) -> [[String]] {
        var near = [[(Float, Int)]](repeating: [], count: k)
        X.withUnsafeBufferPointer { x in C.withUnsafeBufferPointer { c in
            for i in labels.indices where !shown[i].isEmpty {
                var s: Float = 0
                vDSP_dotpr(x.baseAddress! + i * dim, 1, c.baseAddress! + labels[i] * dim, 1, &s, vDSP_Length(dim))
                near[labels[i]].append((s, i))
            }
        } }
        return near.map { list in
            var seen = Set<String>(), out: [String] = []
            for (_, i) in list.sorted(by: { $0.0 > $1.0 }) {
                let t = String(shown[i].split(whereSeparator: \.isNewline).joined(separator: " ").prefix(90))
                if seen.insert(t).inserted { out.append(t) }
                if out.count == top { break }
            }
            return out
        }
    }

    /// Titles kept across a re-grouping: a new group takes the title of the old group it shares the most members with,
    /// when the two share at least 80 % (Jaccard) and the old one had a model's title. Returns how many were kept.
    nonisolated static func carry(into new: inout [Group], labels: [Int], ids: [String], from old: [Group], labels oldLabels: [Int], ids oldIds: [String]) -> Int {
        guard !old.isEmpty, oldLabels.count == oldIds.count, labels.count == ids.count else { return 0 }
        var oldOf: [String: Int] = [:], oldSize: [Int: Int] = [:]
        oldOf.reserveCapacity(oldIds.count)
        for (i, id) in oldIds.enumerated() { oldOf[id] = oldLabels[i]; oldSize[oldLabels[i], default: 0] += 1 }
        var overlap: [Int: [Int: Int]] = [:], size: [Int: Int] = [:]
        for (i, id) in ids.enumerated() {
            size[labels[i], default: 0] += 1
            if let o = oldOf[id] { overlap[labels[i], default: [:]][o, default: 0] += 1 }
        }
        let byId = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var kept = 0, taken = Set<Int>()
        for j in new.indices {
            guard let best = overlap[new[j].id]?.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }),
                  let og = byId[best.key], og.title != nil, !taken.contains(best.key) else { continue }
            let union = (size[new[j].id] ?? 0) + (oldSize[best.key] ?? 0) - best.value
            guard union > 0, Double(best.value) / Double(union) >= 0.8 else { continue }
            new[j].title = og.title; new[j].model = og.model; taken.insert(best.key); kept += 1
        }
        return kept
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
        // an assistant narrating its own steps ("I'm checking before I'll run…") names nothing either
        "i'm", "i’m", "i'll", "i’ll", "i've", "i’ve", "i'd", "i’d", "let's", "let’s", "it's", "it’s", "that's", "that’s", "don't", "don’t",
        "can't", "can’t", "won't", "won’t", "we're", "we’re", "you're", "you’re", "there's", "there’s", "here's", "here’s", "what's", "what’s",
        "before", "after", "about", "again", "other", "checking", "looking", "now's", "got", "seems", "actually", "really", "already",
        // the keys of messages and tool output pasted into a session
        "root", "type", "sender", "true", "false", "null", "value", "name", "content", "text", "json", "string",
        // and the words of any task ("both", "the same", "real", Nat's "shuld")
        "both", "same", "real", "rather", "anything", "everything", "nothing", "three", "every", "each", "against", "without",
        "another", "else", "shuld", "ต่อ",
        "ทำ", "ให้", "แล้ว", "ครับ", "นะ", "ไม่", "ได้", "มี", "ที่", "จะ", "เป็น", "ก็", "ด้วย", "อยู่", "ว่า", "ไป", "มา", "ดู", "ลอง", "อัน", "เลย",
        "จาก", "หน่อย", "มัน", "ผม", "ก่อน", "กัน", "คะ", "ค่ะ", "เดี๋ยว", "แบบ", "ตอน", "อีก", "ยัง", "เอา", "ช่วย", "ขอ", "คือ", "เขา", "นั้น",
        "ไหน", "ทุก", "แต่", "หรือ", "เพราะ", "ถ้า", "ต้อง", "แค่", "กว่า", "ทั้ง", "ไว้", "ออก", "เข้า", "ตัว", "อย่าง", "เรื่อง", "แล้วก็", "นะครับ"]

    /// A keyword: three letters or more — or two Thai ones (บท, ปก: Thai words are short in letters, not in meaning).
    nonisolated static func keyword(_ w: String) -> Bool {
        (w.count > 2 || (w.count == 2 && ClusterTitler.mostlyThai([w]))) && !w.allSatisfy(\.isNumber) && !filler.contains(w)
            && !w.hasSuffix("'s") && !w.hasSuffix("’s")   // "oracle's": the word is there without its 's
    }

    nonisolated static func keywords(labels: [Int], words: [[String]], k: Int, top: Int = 6) -> [[String]] {
        var tf = [[String: Int]](repeating: [:], count: k)
        var total: [String: Int] = [:]
        var size = [Int](repeating: 0, count: k)
        for (i, ws) in words.enumerated() {
            let g = labels[i]
            for w in ws where keyword(w) { tf[g][w, default: 0] += 1; total[w, default: 0] += 1; size[g] += 1 }
        }
        let mean = Double(size.reduce(0, +)) / Double(max(1, k))
        return (0..<k).map { g -> [String] in
            let scored: [(String, Double)] = tf[g].map { (w, c) -> (String, Double) in
                (w, Double(c) / Double(max(1, size[g])) * log(1 + mean / Double(total[w] ?? 1)))
            }
            // ties broken by the word, so the same groups always get the same names
            let ranked = scored.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : a.0 < b.0 }
            return ranked.prefix(top).map(\.0)
        }
    }
}
#endif
