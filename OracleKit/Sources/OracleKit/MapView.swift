#if os(macOS)
import SwiftUI
import RealityKit
import simd

/// The Map page (issue #34): an oracle's memory as one 3-D space — every session piece, ψ note, issue and PR a point
/// at its layout position (MapLayout), related things close together. Orbit with the mouse, scroll to zoom, hover
/// for the title and the point's neighbours, click to open; a search lights its hits and the camera turns to them.
/// RealityKit, instanced (the spike: 49k points at 59 fps); picking is on the CPU (pixelCast never sees instances).
@available(macOS 26, *)
public struct MapView: View {
    let name: String
    let accent: Color
    @ObservedObject var index: GHIndex
    @ObservedObject var layout: MapLayout
    @ObservedObject var clusters: MapClusters
    @ObservedObject private var trace = TraceLog.shared
    @ObservedObject private var heard = QueryListener.shared
    /// The hub's map of every oracle (#37): points coloured by oracle, every app's queries fire it.
    let fleet: FleetMap?
    @State private var byKind = false
    @State private var dominant: [Int: String] = [:]   // a region's oracle, when it holds ≥ 80 % of it
    @State private var kindCounts: [String: Int] = [:]  // the legend's counts, counted once per change of the docs —
    @State private var oracleCounts: [(String, Int)] = []   // not on every redraw (labels move ten times a second)
    @StateObject private var scene: MapScene
    @State private var escMonitor: Any?
    @State private var query = ""
    @State private var who = "all"
    @State private var flat = false
    @State private var showGroups = false
    @State private var openRegion: Int?
    @FocusState private var focused: Bool
    private static var actionDone = false

    public init(name: String, accent: Color, index: GHIndex, fleet: FleetMap? = nil) {
        self.name = name; self.accent = accent; self.index = index; self.layout = index.layout; self.clusters = index.clusters; self.fleet = fleet
        _scene = StateObject(wrappedValue: MapScene(accent: accent, fleet: fleet))
    }

    public var body: some View {
        handlers(page).task { await prepare() }
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("MAP").font(.caption.weight(.bold)).tracking(2.5).foregroundStyle(accent)
                Text("\(name)'s map").font(.custom("Avenir Next", size: 34).weight(.bold))
                Text("\(grouped(layout.xyz.count)) memories in one space — close means related, lines join nearest neighbours.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                legend
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 10)
            ZStack(alignment: .bottomLeading) {
                if layout.xyz.isEmpty { empty } else {
                    RealityView { content in
                        var content = content
                        scene.build(into: &content, layout: layout, docs: index.docs)
                        _ = content.subscribe(to: SceneEvents.Update.self) { _ in scene.frame() }
                    } update: { _ in }
                    // a new layout (a re-fit, docs placed) is a new scene: rows and positions changed together
                    .id("\(layout.meta?.built.timeIntervalSince1970 ?? 0)·\(layout.xyz.count)")
                    .realityViewCameraControls(.orbit)
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        if case .active(let p) = phase { scene.pointer = p } else { scene.pointer = nil; scene.hoverDoc = nil; scene.setHand(false) }
                    }
                    .onTapGesture { scene.click() }
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { scene.viewSize = $0 }
                    .background(Color(red: 0.03, green: 0.03, blue: 0.05))
                    .onAppear { scene.installScrollZoom() }
                    .onDisappear { scene.removeScrollZoom() }
                }
                groupLabels
                if let r = scene.selectedRow, let d = scene.doc(row: r) {
                    panel(row: r, doc: d).frame(width: 340).padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                controls.padding(14)
                VStack(alignment: .leading, spacing: 10) {
                    searchField.frame(maxWidth: 460)
                    if showGroups { groupList.frame(width: 300).transition(.move(edge: .leading).combined(with: .opacity)) }
                }
                .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                GeometryReader { g in
                    if let d = scene.hoverDoc.flatMap({ $0 < scene.docs.count ? scene.docs[$0] : nil }), let p = scene.hoverAt {   // the scene's docs: the ones its rows point at
                        let flipX = p.x > g.size.width - 340, flipY = p.y > g.size.height - 110
                        hoverCard(d).fixedSize(horizontal: false, vertical: true).frame(width: 320, alignment: .leading)
                            .offset(x: flipX ? p.x - 336 : p.x + 18, y: flipY ? p.y - 96 : p.y + 16)
                            .animation(.easeOut(duration: 0.08), value: p)
                    }
                }
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .padding(.horizontal, 28).padding(.bottom, 14)
        }
    }

