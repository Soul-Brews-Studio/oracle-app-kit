import Foundation
#if os(macOS)
import AppKit
import SwiftUI
#endif

/// Every query an oracle app answers, told to the hub (issue #37). The apps are separate processes, so the fleet map
/// learns of a search in Pulse from a distributed notification — on this Mac only, no network. Any app in the login
/// session can observe one, so it carries little: the index, short hashes of the hits (the hub knows which of its rows
/// each is), the source, the asking oracle's name and the id of the app's trace entry. The words of the query stay in
/// the app's own query log, where the hub reads them.
public enum QueryBroadcast {
    public static let name = "co.laris.oracle.query"

    public struct Event: Sendable, Identifiable {
        public let id = UUID()
        public let app: String            // the bundle id that answered: co.laris.oracle.pulse
        public let index: String          // history/laris-co__pulse
        public let hashes: [String]       // the hits, best first, as hash(doc id)
        public let source: String         // page · map · mcp
        public let asker: String?         // "Neo" — an MCP caller's oracle
        public let trace: String?         // the answering app's TraceLog entry: its query is in <App>-queries.jsonl
    }

    /// 16 hex digits of FNV-1a 64 over a doc id: the same in every process, and no file path or title to an observer.
    public nonisolated static func hash(_ id: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    static func post(index: String, ids: [String], source: String, caller: String?, trace: UUID) {
        #if os(macOS)
        var info: [String: Any] = ["index": index, "hashes": ids.prefix(25).map(hash), "source": source, "trace": trace.uuidString]
        if let asker = caller?.components(separatedBy: " · ").first, !asker.isEmpty { info["asker"] = String(asker.prefix(40)) }
        DistributedNotificationCenter.default().postNotificationName(.init(name), object: Bundle.main.bundleIdentifier ?? "?",
                                                                    userInfo: info, deliverImmediately: true)
        #endif
    }

    /// The words of a traced query, from the answering app's query log (its last 64 KB); nil when not there.
    public nonisolated static func query(trace: String, app name: String) -> String? {
        let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ARRA Oracles/\(name)-queries.jsonl")
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > 65_536 ? end - 65_536 : 0)
        guard let d = try? h.readToEnd(), let line = d.split(separator: 0x0A).last(where: { String(decoding: $0, as: UTF8.self).contains(trace) }),
              let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { return nil }
        return o["query"] as? String
    }
}

#if os(macOS)
/// The hub's ear for QueryBroadcast: the last query another app answered (its own are in its TraceLog already).
@MainActor
public final class QueryListener: ObservableObject {
    public static let shared = QueryListener()
    @Published public private(set) var last: QueryBroadcast.Event?
    private var observer: NSObjectProtocol?

    public func start() {
        guard observer == nil else { return }
        let me = Bundle.main.bundleIdentifier
        observer = DistributedNotificationCenter.default().addObserver(forName: .init(QueryBroadcast.name), object: nil, queue: .main) { [weak self] n in
            guard let app = n.object as? String, app != me, let u = n.userInfo, let index = u["index"] as? String,
                  let hashes = u["hashes"] as? [String] else { return }
            let e = QueryBroadcast.Event(app: app, index: index, hashes: hashes, source: u["source"] as? String ?? "page",
                                         asker: u["asker"] as? String, trace: u["trace"] as? String)
            MainActor.assumeIsolated { self?.last = e }
        }
        HubLog.shared.add(.info, "fleet map: listening for every oracle app's queries (\(QueryBroadcast.name), this Mac only)")
    }
}

/// The hub's map of every oracle's memory (issue #37): the history index of each oracle that has run on this Mac,
/// plus the hub's own index of the fleet's issues, PRs and ψ notes, held as ONE index in memory ("fleet-map") with
/// its own layout over the union — related things sit together whichever oracle holds them. Every point keeps its
/// oracle, for its colour, its hover line and where a click goes.
@MainActor
public final class FleetMap: ObservableObject {
    public static let shared = FleetMap()
    /// The union, in memory only (never saved); its layout and groups are files like any index's: fleet-map.xyz …
    public let index = GHIndex(name: "fleet-map")

    public struct Member: Identifiable, Sendable {
        public let id: String           // the index: gh-index, history/laris-co__pulse
        public let oracle: String       // Pulse — "Fleet" for the hub's own index
        public let count: Int           // docs it adds (after removing those already in)
        public let built: Date?
    }
    @Published public private(set) var members: [Member] = []
    /// "reading Neo's memory…" while loading, empty otherwise
    @Published public private(set) var loading = ""
    @Published public private(set) var loaded: Date?
    /// doc id → its oracle
    public private(set) var oracleOf: [String: String] = [:]
    private var task: Task<Void, Never>?
    /// What was read: each member file's date, and the hub's own index's build — a change means read again.
    private var readStamps: [String: Date] = [:]
    private var lastMissReload = Date.distantPast

