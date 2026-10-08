#if os(iOS)
import SwiftUI
import UIKit
import simd

// MARK: - Map: the memory as one space — RealityKit on iOS 26, a flat scatter everywhere else

/// The Map as the Mac laid it out, unpacked. Positions are centred on the cloud and scaled so 80 % of the points lie within
/// 0.45 (MapFrame), then strays are pulled onto a shell at 0.8: the camera frames the body of the cloud, not three strays.
/// Picking and drawing use these.
struct PhoneMapModel: Sendable {
    /// Which map this is: copies of a model share it, a model made from a new answer of the Mac has its own. A scene built
    /// from one map compares it to know when the page holds another (its picks are rows of the map it was built from).
    let stamp = UUID()
    let ids: [String], kinds: [String], titles: [String]
    let xyz: [SIMD3<Float>]
    let knn: [Int32]
    let k: Int
    let labels: [Int]
    let groups: [CompanionAPI.MapGroup]
    /// The rows the Map draws, per kind. A row of any other kind is not here: the Mac sends kind "" (and the id as its title) for
    /// a point whose doc left the index since the layout was made — no colour, no legend key, nothing to say. It is never
    /// drawn, picked, or listed among a point's neighbours.
    let rowsOfKind: [String: [Int]]
    var count: Int { ids.count }
    /// How many rows are drawn: what the legend adds up to.
    let drawnCount: Int

    /// nil when the arrays disagree about how many points there are.
    init?(_ d: CompanionAPI.MapData) {
        let n = d.ids.count
        guard n > 0, d.kinds.count == n, d.titles.count == n, d.xyz.count == n * 12, d.k >= 0, d.k <= d.knn.count / (n * 4),
              d.knn.count == n * d.k * 4 else { return nil }
        ids = d.ids; kinds = d.kinds; titles = d.titles; k = d.k; groups = d.groups
        labels = d.labels.count == n ? d.labels : []
        let laid = d.xyz.withUnsafeBytes { raw in
            (0..<n).map { i in SIMD3<Float>(raw.loadUnaligned(fromByteOffset: i * 12, as: Float.self),
                                            raw.loadUnaligned(fromByteOffset: i * 12 + 4, as: Float.self),
                                            raw.loadUnaligned(fromByteOffset: i * 12 + 8, as: Float.self)) }
        }
        let frame = MapFrame.fit(laid, drawn: d.kinds.map { PhoneStyle.kinds.contains($0) })
        xyz = laid.map { p in
            let q = (p - frame.centre) * frame.scale, r = simd_length(q)
            return r > 0.8 ? q * (0.8 / r) : q
        }
        let kk = d.k
        knn = d.knn.withUnsafeBytes { raw in (0..<(n * kk)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Int32.self) } }
        var by: [String: [Int]] = [:]
        for (i, kind) in d.kinds.enumerated() where PhoneStyle.kinds.contains(kind) { by[kind, default: []].append(i) }
        rowsOfKind = by
        drawnCount = by.values.reduce(0) { $0 + $1.count }
    }

    /// A row that is on the map: in range, and of a kind the Map draws.
    func isDrawn(_ row: Int) -> Bool { row >= 0 && row < kinds.count && PhoneStyle.kinds.contains(kinds[row]) }

    /// The nearest neighbours of a row, closest first (the Mac's kNN graph).
    func neighbours(of row: Int) -> [Int] {
        guard k > 0, row >= 0, (row + 1) * k <= knn.count else { return [] }
        return knn[(row * k)..<(row * k + k)].compactMap { $0 >= 0 && isDrawn(Int($0)) ? Int($0) : nil }
    }
    func group(of row: Int) -> CompanionAPI.MapGroup? {
        guard row >= 0, row < labels.count else { return nil }
        return groups.first { $0.id == labels[row] }
    }
}

/// What the id of a doc says (IndexDoc.id): "owner/repo#12" is an issue or PR, "note:file:///…/ψ/inbox/a.md#1" a note's piece,
/// "hist:<hash>" a piece of a session. The Map carries no more than that, so this is all its panel can show.
enum PhoneMapDoc {
    static func issue(_ id: String) -> (repo: String, number: Int)? {
        guard let h = id.lastIndex(of: "#"), let n = Int(id[id.index(after: h)...]) else { return nil }
        return (String(id[..<h]), n)
    }
    static func url(kind: String, id: String) -> URL? {
        guard kind == "issue" || kind == "pr", let i = issue(id) else { return nil }
        return URL(string: "https://github.com/\(i.repo)/\(kind == "pr" ? "pull" : "issues")/\(i.number)")
    }
    /// "ψ/inbox/a.md" and its part, from a note's id.
    static func note(_ id: String) -> (path: String, part: Int?) {
        var s = id.hasPrefix("note:") ? String(id.dropFirst(5)) : id
        var part: Int?
        if let h = s.lastIndex(of: "#"), let n = Int(s[s.index(after: h)...]) { part = n; s = String(s[..<h]) }
        let path = URL(string: s)?.path ?? s
        if let r = path.range(of: "/ψ/") { return ("ψ/" + path[r.upperBound...], part) }
        return (path.split(separator: "/").suffix(2).joined(separator: "/"), part)
    }
    static func meta(kind: String, id: String) -> String {
        switch kind {
        case "issue", "pr": return "\(kind) \(id)"
        case "note": let n = note(id); return n.path + (n.part.map { " · part \($0 + 1)" } ?? "")
        default: return "a piece of a session"
        }
    }
}

