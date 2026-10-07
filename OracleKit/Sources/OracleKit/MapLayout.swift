import Foundation
import Accelerate
import simd
import CryptoKit

/// Where every doc of an index sits in 3-D — the Map page's positions. Computed in-process by an engine the app
/// registers (UMAP over the index's vectors, kNN graph included), cached beside the vectors, and kept in step with
/// the index: new docs are placed among their nearest neighbours without a re-fit; a re-fit happens only when more
/// than 15 % of the docs are new, and the new layout is aligned onto the old one so the map does not spin.
///
/// Files, next to `<index>.vectors`:
///   <index>.xyz        N × 3 Float32, little-endian, no header, in the order of `<index>.xyz.ids.json`
///   <index>.xyz.ids.json   the doc ids, so a layout survives docs being appended or dropped
///   <index>.xyz.json   {space, n, k, minDist, built, seconds, engine}
///   <index>.knn        N × k Int32 neighbour doc indexes (into the ids order), -1 = none
@MainActor
public final class MapLayout: ObservableObject {
    /// data (n × dim, row-major), k, minDist, seed → xyz (n × 3), kNN indexes (n × k), kNN distances (n × k)
    public typealias Engine = @Sendable (_ data: [Float], _ n: Int, _ dim: Int, _ k: Int, _ minDist: Float, _ seed: UInt64) async throws -> (xyz: [Float], knn: [Int32], dist: [Float])
    /// Registered once by the app (Apps/Shared/MapLayoutEngine.swift); nil in a process that cannot lay out (iOS).
    nonisolated(unsafe) public static var engine: Engine?
    public static var engineName = "none"

    public struct Meta: Codable, Sendable, Equatable {
        public var space: String
        public var n: Int
        public var k: Int
        public var minDist: Float
        public var built: Date
        public var seconds: Double
        public var engine: String
        public var placed: Int = 0          // docs placed by neighbours since the last fit (the 15 % rule counts these)
    }

    @Published public private(set) var xyz: [SIMD3<Float>] = []     // in `ids` order
    @Published public private(set) var ids: [String] = []
    @Published public private(set) var meta: Meta?
    @Published public private(set) var running = false
    @Published public private(set) var progress = ""
    @Published public private(set) var problem: String?
    /// kNN neighbours per doc (flat, k per row, into `ids` order); -1 = none
    public private(set) var knn: [Int32] = []
    public private(set) var k = 15
    public static let minDist: Float = 0.1
    public static let refitShare = 0.15

    private let stem: URL     // <dir>/<index>  (no extension)
    private var index: [String: Int] = [:]   // id → row

    public init(stem: URL) {
        self.stem = stem
        load()
    }

    var xyzURL: URL { stem.appendingPathExtension("xyz") }
    var idsURL: URL { URL(fileURLWithPath: stem.path + ".xyz.ids.json") }
    var metaURL: URL { URL(fileURLWithPath: stem.path + ".xyz.json") }
    var knnURL: URL { stem.appendingPathExtension("knn") }
    public var filePath: String { xyzURL.path }

    /// The row of a doc id, nil when the doc has no position yet.
    public func row(of id: String) -> Int? { index[id] }
    public func position(of id: String) -> SIMD3<Float>? { index[id].map { xyz[$0] } }
    /// The neighbours of a row (doc indexes into `ids`), from the kNN graph the fit built.
    public func neighbours(of row: Int) -> [Int] {
        guard k > 0, row * k + k <= knn.count else { return [] }
        return knn[(row * k)..<(row * k + k)].compactMap { $0 >= 0 ? Int($0) : nil }
    }

    // MARK: files