    /// What the page reacts to: the layout and the groups changing, every traced or heard query, the switches.
    private func handlers<V: View>(_ v: V) -> some View {
        switches(events(v))
            .animation(.easeOut(duration: 0.18), value: scene.selectedRow)
            .animation(.easeOut(duration: 0.18), value: showGroups)
            .onAppear { installEsc() }
            .onDisappear { if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil } }
    }

    /// The layout, the groups and every traced or heard query.
    private func events<V: View>(_ v: V) -> some View {
        v.onChange(of: layout.xyz.count) { scene.needsRebuild = true }
        // a fit that ends while the page is open (the fleet map fits in the background): the groups follow the new rows
        .onChange(of: layout.meta?.built) { Task { await clusters.refresh(layout: layout, docs: index.docs) } }
        .onChange(of: clusters.revision) { regroupScene() }
        .onChange(of: scene.built) { regroupScene() }
        // #36: every query asked of this memory — a page, the map, another oracle over MCP — fires its hits
        // keyed on the newest entry, not the count: TraceLog keeps 500, so past that the count stops changing
        .onChange(of: trace.entries.last?.id) { _, _ in fireTraced() }
        // #37: a query another oracle app answered
        .onChange(of: heard.last?.id) { _, _ in fireHeard() }
    }

    /// The page's own switches: kinds, 2D, colour by oracle or kind, the legend's counts.
    private func switches<V: View>(_ v: V) -> some View {
        v.onChange(of: who) { scene.show(kinds: who) }
        .onChange(of: flat) { scene.flatten(flat) }
        .onChange(of: byKind) { scene.recolor(byKind: byKind) }
        .onChange(of: index.docs.count, initial: true) { count() }
    }

    private func regroupScene() {
        scene.setGroups(clusters.labels, leaves: clusters.leafLabels, ids: clusters.layoutIds)
        placeOracles()
    }

    /// esc: clear the selection, then the lit hits.
    private func installEsc() {
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 53 else { return e }
            if scene.selectedRow != nil { scene.select(nil); return nil }
            if !scene.lit.isEmpty { scene.light([]); query = ""; return nil }
            return e
        }
    }

    /// The last query traced in this app, when it was asked of this map's memory (or, on the fleet map, of any index
    /// in it): its hits fire in the caller's colour.
    private func fireTraced() {
        guard let e = trace.entries.last else { return }
        guard e.index == index.name || fleet?.members.contains(where: { $0.id == e.index }) == true else { return }
        let rows = e.top.compactMap { layout.row(of: $0.id) }
        scene.fire(rows: rows, color: MapScene.callerColor(e.caller, source: e.source, accent: accent), label: Self.who(e))
    }

    /// Fleet map: a query another oracle app answered fires in that oracle's colour (Pulse's memory lights Pulse
    /// red); the caption says who asked.
    private func fireHeard() {
        guard let fleet, let e = heard.last else { return }
        // only an index the hub read itself; the oracle's name (and so its log's name) comes from the hub's own listing
        guard let member = fleet.members.first(where: { $0.id == e.index && $0.id.hasPrefix("history/") }) else { return }
        let owner = member.oracle, known = Set(fleet.members.map(\.oracle))
        Task {
            guard let t = await Task.detached(priority: .userInitiated, operation: { QueryBroadcast.traced(e.trace, oracle: owner) }).value else { return }
            let rows = t.ids.compactMap { layout.row(of: $0) }
            if rows.count < t.ids.count { fleet.missed(t.ids.filter { layout.row(of: $0) == nil }) }
            let asker = e.source == "mcp" ? t.caller?.components(separatedBy: " · ").first : nil
            let who = asker.map { known.contains($0) ? $0 : "an agent" } ?? (e.source == "mcp" ? "an agent" : "you")
            scene.fire(rows: rows, color: FleetMap.color(owner), label: "\(who) asked \(owner) “\(t.query.prefix(40))”")
        }
    }

    /// On open: the model, the layout (fitted when missing or stale), the groups, and the test hooks.
    private func prepare() async {
        if GHIndex.loaded == nil, !ModelLoad.shared.loading, ModelLoad.shared.failed == nil, !ModelLoad.shared.absent {
            ModelLoad.shared.reload?(UserDefaults.standard.string(forKey: "hub.engineMode") ?? "gpu")
        }
        if layout.xyz.isEmpty, layout.staleReason(docs: index.docs, space: index.space) != nil, !layout.running {
            await layout.fit(docs: index.docs, space: index.space, why: "Map page opened with no layout")
        } else if let why = layout.staleReason(docs: index.docs, space: index.space), !layout.running {
            await layout.fit(docs: index.docs, space: index.space, why: why)
        }
        await clusters.refresh(layout: layout, docs: index.docs)
        scene.setGroups(clusters.labels, leaves: clusters.leafLabels, ids: clusters.layoutIds)
        placeOracles()
        if UserDefaults.standard.bool(forKey: "mapGroups") { showGroups = true }   // -mapGroups YES (tests)
        if let id = UserDefaults.standard.string(forKey: "mapSelect") {   // -mapSelect <doc id> (tests: one point's panel)
            for _ in 0..<300 where scene.built == 0 { try? await Task.sleep(for: .milliseconds(100)) }
            if let r = layout.row(of: id) { scene.select(r) } else { HubLog.shared.add(.error, "map: -mapSelect \(id) is not on the map") }
        }
        if !Self.actionDone, let q = UserDefaults.standard.string(forKey: "mapQuery"), !q.isEmpty {   // -mapQuery <text> (tests)
            Self.actionDone = true
            for _ in 0..<600 where layout.xyz.isEmpty || scene.built == 0 || ModelLoad.shared.loading { try? await Task.sleep(for: .milliseconds(100)) }
            query = q; await search()
            if UserDefaults.standard.bool(forKey: "mapSelectFirst"), let r = scene.lit.first { scene.select(r) }   // -mapSelectFirst YES (tests)
        }
    }

    /// The colour key, with counts — the only place a colour is explained.
    private var legend: some View {
        let counts = kindCounts
        return HStack(spacing: 16) {
            if fleet != nil, !byKind {
                ForEach(oracleCounts, id: \.0) { o, n in
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: FleetMap.color(o))).frame(width: 8, height: 8)
                        Text("\(o) \(grouped(n))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
            ForEach([("history", "sessions"), ("note", "ψ notes"), ("issue", "issues"), ("pr", "PRs")], id: \.0) { k, label in
                if let n = counts[k], n > 0 {
                    HStack(spacing: 6) {
                        Circle().fill(Color(nsColor: MapScene.color(k, accent: accent))).frame(width: 8, height: 8)
                        Text("\(grouped(n)) \(label)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            }
            if fleet != nil {
                Picker("", selection: $byKind) { Text("By oracle").tag(false); Text("By kind").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            }
            ForEach(scene.recentFirings.prefix(3), id: \.id) { f in
                HStack(spacing: 6) { Circle().fill(Color(nsColor: f.color)).frame(width: 8, height: 8).shadow(color: Color(nsColor: f.color), radius: 4)
                    Text(f.label).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if !scene.lit.isEmpty {
                HStack(spacing: 6) { Circle().fill(.white).frame(width: 8, height: 8).shadow(color: .white, radius: 4)
                    Text("\(scene.lit.count) lit by the search").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    /// The names of the biggest groups, floating at their centres — the regions, or, zoomed in, the leaves of what is
    /// on screen. A name lights its whole group.
    private var groupLabels: some View {
        let leafLevel = !scene.leafAt.isEmpty
        let at = leafLevel ? scene.leafAt : scene.labelAt
        let all = leafLevel ? clusters.leaves : clusters.groups
        // biggest first; a name that would overlap one already placed is left out (hover its group to see it)
        var placed: [CGPoint] = []
        let shown = all.sorted { $0.count > $1.count }.filter { g in
            guard let p = at[g.id], !placed.contains(where: { abs($0.x - p.x) < 150 && abs($0.y - p.y) < 26 }) else { return false }
            placed.append(p); return true
        }.prefix(leafLevel ? 16 : 12)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(shown)) { g in
                if let p = at[g.id] {
                    Button { scene.focus(group: g.id, leaf: leafLevel) } label: {
                        Text(!leafLevel ? dominant[g.id].map { "\($0) · \(g.name)" } ?? g.name : g.name)
                            .font(leafLevel ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(leafLevel ? 0.75 : 0.85))
                            .padding(.horizontal, leafLevel ? 6 : 8).padding(.vertical, leafLevel ? 2 : 3)
                            .background(.black.opacity(leafLevel ? 0.45 : 0.55), in: Capsule())
                            .overlay(Capsule().strokeBorder(accent.opacity(leafLevel ? 0.22 : 0.35)))
                    }
                    .buttonStyle(.plain).handCursor().help("\(grouped(g.count)) memories — \(g.keywords.prefix(5).joined(separator: " · ")) — click to light the group")
                    .fixedSize().position(p)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Every region with its count; open one for its leaves. A click lights the group and turns the map to it.
    private var groupList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("GROUPS").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(accent)
                Text("\(clusters.groups.count) regions · \(clusters.leaves.count) smaller").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { showGroups = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).handCursor().help("Close")
            }
            if clusters.running { Text("grouping…").font(.caption).foregroundStyle(.secondary) }
            else if !clusters.titling.isEmpty { Text("\(clusters.titling) — Apple's on-device model names them").font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(clusters.groups.sorted { $0.count > $1.count }) { g in
                        groupRow(g, leaf: false)
                        if openRegion == g.id {
                            ForEach(clusters.leaves.filter { $0.parent == g.id }.sorted { $0.count > $1.count }) { l in groupRow(l, leaf: true) }
                        }
                    }
                }
            }
            .frame(maxHeight: 360)
        }
        .padding(12)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.35)))
    }

    private func groupRow(_ g: MapClusters.Group, leaf: Bool) -> some View {
        Button {
            scene.focus(group: g.id, leaf: leaf)
            if !leaf { openRegion = openRegion == g.id ? nil : g.id }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !leaf { Image(systemName: openRegion == g.id ? "chevron.down" : "chevron.right").font(.caption2).foregroundStyle(.tertiary).frame(width: 10) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(g.name).font(leaf ? .caption : .callout.weight(.medium)).lineLimit(1)
                    if g.title != nil { Text(g.keywords.prefix(4).joined(separator: " · ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                }
                Spacer(minLength: 4)
                Text(grouped(g.count)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4).padding(.leading, leaf ? 22 : 4).padding(.trailing, 4).contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor().help(leaf ? "Light this group and turn to it" : "Light this region and turn to it; shows its smaller groups")
    }

    /// The clicked point: what it is, what is closest to it (its nearest neighbours in meaning), and its group.
    private func panel(row: Int, doc d: IndexDoc) -> some View {
        let rel = scene.neighbours(of: row).prefix(15).compactMap { r in scene.doc(row: r).map { (r, $0) } }
        let g = scene.group(of: row).flatMap { gid in clusters.groups.first { $0.id == gid } }
        let leaf = scene.leaf(of: row).flatMap { lid in clusters.leaves.first { $0.id == lid } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Circle().fill(Color(nsColor: MapScene.color(d.kind, accent: accent))).frame(width: 9, height: 9).padding(.top, 5)
                Text(d.kind == "history" && !d.snippet.isEmpty ? d.snippet : d.title).font(.callout.weight(.semibold)).lineLimit(4)
                Spacer(minLength: 4)
                Button { scene.select(nil) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).handCursor().help("Close (esc)")
            }
            Text(meta(d)).font(.caption.monospaced()).foregroundStyle(.secondary)
            if d.kind == "history" { Text("in “\(d.title)”").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            else if !d.snippet.isEmpty { Text(d.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(4) }
            HStack {
                Button(d.kind == "history" ? "Copy the command that reopens it" : "Open") { MapScene.open(d) }
                    .buttonStyle(.borderedProminent).tint(accent).controlSize(.small).handCursor()
                if let o = fleet?.oracleOf[d.id], let app = FleetMap.app(of: o) {
                    Button("Open \(o)") { NSWorkspace.shared.openApplication(at: app, configuration: .init()) }
                        .buttonStyle(.bordered).controlSize(.small).handCursor().help("Open the \(o) app")
                }
            }
            if let g {
                Divider()
                Text("GROUP").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(accent)
                Text(leaf.map { "\(g.name) › \($0.name)" } ?? g.name).font(.callout.weight(.medium)).lineLimit(2)
                Text((leaf ?? g).keywords.prefix(5).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack {
                    Text("\(grouped((leaf ?? g).count)) memories").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Light the group") { if let leaf { scene.focus(group: leaf.id, leaf: true) } else { scene.focus(group: g.id, leaf: false) } }
                        .buttonStyle(.bordered).controlSize(.small).handCursor()
                }
            }
            Divider()
            Text("CLOSEST IN MEANING").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(accent)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rel, id: \.0) { r, n in
                        Button { scene.select(r) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(Color(nsColor: MapScene.color(n.kind, accent: accent))).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(n.kind == "history" && !n.snippet.isEmpty ? n.snippet : n.title).font(.caption).lineLimit(2)
                                    Text(meta(n)).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 4).padding(.horizontal, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).handCursor().help("Go to it on the map")
                    }
                }
            }
            .frame(maxHeight: 320)
        }
        .padding(14)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.45)))
    }

    /// "Pulse asked" / "you asked" — the firing's caption.
    static func who(_ e: TraceLog.Entry) -> String {
        let oracle = e.source == "mcp" ? (e.caller?.components(separatedBy: " · ").first ?? "an agent") : "you"
        return "\(oracle) asked “\(e.query.prefix(40))”"
    }

    private func meta(_ d: IndexDoc) -> String {
        let o = fleet?.oracleOf[d.id]
        let base = d.kind == "note" ? "ψ/\(d.state)" : d.kind == "history" ? "session · \(d.state == "user" ? "you asked" : "\(o ?? name) answered") · \(String(d.updated.prefix(10)))" : "\(d.kind) \(d.repo)#\(d.number) · \(d.state.lowercased())"
        return o.map { "\($0) · \(base)" } ?? base
    }

    /// The legend's counts: docs per kind, and per oracle on the fleet map (biggest first).
    private func count() {
        var k: [String: Int] = [:], o: [String: Int] = [:]
        for d in index.docs { k[d.kind, default: 0] += 1; if let fleet { o[fleet.oracleOf[d.id] ?? "Fleet", default: 0] += 1 } }
        kindCounts = k
        oracleCounts = o.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }
    private func placeOracles() {
        guard let fleet else { return }
        dominant = fleet.dominant(labels: clusters.labels, ids: clusters.layoutIds)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            if layout.running {
                ProgressView().controlSize(.small)
                Text(layout.progress.isEmpty ? "laying out \(grouped(index.docs.count)) memories…" : layout.progress).font(.callout).foregroundStyle(.secondary)
            } else if let p = layout.problem {
                Text(p).font(.callout).foregroundStyle(.orange)
            } else if index.docs.isEmpty {
                Text("nothing embedded yet — Memory page: Scan, then Run batch").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(MapLayout.engine == nil ? "this app has no layout engine" : "no map yet").font(.callout).foregroundStyle(.secondary)
                Button("Lay out \(grouped(index.docs.count)) memories") { Task { await layout.fit(docs: index.docs, space: index.space, why: "Map page button") } }
                    .buttonStyle(.borderedProminent).tint(accent).disabled(MapLayout.engine == nil).handCursor()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .background(Color(red: 0.03, green: 0.03, blue: 0.05))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $who) {
                Text("All").tag("all"); Text("Sessions").tag("history"); Text("ψ notes").tag("note"); Text("Issues & PRs").tag("gh")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Toggle("2D", isOn: $flat).toggleStyle(.switch).controlSize(.mini)
            Button { showGroups.toggle() } label: { Label("Groups", systemImage: "circle.hexagongrid") }
                .buttonStyle(.bordered).controlSize(.small).handCursor().disabled(clusters.groups.isEmpty)
                .help("Every group of this memory — click one to light it")
            if !scene.lit.isEmpty {
                Button { scene.light([]); query = "" } label: { Label("\(scene.lit.count) lit", systemImage: "xmark.circle.fill") }
                    .buttonStyle(.bordered).controlSize(.small).handCursor().help("Clear the lit hits (esc)")
            }
        }
        .padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func hoverCard(_ d: IndexDoc) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(d.title).font(.callout.weight(.semibold)).lineLimit(2)
            Text(meta(d)).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let r = scene.hovered, let g = scene.group(of: r).flatMap({ gid in clusters.groups.first { $0.id == gid } }) {
                let leaf = scene.leaf(of: r).flatMap { lid in clusters.leaves.first { $0.id == lid } }
                Text("in \(g.name)" + (leaf.map { " › \($0.name)" } ?? "")).font(.caption).foregroundStyle(accent).lineLimit(1)
            }
            Text("click: what is related, and its group").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(accent.opacity(0.5)))
        .allowsHitTesting(false)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
            TextField("Light up what is about…", text: $query).textFieldStyle(.plain).font(.custom("Avenir Next", size: 16)).focused($focused)
                .onSubmit { Task { await search() } }
            if index.searching { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.black.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(focused ? accent : Color.primary.opacity(0.14), lineWidth: focused ? 1.5 : 1))
        .shadow(color: focused ? accent.opacity(0.45) : .clear, radius: 14)
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { scene.light([]); return }
        guard let hits = await index.query(q, limit: 25, source: "map") else { return }
        scene.light(hits.compactMap { layout.row(of: $0.doc.id) })
    }
}
#endif
