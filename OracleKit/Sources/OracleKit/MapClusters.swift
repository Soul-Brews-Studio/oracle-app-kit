#if os(macOS)
import Foundation
import Accelerate
import NaturalLanguage

/// The map's groups (issue #35): docs clustered in the 768-d space (spherical k-means — cosine, deterministic) on two
/// levels — about a dozen regions (k at the elbow of 8…16), each split again into leaves (~80 on a big memory) that
/// the map names when zoomed in. A group is named by its c-TF-IDF keywords (the words frequent in it and rare
/// elsewhere), then titled by the on-device model (ClusterTitler) in the background. Cached in <index>.groups.json
/// (apps before v3 keep their own <index>.clusters.json, so the two never overwrite each other): after a change
/// without a re-fit every doc keeps its groups and a new one joins its nearest; a re-fit groups again, and a group
/// keeps its title when it shares 80 % of its members with an old one, so only the changed groups are titled again.
@MainActor
public final class MapClusters: ObservableObject {
    public struct Group: Codable, Sendable, Identifiable {
        public var id: Int
        public var count: Int
        public var keywords: [String]
        /// The model's title; nil until titled, and when no model could title it (the keywords name it then).
        public var title: String?
        /// Who named it: "apple-fm", "apple-fm th", or "keywords · <why>"; nil = not tried yet.
        public var model: String?
        /// The region a leaf belongs to (nil on the top level).
        public var parent: Int?
        /// The texts nearest the group's centre — the model reads them with the keywords.
        public var examples: [String]?
        public var name: String { title ?? (keywords.isEmpty ? "\(count) memories" : keywords.prefix(3).joined(separator: " · ")) }
    }
    struct File: Codable {
        var built: Date; var n: Int; var labels: [Int]; var groups: [Group]; var version: Int?
        var leafLabels: [Int]?; var leaves: [Group]?; var ids: [String]?; var titled: Date?
        var joined: Int?   // docs that joined by nearest centre since the last grouping
    }
    static let version = 3   // bump when grouping or naming changes: cached groups are recomputed

    @Published public private(set) var groups: [Group] = []
    /// region per layout row (same order as MapLayout.ids)
    @Published public private(set) var labels: [Int] = []
    /// The second level: each region split again; the map names these when zoomed in.
    @Published public private(set) var leaves: [Group] = []
    /// leaf per layout row
    @Published public private(set) var leafLabels: [Int] = []
    @Published public private(set) var running = false
    /// "titling 5 of 92" while the model names groups, empty otherwise.
    @Published public private(set) var titling = ""
    /// When the titles were last finished.
    @Published public private(set) var titled: Date?
    /// Bumps whenever the labels change (a regroup, docs placed or gone) — the map's copy of them follows it.
    @Published public private(set) var revision = 0
    /// The layout ids the labels belong to (row i of `labels` is the doc `layoutIds[i]`).
    public var layoutIds: [String] { ids }
    private let url: URL
    private var built: Date?
    private var version = 0
    private var ids: [String] = []        // the layout ids the labels belong to
    private var joined = 0                // docs that joined by nearest centre since the last grouping
    /// Past this share of joined docs the memory is grouped again (the groups no longer describe it).
    static let regroupShare = 0.25
    private var generation = 0            // a new grouping stops the titling of the old one
    private var titleTask: Task<Void, Never>?
    private var saving: Task<Void, Never>?

    init(stem: URL) {
        url = URL(fileURLWithPath: stem.path + ".groups.json")
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let f = try? d.decode(File.self, from: data) {
            groups = f.groups; labels = f.labels; built = f.built; version = f.version ?? 1
            leaves = f.leaves ?? []; leafLabels = f.leafLabels ?? []; ids = f.ids ?? []; titled = f.titled; joined = f.joined ?? 0
        }
    }