    private func load() {
        guard let md = try? Data(contentsOf: metaURL), let m = try? Self.decoder.decode(Meta.self, from: md),
              let idd = try? Data(contentsOf: idsURL), let ids = try? JSONDecoder().decode([String].self, from: idd),
              let raw = try? Data(contentsOf: xyzURL), raw.count == ids.count * 12, ids.count == m.n else { return }
        xyz = Self.unpack(raw)
        self.ids = ids; meta = m; k = m.k
        index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        if let kd = try? Data(contentsOf: knnURL), kd.count == ids.count * m.k * 4 {
            knn = kd.withUnsafeBytes { Array($0.bindMemory(to: Int32.self)) }
        }
    }

    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    nonisolated static func unpack(_ raw: Data) -> [SIMD3<Float>] {
        raw.withUnsafeBytes { buf -> [SIMD3<Float>] in
            let f = buf.bindMemory(to: Float.self)
            return stride(from: 0, to: f.count - 2, by: 3).map { SIMD3(f[$0], f[$0 + 1], f[$0 + 2]) }
        }
    }
    nonisolated static func pack(_ p: [SIMD3<Float>]) -> Data {
        var raw = Data(capacity: p.count * 12)
        for v in p { var x = v.x, y = v.y, z = v.z
            withUnsafeBytes(of: &x) { raw.append(contentsOf: $0) }; withUnsafeBytes(of: &y) { raw.append(contentsOf: $0) }; withUnsafeBytes(of: &z) { raw.append(contentsOf: $0) } }
        return raw
    }