    /// Reads every member off the main actor and holds the union — the first time, and again whenever a member changed
    /// since (an oracle app saved its index, the hub refreshed its own, a new oracle appeared). Callers at the same
    /// time share one read.
    public func load(why: String) async {
        if let task { await task.value }
        guard loaded == nil || isStale else { return }
        if let task { await task.value; return }   // another caller started a read while this one waited
        let t = Task { await self.build(why: why) }
        task = t
        await t.value
        if task == t { task = nil }
    }

    /// A member changed since the read: its file's date, a new or gone history index, the hub's own index rebuilt.
    public var isStale: Bool { loaded != nil && Self.stamps() != readStamps }

    /// A heard query named docs the union does not have: read again, at most once a minute.
    func missed(_ n: Int) {
        guard Date().timeIntervalSince(lastMissReload) > 60 else { return }
        lastMissReload = Date()
        HubLog.shared.add(.info, "fleet map: \(n) hits are not on the map yet — reading every oracle's index again")
        Task { await load(why: "\(n) heard hits not on the map") }
    }

    /// Each member's date: the history index files' modification dates, and gh-index's build.
    static func stamps() -> [String: Date] {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ARRA Oracles", isDirectory: true)
        var out: [String: Date] = [:]
        for name in historyIndexes() {
            out[name] = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(name + ".json").path)[.modificationDate]) as? Date
        }
        out["gh-index"] = GHIndex.shared.built ?? .distantPast
        return out
    }

    private func build(why: String) async {
        let t0 = Date()
        let histories = Self.historyIndexes()
        let known = Set(histories.map(Self.oracle(ofIndex:)))
        var docs: [IndexDoc] = [], seen = Set<String>(), oracleOf: [String: String] = [:], members: [Member] = []
        var space: String?, built: Date?
        func add(_ name: String, _ list: [IndexDoc], _ b: Date?, _ sp: String?, oracle: (IndexDoc) -> String) {
            if space == nil { space = sp }
            guard sp == nil || sp == space else {   // one layout needs one vector space (the parity check per index)
                HubLog.shared.add(.error, "fleet map: \(name) is in another vector space — left out; re-embed it in its app")
                return
            }
            var n = 0
            for d in list where seen.insert(d.id).inserted { docs.append(d); oracleOf[d.id] = oracle(d); n += 1 }
            members.append(Member(id: name, oracle: name.hasPrefix("history/") ? Self.oracle(ofIndex: name) : "Fleet", count: n, built: b))
            if let b { built = max(built ?? b, b) }
        }
        // the hub's own index is in memory already: its docs without their texts
        let stamps = Self.stamps()
        let gh = GHIndex.shared
        add(gh.name, gh.docs.map { var d = $0; d.text = nil; return d }, gh.built, gh.space) { Self.oracle(ofRepo: $0.repo, known: known) }
        for name in histories {
            loading = "reading \(Self.oracle(ofIndex: name))'s memory…"
            guard let r = await Task.detached(priority: .utility, operation: { GHIndex.readDocs(name: name) }).value else {
                // missing, of another model, or caught between the two files of a save three times running
                let dir = "$HOME/Library/Application Support/ARRA Oracles/" + name
                HubLog.shared.add(.error, "fleet map: could not read \(name) — left out until the next read. To look: ls -l \"\(dir)\".*")
                continue
            }
            let o = Self.oracle(ofIndex: name)
            add(name, r.docs, r.built, r.space) { _ in o }
        }
        index.adopt(docs, space: space, built: built)
        self.oracleOf = oracleOf; self.members = members; loading = ""; loaded = Date(); readStamps = stamps
        // docs new since the fleet's layout: placing them one by one would scan 72k vectors each on the main actor, so
        // past 1 % (or 300) the layout is fitted again in the background; fewer wait off the map until then
        let layout = index.layout
        if layout.meta != nil, !layout.running {
            let fresh = docs.filter { layout.row(of: $0.id) == nil }.count
            if fresh >= max(300, docs.count / 100) {
                let why = "\(grouped(fresh)) docs new since the fleet's layout"
                Task { await layout.fit(docs: index.docs, space: index.space, why: why) }
            } else if fresh > 0 {
                HubLog.shared.add(.info, "fleet map: \(fresh) new docs wait off the map until the next fit (1 % of \(grouped(docs.count)))")
            }
        }
        HubLog.shared.add(.info, String(format: "fleet map: %@ docs from %d indexes in %.1f s (%@) — %@", grouped(docs.count), members.count,
                                        Date().timeIntervalSince(t0), why, members.map { "\($0.oracle) \(grouped($0.count))" }.joined(separator: " · ")))
    }

    /// Every history index on disk — one per oracle app that has read its sessions; no list to keep up to date.
    nonisolated static func historyIndexes() -> [String] {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARRA Oracles/history", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") && !$0.dropLast(5).contains(".") }   // not .xyz.json, .clusters.json …
            .map { "history/" + $0.dropLast(5) }.sorted()
    }

    /// history/laris-co__neo-oracle → Neo, history/laris-co__pulse → Pulse
    nonisolated static func oracle(ofIndex name: String) -> String {
        guard name.hasPrefix("history/") else { return "Fleet" }
        return oracle(ofRepoName: String(name.split(separator: "__").last ?? Substring(name)))
    }
    nonisolated static func oracle(ofRepoName repo: String) -> String {
        let base = repo.hasSuffix("-oracle") ? String(repo.dropLast(7)) : repo
        return base.prefix(1).uppercased() + base.dropFirst()
    }
    /// An issue, PR or ψ note of the hub's index belongs to the oracle whose repo it is in; the rest to the fleet.
    nonisolated static func oracle(ofRepo slug: String, known: Set<String>) -> String {
        let o = oracle(ofRepoName: String(slug.split(separator: "/").last ?? ""))
        return known.contains(o) ? o : "Fleet"
    }

    /// Each oracle's own colour (its app's accent); one made from the name for an oracle not listed here.
    public nonisolated static func color(_ oracle: String) -> NSColor {
        switch oracle.lowercased() {
        case "neo": return NSColor(red: 0.39, green: 0.71, blue: 0.96, alpha: 1)      // #64b5f6
        case "pulse": return NSColor(red: 0.94, green: 0.33, blue: 0.31, alpha: 1)    // #ef5350
        case "nexus": return NSColor(red: 0.67, green: 0.28, blue: 0.74, alpha: 1)    // #ab47bc
        case "athena": return NSColor(red: 0.83, green: 0.65, blue: 0.17, alpha: 1)   // #d4a72c
        case "fleet": return NSColor(red: 0.61, green: 0.55, blue: 1, alpha: 1)        // the hub's #9b8cff
        default:
            let h = oracle.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
            return NSColor(hue: CGFloat(h % 360) / 360, saturation: 0.55, brightness: 0.92, alpha: 1)
        }
    }

    /// The oracle that holds ≥ 80 % of a group's docs (its name goes in front of the group's), else nil.
    public func dominant(labels: [Int], ids: [String]) -> [Int: String] {
        guard labels.count == ids.count else { return [:] }
        var count: [Int: [String: Int]] = [:], size: [Int: Int] = [:]
        for (i, g) in labels.enumerated() { size[g, default: 0] += 1; count[g, default: [:]][oracleOf[ids[i]] ?? "Fleet", default: 0] += 1 }
        var out: [Int: String] = [:]
        for (g, c) in count { if let m = c.max(by: { $0.value < $1.value }), Double(m.value) >= 0.8 * Double(size[g] ?? 1) { out[g] = m.key } }
        return out
    }

    /// Tests: the doc → oracle map without reading any index.
    func setOracles(_ m: [String: String]) { oracleOf = m }

    /// The installed app of an oracle (co.laris.oracle.<name>), for "Open in Pulse".
    public static func app(of oracle: String) -> URL? { HubParse.installedApps()[oracle.lowercased()] }
}

/// The hub's Map page: the fleet's union, read in the background (again when a member changed), then the same map as
/// an oracle's.
public struct FleetMapPage: View {
    @ObservedObject private var fleet = FleetMap.shared
    @ObservedObject private var index = FleetMap.shared.index
    let accent: Color
    public init(accent: Color) { self.accent = accent }
    public var body: some View {
        if #available(macOS 26, *) {
            Group {
                if !index.docs.isEmpty {
                    MapView(name: "The fleet", accent: accent, index: index, fleet: fleet)
                } else if fleet.loaded == nil || !fleet.loading.isEmpty {
                    VStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text(fleet.loading.isEmpty ? "reading every oracle's memory…" : fleet.loading).font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Nothing indexed on this Mac yet").font(.headline)
                        Text("Open Search issues & PRs and press Run batch, or open an oracle's app and scan its sessions. To see what exists:")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("ls -la \"$HOME/Library/Application Support/ARRA Oracles\" \"$HOME/Library/Application Support/ARRA Oracles/history\"")
                            .font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .task { await fleet.load(why: "Map page opened") }
        } else {
            Text("The map needs macOS 26").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
#endif