    /// How many groups each namer named ("apple-fm" 88, "keywords" 4) — Settings shows it.
    public var namedBy: [(String, Int)] {
        Dictionary(grouping: (groups + leaves).compactMap(\.model), by: { $0.hasPrefix("keywords") ? "keywords" : $0 })
            .map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
    }

    /// The groups for the layout. The groups live in the 768-d space, so a re-fit (which only moves the 3-D layout)
    /// changes nothing: every doc keeps its groups by id and a new doc joins its nearest. The memory is grouped again
    /// only with no groups, a new version, or once more than a quarter of the docs joined that way. Then untitled
    /// groups are titled in the background — a plain relaunch finds them all titled and asks the model nothing.
    public func refresh(layout: MapLayout, docs: [IndexDoc]) async {
        guard let meta = layout.meta, !running, layout.ids.count >= 50 else { return }
        if version == Self.version, !labels.isEmpty, labels.count == leafLabels.count, labels.count == ids.count {
            let known = Set(ids), fresh = layout.ids.reduce(0) { $0 + (known.contains($1) ? 0 : 1) }
            if Double(joined + fresh) <= Self.regroupShare * Double(layout.ids.count) {
                if ids != layout.ids { await realign(layout: layout, docs: docs) }
                if built != meta.built { built = meta.built; save() }
                startTitling(); return
            }
        }
        await regroup(layout: layout, docs: docs, built: meta.built)
        startTitling()
    }

    /// Settings → Relabel groups: every group is titled again. Each keeps its title until the new one arrives, and
    /// nothing happens while the model can't answer.
    public func relabel() {
        guard !running, titleTask == nil, !(groups.isEmpty && leaves.isEmpty) else { return }
        if let why = ClusterTitler.unavailable { HubLog.shared.add(.error, "map groups: relabel needs Apple's model — \(why)"); return }
        for i in groups.indices { groups[i].model = nil }
        for i in leaves.indices { leaves[i].model = nil }
        HubLog.shared.add(.info, "map groups: relabel asked — \(groups.count + leaves.count) groups to title")
        startTitling()
    }
    /// Relabel can run: groups, the model, no grouping or titling under way.
    public var canRelabel: Bool { !running && titling.isEmpty && !(groups.isEmpty && leaves.isEmpty) && ClusterTitler.unavailable == nil }

    private func regroup(layout: MapLayout, docs: [IndexDoc], built b: Date) async {
        let byId = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let rows = layout.ids.map { byId[$0] }
        let dim = rows.first(where: { $0 != nil })??.vec.count ?? 0
        guard dim > 0 else { return }
        running = true
        generation += 1; titleTask?.cancel(); titleTask = nil; titling = ""
        var X = [Float](); X.reserveCapacity(rows.count * dim)
        var texts: [String] = [], shown: [String] = []
        for r in rows {
            if let r, r.vec.count == dim {
                X.append(contentsOf: r.vec)
                // a session piece is named by what was said (its snippet), not the session's title; of a /command, what follows it
                let said = r.snippet.hasPrefix("/") ? String(r.snippet.drop { !$0.isWhitespace }) : r.snippet
                texts.append(r.kind == "history" ? said : r.title + " " + r.snippet)
                shown.append(r.kind == "history" ? said : r.title)
            } else { X.append(contentsOf: [Float](repeating: 0, count: dim)); texts.append(""); shown.append("") }
        }
        let n = rows.count, newIds = layout.ids
        let oldGroups = groups, oldLabels = labels, oldLeaves = leaves, oldLeafLabels = leafLabels, oldIds = ids
        let warm = version == Self.version
        let t0 = Date()
        let r = await Task.detached(priority: .utility) { () -> Grouping in
            // a re-fit starts from the groups it had, so they stay (and keep their titles) unless the docs moved
            let seed = warm ? Self.seed(oldIds: oldIds, labels: oldLabels, groups: oldGroups, leafLabels: oldLeafLabels, leaves: oldLeaves,
                                         newIds: newIds, X: X, dim: dim) : nil
            return Self.group(X, n: n, dim: dim, texts: texts, shown: shown, seed: seed)
        }.value
        var g = r.groups, l = r.leaves
        let kept = Self.carry(into: &g, labels: r.labels, ids: newIds, from: oldGroups, labels: oldLabels, ids: oldIds)
            + Self.carry(into: &l, labels: r.leafLabels, ids: newIds, from: oldLeaves, labels: oldLeafLabels, ids: oldIds)
        groups = g; labels = r.labels; leaves = l; leafLabels = r.leafLabels; ids = newIds
        built = b; version = Self.version; revision += 1; joined = 0
        save()
        HubLog.shared.add(.info, String(format: "map groups: %d docs in %d regions (k %d at the elbow) and %d leaves in %.1f s (%@) — %d titles kept",
                                        n, g.count, r.k, l.count, Date().timeIntervalSince(t0), r.timing, kept))
        running = false
    }