    /// Everything to disk, off the main actor, each file written whole then renamed (a kill leaves the old layout).
    private func save() {
        let xyz = xyz, ids = ids, meta = meta, knn = knn, urls = (xyzURL, idsURL, metaURL, knnURL)
        Task.detached(priority: .utility) {
            try? Self.pack(xyz).write(to: urls.0, options: .atomic)
            try? JSONEncoder().encode(ids).write(to: urls.1, options: .atomic)
            if let meta, let md = try? Self.encoder.encode(meta) { try? md.write(to: urls.2, options: .atomic) }
            knn.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: urls.3, options: .atomic) }
        }
    }

    public func forget() {
        xyz = []; ids = []; meta = nil; knn = []; index = [:]
        for u in [xyzURL, idsURL, metaURL, knnURL] { try? FileManager.default.removeItem(at: u) }
    }

    // MARK: fit

    /// Whether a fit is wanted: no layout, another vector space, or more than 15 % of the docs placed since the fit.
    public func staleReason(docs: [IndexDoc], space: String?) -> String? {
        guard Self.engine != nil else { return nil }
        if docs.count < 10 { return nil }
        guard let meta else { return "no map layout yet" }
        if let space, meta.space != space { return "the layout is of another vector space" }
        let known = docs.filter { index[$0.id] != nil }.count
        let fresh = docs.count - known
        if Double(fresh + meta.placed) > Self.refitShare * Double(docs.count) { return "\(fresh + meta.placed) of \(docs.count) docs were placed, not fitted" }
        return nil
    }

    /// A full UMAP fit over every doc, in the background; the new layout is turned and scaled onto the old one
    /// over the docs both have, so the map keeps its orientation. `why` goes to the log.
    public func fit(docs: [IndexDoc], space: String?, why: String) async {
        guard let engine = Self.engine else { problem = "no layout engine in this app"; return }
        guard !running, docs.count >= 10, let dim = docs.first?.vec.count, dim > 0 else { return }
        running = true; problem = nil; progress = "laying out \(docs.count) docs…"
        HubLog.shared.add(.info, "map layout: fitting \(docs.count) docs (\(why))")
        let k = min(self.k, docs.count - 1)
        var data = [Float](); data.reserveCapacity(docs.count * dim)
        for d in docs { data.append(contentsOf: d.vec) }
        let t0 = Date()
        let old = (ids: ids, xyz: xyz), oldIndex = index
        do {
            let r = try await engine(data, docs.count, dim, k, Self.minDist, 7)
            guard r.xyz.count == docs.count * 3 else { throw LayoutError.badShape }
            var pts = Self.unpack(Data(bytes: r.xyz, count: r.xyz.count * 4))
            // centre, scale to the unit cube by the 98th percentile (outliers must not shrink the map)
            pts = Self.normalise(pts)
            if !old.xyz.isEmpty {
                let shared = docs.indices.compactMap { i in oldIndex[docs[i].id].map { (i, $0) } }
                if shared.count >= 10 { pts = Self.align(pts, onto: old.xyz, pairs: shared) }
            }
            let secs = Date().timeIntervalSince(t0)
            xyz = pts; ids = docs.map(\.id); knn = r.knn; self.k = k
            index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
            meta = Meta(space: space ?? "", n: docs.count, k: k, minDist: Self.minDist, built: Date(), seconds: secs, engine: Self.engineName)
            save()
            progress = String(format: "laid out %d docs in %.1f s", docs.count, secs)
            HubLog.shared.add(.info, "map layout: \(docs.count) docs in \(String(format: "%.1f", secs)) s · k \(k) · \(Self.engineName)")
        } catch {
            problem = "map layout failed: \(error)"
            HubLog.shared.add(.error, problem!)
        }
        running = false
    }

    enum LayoutError: Error { case badShape }

    /// After the index changed: drop docs that are gone, place new docs at the rank-weighted mean of their k nearest
    /// existing neighbours (by cosine over the vectors). Returns how many were placed. No re-fit here.
    @discardableResult
    public func reconcile(docs: [IndexDoc]) -> Int {
        guard meta != nil, !xyz.isEmpty, !running else { return 0 }
        let present = Set(docs.map(\.id))
        if ids.contains(where: { !present.contains($0) }) {   // drop rows whose docs are gone (compact, keep order)
            var keepXYZ: [SIMD3<Float>] = [], keepIds: [String] = [], keepKNN: [Int32] = []
            var remap = [Int32](repeating: -1, count: ids.count)
            for (i, id) in ids.enumerated() where present.contains(id) { remap[i] = Int32(keepIds.count); keepIds.append(id); keepXYZ.append(xyz[i]) }
            if knn.count == ids.count * k {
                for (i, id) in ids.enumerated() where present.contains(id) {
                    for j in 0..<k { let n = knn[i * k + j]; keepKNN.append(n >= 0 ? remap[Int(n)] : -1) }
                }
            }
            xyz = keepXYZ; ids = keepIds; knn = keepKNN
            index = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        }
        let fresh = docs.filter { index[$0.id] == nil }
        guard !fresh.isEmpty else { return 0 }
        let t0 = Date()
        // the existing docs' vectors, in `ids` order, for the neighbour search
        let byId = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let base = ids.map { byId[$0]?.vec ?? [] }
        var placed = 0
        for d in fresh {
            guard let p = Self.place(d.vec, among: base, xyz: xyz, k: min(k, base.count)) else { continue }
            index[d.id] = ids.count; ids.append(d.id); xyz.append(p.position)
            if knn.count == (ids.count - 1) * k { knn.append(contentsOf: p.neighbours.map(Int32.init) + [Int32](repeating: -1, count: max(0, k - p.neighbours.count))) }
            placed += 1
        }
        meta?.n = ids.count; meta?.placed += placed
        save()
        HubLog.shared.add(.info, String(format: "map layout: placed %d new docs among their neighbours in %.0f ms", placed, Date().timeIntervalSince(t0) * 1000))
        return placed
    }

    /// The rank-weighted mean of the k nearest (cosine) existing positions — the start umap-learn's transform uses.
    nonisolated static func place(_ v: [Float], among base: [[Float]], xyz: [SIMD3<Float>], k: Int) -> (position: SIMD3<Float>, neighbours: [Int])? {
        guard !v.isEmpty, !base.isEmpty, k > 0 else { return nil }
        var best: [(Int, Float)] = []
        for (j, b) in base.enumerated() where b.count == v.count {
            let s = vDSP.dot(v, b)
            if best.count < k { best.append((j, s)); best.sort { $0.1 > $1.1 } }
            else if s > best[best.count - 1].1 { best[best.count - 1] = (j, s); best.sort { $0.1 > $1.1 } }
        }
        guard !best.isEmpty else { return nil }
        var p = SIMD3<Float>(repeating: 0), w: Float = 0
        for (rank, (j, _)) in best.enumerated() { let wj = 1 / Float(rank + 1); p += xyz[j] * wj; w += wj }
        return (p / w, best.map(\.0))
    }

    /// Centre on the mean, scale so the 98th percentile radius is 0.5 (the unit cube, outliers outside it).
    nonisolated static func normalise(_ p: [SIMD3<Float>]) -> [SIMD3<Float>] {
        guard p.count > 1 else { return p }
        var mean = SIMD3<Float>(repeating: 0); for v in p { mean += v }; mean /= Float(p.count)
        let r = p.map { simd_length($0 - mean) }.sorted()
        let scale = r[min(r.count - 1, Int(Double(r.count) * 0.98))]
        guard scale > 0 else { return p.map { $0 - mean } }
        return p.map { ($0 - mean) * (0.5 / scale) }
    }

    /// Kabsch: the rotation (and one scale) that moves `new` onto `old` over the paired rows (new row, old row).
    nonisolated static func align(_ new: [SIMD3<Float>], onto old: [SIMD3<Float>], pairs: [(Int, Int)]) -> [SIMD3<Float>] {
        guard pairs.count >= 3 else { return new }
        var cn = SIMD3<Float>(), co = SIMD3<Float>()
        for (a, b) in pairs { cn += new[a]; co += old[b] }
        cn /= Float(pairs.count); co /= Float(pairs.count)
        var h = simd_float3x3(0)   // Σ (new − cn)(old − co)ᵀ
        var varNew: Float = 0
        for (a, b) in pairs {
            let x = new[a] - cn, y = old[b] - co
            h += simd_float3x3(columns: (x * y.x, x * y.y, x * y.z))   // column j = x * y_j  →  h[i][j] = x_i y_j
            varNew += simd_length_squared(x)
        }
        // SVD of h via the eigen-decomposition of hᵀh (Jacobi): h = U Σ Vᵀ, R = V Uᵀ
        let hth = h.transpose * h
        let (evals, V) = jacobiEigen(hth)
        let sigma = SIMD3(sqrt(max(0, evals.x)), sqrt(max(0, evals.y)), sqrt(max(0, evals.z)))
        var U = simd_float3x3(0)
        for j in 0..<3 {
            let col = h * V[j]
            U[j] = sigma[j] > 1e-8 ? col / sigma[j] : SIMD3(0, 0, 0)
        }
        if sigma.z <= 1e-8 { U[2] = simd_normalize(simd_cross(U[0], U[1])) }   // a degenerate third axis: complete the frame
        var R = U * V.transpose    // maps old-centred → new-centred? we need new → old: R = V Uᵀ in the x→y convention below
        R = V * U.transpose
        if R.determinant < 0 { var V2 = V; V2[2] = -V2[2]; R = V2 * U.transpose }
        let scale = varNew > 0 ? (sigma.x + sigma.y + sigma.z) / varNew : 1
        return new.map { R * (($0 - cn) * scale) + co }
    }

    /// Eigenvalues and eigenvectors (columns) of a symmetric 3×3, by cyclic Jacobi rotations.
    nonisolated static func jacobiEigen(_ m: simd_float3x3) -> (SIMD3<Float>, simd_float3x3) {
        var a = m, v = matrix_identity_float3x3
        for _ in 0..<30 {
            var off: Float = 0
            for p in 0..<3 { for q in (p + 1)..<3 { off += a[q][p] * a[q][p] } }
            if off < 1e-12 { break }
            for p in 0..<3 { for q in (p + 1)..<3 {
                let apq = a[q][p]; if abs(apq) < 1e-12 { continue }
                let theta = (a[q][q] - a[p][p]) / (2 * apq)
                let t = (theta >= 0 ? 1 : -1) / (abs(theta) + sqrt(theta * theta + 1))
                let c = 1 / sqrt(t * t + 1), s = t * c
                var J = matrix_identity_float3x3
                J[p][p] = c; J[q][q] = c; J[q][p] = s; J[p][q] = -s
                a = J.transpose * a * J
                v = v * J
            } }
        }
        return (SIMD3(a[0][0], a[1][1], a[2][2]), v)
    }
}

extension GHIndex {
    /// This index's 3-D layout (lazy, one per index).
    public var layout: MapLayout {
        if let l = GHIndex.layouts[name] { return l }
        let l = MapLayout(stem: URL(fileURLWithPath: filePath).deletingPathExtension())
        GHIndex.layouts[name] = l
        return l
    }
    static var layouts: [String: MapLayout] = [:]
}