/// One point of the Map: what it is, its group, and what is closest to it in meaning (the Mac's panel, as a sheet).
struct PhoneMapPanel: View {
    let model: PhoneMapModel
    let row: Int
    let accent: Color
    let select: (Int) -> Void
    let close: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    /// A row picked from an older map can be past the end of this one (the Mac laid it out again), or not drawn: draw nothing, never trap.
    var body: some View {
        if model.isDrawn(row) { page }
    }

    @ViewBuilder private var page: some View {
        let kind = model.kinds[row]
        let g = model.group(of: row)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Color(PhoneStyle.kindColor(kind, accent: accent))).frame(width: 9, height: 9).padding(.top, 6)
                    Text(model.titles[row]).font(.callout.weight(.semibold)).lineLimit(8).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Close")
                }
                Text(PhoneMapDoc.meta(kind: kind, id: model.ids[row])).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let u = PhoneMapDoc.url(kind: kind, id: model.ids[row]) {
                    Button { openURL(u) } label: { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.borderedProminent).tint(accent).controlSize(.small)
                } else if kind == "note" {
                    Button { WorkFormat.copy(PhoneMapDoc.note(model.ids[row]).path); copied = true } label: {
                        Label(copied ? "path copied" : "Copy its path on the Mac", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Text("A piece of a session. Search it on the Memory page to copy the command that reopens it.").font(.caption).foregroundStyle(.secondary)
                }
                if let g {
                    Divider()
                    Text("GROUP").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(accent)
                    Text(g.title ?? g.keywords.prefix(5).joined(separator: " · ")).font(.callout.weight(.medium))
                    if g.title != nil { Text(g.keywords.prefix(5).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    Text("\(grouped(g.count)) memories").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("CLOSEST IN MEANING").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.neighbours(of: row).prefix(15), id: \.self) { r in
                        Button { select(r); copied = false } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(Color(PhoneStyle.kindColor(model.kinds[r], accent: accent))).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.titles[r]).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(PhoneMapDoc.meta(kind: model.kinds[r], id: model.ids[r])).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }
}

struct PhoneMapView: View {
    @ObservedObject var store: OracleStore
    @ObservedObject private var client = CompanionClient.shared
    @State private var model: PhoneMapModel?
    @State private var mapData: CompanionAPI.MapData?   // what `model` was unpacked from: the same map read again changes nothing on screen
    @State private var failed: String?
    @State private var readAt: Date?                // when the map last read: a failing read keeps the map and says since when
    @State private var loading = false
    @State private var reading = false
    @State private var hidden: Set<String> = []     // kinds switched off in the legend
    @State private var flat = UserDefaults.standard.bool(forKey: "mapFlat")   // 2-D by choice; -mapFlat YES (tests)
    @State private var realityFailed = false        // RealityKit would not draw it here: the flat map takes over
    @State private var selected: Int?
    @State private var resetTick = 0
    @Environment(\.horizontalSizeClass) private var sizeClass
    private static var actionDone = false
    private var c: OracleConfig { store.config }
    private static var realityAvailable: Bool { if #available(iOS 26, *) { return true } else { return false } }

    var body: some View {
        Group {
            if client.isPaired { page } else {
                PhoneUnpaired(config: c, symbol: "point.3.filled.connected.trianglepath.dotted",
                              gives: "\(c.name)'s memory as one space: every session, ψ note, issue and PR a point, close means related. Drag to turn it, pinch to zoom, tap a point for what is next to it.")
            }
        }
        .navigationTitle("Map")
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            // taller than its half of the page (large text sizes, a short screen): the header scrolls and the map keeps the rest
            ViewThatFits(in: .vertical) {
                header
                ScrollView { header }
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            mapArea
        }
        .onReceive(NotificationCenter.default.publisher(for: .oraclePhoneReload)) { _ in Task { await load() } }
        .onAppear { Task { await load() } }
        .onChange(of: client.pairing) { model = nil; mapData = nil; selected = nil; readAt = nil; Task { await load() } }
        .onChange(of: client.reachable) { _, now in if now == true, failed != nil { Task { await load() } } }
        .sheet(isPresented: Binding(get: { shownRow != nil && sizeClass == .compact }, set: { if !$0 { selected = nil } })) {
            if let m = model, let r = shownRow {
                PhoneMapPanel(model: m, row: r, accent: c.color, select: { selected = $0 }, close: { selected = nil })
                    .presentationDetents([.fraction(0.34), .medium, .large]).presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationBackground(Color(uiColor: .systemBackground))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhoneHeader(eyebrow: "MAP", title: "\(c.name)'s map",
                        subtitle: model.map { "\(grouped($0.drawnCount)) memories in one space — close means related. " + (use3D ? "Drag to turn, pinch to zoom, tap a point." : "Drag to move, pinch to zoom, tap a point.") }
                            ?? "close means related", accent: c.color)
            if let m = model { legend(m) }
            if let failed, model != nil { PhoneReadFailure(problem: failed, since: readAt) }   // with no map yet the card below says it
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var use3D: Bool { Self.realityAvailable && !flat && !realityFailed }

    /// The selected row while it is a row of the map on screen. One from another map shows nothing (and the sheet stays shut)
    /// rather than another point's panel — or a trap: the sheet and the iPad's card both ask this, not `selected`.
    private var shownRow: Int? {
        guard let m = model, let r = selected, m.isDrawn(r) else { return nil }
        return r
    }

    private var mapArea: some View {
        ZStack(alignment: .bottomLeading) {
            if let m = model {
                if use3D { reality(m) } else { PhoneMapCanvas(model: m, accent: c.color, hidden: hidden, selected: $selected, resetTick: resetTick) }
                controls
                if let r = shownRow, sizeClass != .compact {
                    PhoneMapPanel(model: m, row: r, accent: c.color, select: { selected = $0 }, close: { selected = nil })
                        .environment(\.colorScheme, .dark)
                        .frame(width: 340).frame(maxHeight: 460)
                        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.color.opacity(0.45)))
                        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            } else if loading {
                VStack(spacing: 8) { ProgressView(); Text("reading the map from the Mac…").font(.callout).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failed {
                PhoneProblemCard(text: failed) { Task { await load() } }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PhoneStyle.mapBG)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .padding(.horizontal, 16).padding(.bottom, 14)
        .animation(.easeOut(duration: 0.18), value: selected)
    }

    @ViewBuilder private func reality(_ m: PhoneMapModel) -> some View {
        if #available(iOS 26, *) {
            PhoneMapReality(model: m, accent: c.color, hidden: hidden, selected: $selected, resetTick: resetTick, failed: { realityFailed = true })
        }
    }

    /// 3-D / flat, and back to the start view.
    private var controls: some View {
        HStack(spacing: 10) {
            if Self.realityAvailable && !realityFailed {
                Picker("", selection: $flat) { Text("3D").tag(false); Text("2D").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 100)
            }
            Button { resetTick += 1 } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel("Reset the view")
            if realityFailed { Text("3-D did not start here — flat map").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
        .padding(12)
    }

    /// The colour key, with counts; a tap hides or shows a kind.
    private func legend(_ m: PhoneMapModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(PhoneStyle.kinds, id: \.self) { kind in
                    if let n = m.rowsOfKind[kind]?.count, n > 0 {
                        Button { if hidden.contains(kind) { hidden.remove(kind) } else { hidden.insert(kind) } } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Color(PhoneStyle.kindColor(kind, accent: c.color))).frame(width: 8, height: 8)
                                Text("\(grouped(n)) \(PhoneStyle.kindLabel(kind))").font(.caption).foregroundStyle(.secondary)
                            }
                            .opacity(hidden.contains(kind) ? 0.35 : 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func load() async {
        if reading { return }
        reading = true; loading = model == nil
        defer { reading = false; loading = false }
        guard let d = await client.shielded({ await $0.map() }) else { failed = PhoneFormat.why(client); return }
        if model != nil, d == mapData { readAt = Date(); failed = nil; realityFailed = false; return }   // the same map again: cloud, turn and selection stay
        let m = await Task.detached(priority: .userInitiated) { PhoneMapModel(d) }.value
        if let m {
            // A different map: every row number the page holds (the selection, the 3-D scene's picks) meant another point in the old one.
            model = m; mapData = d; selected = nil; readAt = Date()
            failed = nil; realityFailed = false
        }
        else { failed = "the Mac's map does not add up (its arrays differ in length) — update the \(c.name) app on the Mac and on this \(PhoneStyle.device) to the same version" }
        if !Self.actionDone, let r = UserDefaults.standard.string(forKey: "mapSelect").flatMap(Int.init), let m, m.isDrawn(r) {   // -mapSelect <row> (tests)
            Self.actionDone = true
            selected = r
        }
    }
}

#endif