    /// The layout changed without a re-fit (docs placed among their neighbours, docs gone): every doc keeps its region
    /// and leaf, by id; a new one joins the region, then the leaf of that region, whose centre (the members' mean,
    /// normalised) is closest in cosine. No re-grouping, no new titles.
    private func realign(layout: MapLayout, docs: [IndexDoc]) async {
        let target = layout.ids
        let byId = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let vecs = target.map { byId[$0]?.vec ?? [] }
        guard let dim = vecs.first(where: { !$0.isEmpty })?.count else { return }
        let oldIds = ids, oldTop = labels, oldLeaf = leafLabels
        let regions = groups.map(\.id), leafParent = leaves.map { ($0.id, $0.parent ?? -1) }
        let gen = generation, before = ids.count
        let (top, leaf, fresh) = await Task.detached(priority: .utility) {
            Self.realigned(oldIds: oldIds, labels: oldTop, leafLabels: oldLeaf, regions: regions, leafParent: leafParent, ids: target, vecs: vecs, dim: dim)
        }.value
        guard gen == generation, !running, layout.ids == target else { return }   // moved meanwhile: the next refresh redoes it
        var topCount: [Int: Int] = [:], leafCount: [Int: Int] = [:]
        for x in top { topCount[x, default: 0] += 1 }
        for x in leaf { leafCount[x, default: 0] += 1 }
        groups = groups.map { var x = $0; x.count = topCount[x.id] ?? 0; return x }.filter { $0.count > 0 }
        leaves = leaves.map { var x = $0; x.count = leafCount[x.id] ?? 0; return x }.filter { $0.count > 0 }
        labels = top; leafLabels = leaf; ids = target; revision += 1; joined += fresh
        save()
        HubLog.shared.add(.info, "map groups: \(fresh) new docs joined their nearest groups, \(before + fresh - target.count) gone — relabelled 0 of \(groups.count + leaves.count)")
    }

    /// The labels for a new list of ids: an old doc keeps its region and leaf; a new one joins the region, then the
    /// leaf of that region, whose centre is closest in cosine. Returns the labels and how many docs joined.
    nonisolated static func realigned(oldIds: [String], labels: [Int], leafLabels: [Int], regions: [Int], leafParent: [(Int, Int)],
                                      ids target: [String], vecs: [[Float]], dim: Int) -> (top: [Int], leaf: [Int], fresh: Int) {
        var was: [String: (Int, Int)] = [:]
        was.reserveCapacity(oldIds.count)
        for (i, id) in oldIds.enumerated() where i < labels.count && i < leafLabels.count { was[id] = (labels[i], leafLabels[i]) }
        let k = (regions.max() ?? 0) + 1, L = (leafParent.map(\.0).max() ?? 0) + 1
        var top = [Int](repeating: -1, count: target.count), leaf = [Int](repeating: -1, count: target.count)
        for (i, id) in target.enumerated() { if let w = was[id] { top[i] = w.0; leaf[i] = w.1 } }
        let C = centres(vecs, labels: top, k: k, dim: dim), LC = centres(vecs, labels: leaf, k: L, dim: dim)
        var fresh = 0
        for i in target.indices where top[i] < 0 {
            let g = nearest(vecs[i], in: C, dim: dim, among: regions)
            let mine = leafParent.filter { $0.1 == g }.map(\.0)
            top[i] = g; leaf[i] = nearest(vecs[i], in: LC, dim: dim, among: mine.isEmpty ? leafParent.map(\.0) : mine); fresh += 1
        }
        return (top, leaf, fresh)
    }

    /// Titles every group the model has not named yet, one at a time in the background (~1 s each), regions first.
    private func startTitling() {
        guard titleTask == nil, !running, (groups + leaves).contains(where: { $0.model == nil }) else { return }
        let gen = generation
        titleTask = Task { [weak self] in
            await self?.titleAll(generation: gen)
            if let self, self.generation == gen { self.titleTask = nil }
        }
    }

    private func titleAll(generation gen: Int) async {
        let todo = groups.indices.filter { groups[$0].model == nil }.map { (true, $0) }
            + leaves.indices.filter { leaves[$0].model == nil }.map { (false, $0) }
        guard !todo.isEmpty else { return }
        let total = groups.count + leaves.count, t0 = Date()
        var by: [String: Int] = [:]
        for (n, (top, i)) in todo.enumerated() {
            guard gen == generation, !Task.isCancelled else { return }
            titling = "titling \(n + 1) of \(todo.count)"
            let g = top ? groups[i] : leaves[i]
            // a leaf is told its region's title, so it says what sets it apart instead of repeating the region
            let region = top ? nil : groups.first { $0.id == g.parent }.flatMap(\.title)
            let siblings = top ? [] : leaves.filter { $0.parent == g.parent && $0.id != g.id }.compactMap(\.title)
            let r = await ClusterTitler.title(keywords: g.keywords, examples: g.examples ?? [], within: region, avoiding: siblings + (region.map { [$0] } ?? []))
            guard gen == generation, !Task.isCancelled else { return }
            if !r.final {   // the model can't be asked now: the rest stay untitled and are tried on the next map open
                titling = ""; save()
                HubLog.shared.add(.error, "map groups: titling paused after \(n) of \(todo.count) — \(r.model.replacingOccurrences(of: "keywords · ", with: ""))")
                return
            }
            if top { groups[i].title = r.title; groups[i].model = r.model } else { leaves[i].title = r.title; leaves[i].model = r.model }
            by[r.model.hasPrefix("keywords") ? "keywords" : r.model, default: 0] += 1
            if ClusterTitler.mostlyThai(g.keywords) {   // the model does not list Thai: each Thai group says what named it
                HubLog.shared.add(.info, "map groups: Thai group “\(g.keywords.prefix(3).joined(separator: " "))” → “\(r.title ?? g.name)” by \(r.model)")
            }
            if (n + 1) % 12 == 0 { save() }
        }
        titling = ""; titled = Date()
        save()
        HubLog.shared.add(.info, String(format: "map groups: relabelled %d of %d in %.0f s — %@", todo.count, total, Date().timeIntervalSince(t0),
                                        by.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · ")))
    }

    /// Writes off the main actor, one save after another.
    private func save() {
        guard let built else { return }
        let f = File(built: built, n: labels.count, labels: labels, groups: groups, version: Self.version,
                     leafLabels: leafLabels, leaves: leaves, ids: ids, titled: titled, joined: joined)
        let url = url, previous = saving
        saving = Task.detached(priority: .utility) {
            await previous?.value
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
            try? e.encode(f).write(to: url, options: .atomic)
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
#endif

/// A buffer's base for `concurrentPerform` workers that each write a disjoint range of it.
struct SlicePointer<T>: @unchecked Sendable {
    let p: UnsafeMutablePointer<T>
    init(_ p: UnsafeMutablePointer<T>) { self.p = p }
}
