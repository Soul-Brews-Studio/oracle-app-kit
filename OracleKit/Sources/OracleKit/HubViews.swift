#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Oracles (the landing app) — sidebar: all herdr sessions · detail: every oracle as a card
// Same look as the oracle apps: ARRA-style sidebar, cards like the Work view.

enum HubPick: Hashable { case all, search, session(String) }

enum HubStyle {
    static let accent = Color(hex: "#9b8cff")
}

/// The store and the menu-bar switch belong to the App (`@StateObject` + `@AppStorage` there): kept in this
/// Scene they made MenuBarExtra and the main menu rebuild each other forever — 100% CPU, spinning cursor.
public struct HubScene: Scene {
    let store: HubStore
    @Binding var menuBar: Bool
    public init(store: HubStore, menuBar: Binding<Bool>) { self.store = store; _menuBar = menuBar }
    public var body: some Scene {
        Window("ARRA Oracles", id: "main") { HubRootView(store: store, menuBar: $menuBar) }
            .defaultSize(width: 1120, height: 740)
        // The status tray: one item for the whole fleet. Its label stays a plain symbol — a live view
        // there (a count in an HStack, an .onAppear) fed the same loop. Counts live inside the menu.
        // isInserted is written back by the status item's KVO on every button update; an @AppStorage write of the
        // SAME value re-renders the App, which updates the button again — the loop sample(1) showed. Write on change only.
        MenuBarExtra("ARRA Oracles", systemImage: "circle.hexagongrid.fill",
                     isInserted: Binding(get: { menuBar }, set: { if $0 != menuBar { menuBar = $0 } })) {
            HubMenu(store: store, menuBar: $menuBar)
        }
    }
}

struct HubRootView: View {
    @ObservedObject var store: HubStore
    @Binding var menuBar: Bool
    @State private var pick: HubPick = UserDefaults.standard.string(forKey: "hubPage") == "search" ? .search : .all   // -hubPage search
    @StateObject private var index = GHIndex()
    var body: some View {
        NavigationSplitView {
            HubSidebar(store: store, pick: $pick, menuBar: $menuBar)
                .navigationSplitViewColumnWidth(min: 240, ideal: 272)
        } detail: {
            switch pick {
            case .all: OracleBoard(store: store)
            case .search: IndexSearchView(store: store, index: index)
            case .session(let name): SessionSpaces(store: store, session: name)
            }
        }
        .tint(HubStyle.accent)
        .onAppear { store.start() }
        .task {   // keep the ANE index fresh in the background: on launch when it is missing or older than 6 h
            for _ in 0..<20 where store.oracles.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            let slugs = Array(Set(store.oracles.compactMap { $0.checkout.flatMap(GHIndex.slug(fromCheckout:)) })).sorted()
            if !slugs.isEmpty, index.docs.isEmpty || (index.built.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true) {
                await index.index(repos: slugs)
            }
        }
    }
}

struct HubSidebar: View {
    @ObservedObject var store: HubStore
    @Binding var pick: HubPick
    @Binding var menuBar: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(HubStyle.accent.gradient).frame(width: 30, height: 30)
                    Image(systemName: "circle.hexagongrid.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                }
                Text("ARRA Oracles").font(.custom("Avenir Next", size: 20).weight(.semibold)).tracking(-0.4).lineLimit(1)
                Spacer(minLength: 4)
                SidebarIconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refresh() } }
            }
            .padding(.horizontal, 18).frame(height: 70)
            NavRow(symbol: "square.grid.2x2", title: "All oracles", badge: "\(store.oracles.count)",
                   on: pick == .all, accent: HubStyle.accent) { pick = .all }
                .padding(.horizontal, 12)
            NavRow(symbol: "sparkle.magnifyingglass", title: "Search issues & PRs", badge: nil,
                   on: pick == .search, accent: HubStyle.accent) { pick = .search }
                .padding(.horizontal, 12)
            Text("Sessions").font(.custom("Avenir Next", size: 13).weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 26).padding(.top, 18).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.sessions.sorted { ($0.running ? 0 : 1, $0.name) < ($1.running ? 0 : 1, $1.name) }) { s in
                        SessionRow(session: s, spaces: store.spaces.filter { $0.session == s.name },
                                   on: pick == .session(s.name)) { pick = .session(s.name) }
                    }
                }
                .padding(.horizontal, 12)
            }
            footer
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(store.problems.isEmpty ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(store.problems.isEmpty ? "Live on this Mac" : "Needs a look").font(.custom("Avenir Next", size: 13).weight(.semibold))
            }
            if let t = store.lastRefresh {
                Text("herdr · maw — updated \(t.formatted(date: .omitted, time: .shortened))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(store.problems, id: \.self) { Text($0).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled) }
            Toggle("Show in menu bar", isOn: $menuBar).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

struct SessionRow: View {
    let session: HubSession
    let spaces: [HubSpace]
    let on: Bool
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        let urgent = spaces.map(\.status).min { HubParse.rank($0) < HubParse.rank($1) }
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(session.running ? Color.green : Color.secondary.opacity(0.35)).frame(width: 7, height: 7)
                Text(session.name).font(.custom("Avenir Next", size: 14).weight(on ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 4)
                if let u = urgent, HubParse.rank(u) <= 2 { HubGlyph(status: u) }
                Text(session.running ? "\(spaces.count)" : "off").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            }
            .foregroundStyle(on ? HubStyle.accent : (session.running ? Color.primary.opacity(0.85) : Color.secondary))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? HubStyle.accent.opacity(0.16) : (hover ? Color.primary.opacity(0.06) : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .onHover { hover = $0 }
    }
}

/// herdr's marks: ◐ working · ✓ needs you (done) · ! blocked · ○ idle.
struct HubGlyph: View {
    let status: String
    var body: some View {
        let look: (String, Color) = {
            switch status {
            case "working": return ("circle.lefthalf.filled", HubStyle.accent)
            case "done": return ("checkmark.circle.fill", .green)
            case "blocked": return ("exclamationmark.circle.fill", .orange)
            case "idle": return ("circle", .secondary)
            case "resumable": return ("arrow.uturn.backward", .secondary)
            default: return ("moon.zzz", Color.secondary.opacity(0.6))
            }
        }()
        Image(systemName: look.0).font(.system(size: 10, weight: .bold)).foregroundStyle(look.1)
    }
}

// MARK: every oracle — apps first, then what herdr has open, then what can be resumed

struct OracleBoard: View {
    @ObservedObject var store: HubStore
    @State private var allResumable = false
    @State private var showCold = false
    @State private var showRegistry = false
    @State private var query = ""
    private let grid = [GridItem(.adaptive(minimum: 250), spacing: 14)]
    var body: some View {
        let appKeys = Set(store.apps.keys)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let hit: (HubOracle) -> Bool = { q.isEmpty || $0.name.lowercased().contains(q) || $0.repo.lowercased().contains(q) }
        let withApp = store.appOracles.filter(hit)
        let live = store.oracles.filter { $0.isLive && !appKeys.contains($0.appKey) && hit($0) }
        let resumable = store.oracles.filter { !$0.isLive && $0.resumable > 0 && !appKeys.contains($0.appKey) && hit($0) }
        let cold = store.oracles.filter { !$0.isLive && $0.resumable == 0 && !appKeys.contains($0.appKey) && hit($0) }
        let registry = store.registryOnly.filter(hit)
        let running = store.sessions.filter(\.running).count
        let need = store.spaces.filter { $0.status == "done" || $0.status == "blocked" }.count
        let working = store.spaces.filter { $0.status == "working" }.count
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(need > 0 ? "\(need) need you" : working > 0 ? "\(working) working" : "all quiet")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(need + working > 0 ? HubStyle.accent : Color.secondary)
                    Text("\(running) of \(store.sessions.count) herdr sessions running · \(store.spaces.count) spaces · \(store.oracles.count) repos")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !withApp.isEmpty {
                    block("APPS", withApp.count, note: "click opens the oracle's app") {
                        LazyVGrid(columns: grid, alignment: .leading, spacing: 14) {
                            ForEach(withApp) { OracleCard(oracle: $0, app: store.apps[$0.appKey], store: store) }
                        }
                    }
                }
                if !live.isEmpty {
                    block("LIVE IN HERDR", live.count, note: "click shows its space in herdr") {
                        LazyVGrid(columns: grid, alignment: .leading, spacing: 14) {
                            ForEach(live) { OracleCard(oracle: $0, app: nil, store: store) }
                        }
                    }
                }
                if !resumable.isEmpty {
                    block("RESUMABLE", resumable.count) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(allResumable ? resumable : Array(resumable.prefix(8))) { RestingRow(oracle: $0) }
                        }
                        if resumable.count > 8 {
                            Button(allResumable ? "show less" : "\(resumable.count - 8) more") { allResumable.toggle() }.handCursor()
                                .buttonStyle(.link).padding(.leading, 4)
                        }
                    }
                }
                if !cold.isEmpty {
                    folded("COLD", cold, note: "no session to resume", open: $showCold)
                }
                if !registry.isEmpty {
                    folded("NOT IN HERDR", registry, note: "in maw's oracle registry, never opened in herdr", open: $showRegistry)
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay { if store.oracles.isEmpty && store.apps.isEmpty { Text("Nothing from herdr or maw yet").foregroundStyle(.secondary) } }
        .searchable(text: $query, placement: .toolbar, prompt: "Filter oracles")
        .navigationTitle("All oracles")
    }

    private func folded(_ title: String, _ list: [HubOracle], note: String, open: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.snappy) { open.wrappedValue.toggle() } } label: {
                HStack(spacing: 6) {
                    WorkFormat.header(title, list.count, note: note)
                    Image(systemName: open.wrappedValue || !query.isEmpty ? "chevron.down" : "chevron.right")
                        .font(.caption2.bold()).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).handCursor()
            if open.wrappedValue || !query.isEmpty {   // a filter opens every fold, so a match is never hidden
                VStack(alignment: .leading, spacing: 2) { ForEach(list) { RestingRow(oracle: $0).opacity(0.75) } }
            }
        }
    }

    private func block<Content: View>(_ title: String, _ n: Int, note: String = "", @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkFormat.header(title, n, note: note)
            content()
        }
    }
}

struct OracleCard: View {
    let oracle: HubOracle
    let app: URL?
    let store: HubStore
    @State private var hover = false
    var body: some View {
        Button(action: tap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 11) {
                    OracleIcon(app: app, name: oracle.name)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(oracle.name).font(.custom("Avenir Next", size: 16).weight(.semibold)).lineLimit(1)
                        HStack(spacing: 5) {
                            HubGlyph(status: oracle.status)
                            Text(HubParse.word(oracle.status)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: app != nil ? "arrow.up.forward.app" : "macwindow")
                        .font(.system(size: 13)).foregroundStyle(hover ? HubStyle.accent : Color.secondary)
                }
                Text(spacesLine).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(treesLine).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hover ? 0.075 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(hover ? HubStyle.accent.opacity(0.6) : Color.primary.opacity(0.08)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .onHover { hover = $0 }
        .help(app != nil ? "Open the \(oracle.name) app" : oracle.spaces.isEmpty ? "No herdr space open" : "Show in herdr")
        .contextMenu {
            if app != nil { Button("Open \(oracle.name) app") { store.openApp(oracle.appKey) } }
            ForEach(oracle.spaces) { s in Button("Show in herdr — \(s.session) · \(s.label)") { store.showInHerdr(s) } }
            if let r = oracle.resume { Button("Copy resume command") { WorkFormat.copy(r) } }
            if let p = oracle.checkout { Button("Open folder") { WorkFormat.open(URL(fileURLWithPath: p)) } }
        }
    }

    private func tap() {
        if app != nil { store.openApp(oracle.appKey) }
        else if let s = oracle.spaces.first { store.showInHerdr(s) }
    }
    private var spacesLine: String {
        guard !oracle.spaces.isEmpty else { return "no herdr space open" }
        let sessions = Set(oracle.spaces.map(\.session)).sorted().joined(separator: ", ")
        let panes = oracle.spaces.reduce(0) { $0 + $1.panes }
        return "\(sessions) · \(oracle.spaces.count) \(oracle.spaces.count == 1 ? "space" : "spaces") · \(panes) \(panes == 1 ? "pane" : "panes")"
    }
    private var treesLine: String {
        "\(oracle.running + oracle.open) open · \(oracle.resumable) resumable · \(oracle.cold) cold"
    }
}

struct OracleIcon: View {
    let app: URL?
    let name: String
    var body: some View {
        if let app {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().interpolation(.high).frame(width: 36, height: 36)
        } else {
            let hue = Double(abs(name.hashValue % 360)) / 360
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color(hue: hue, saturation: 0.45, brightness: 0.55).gradient)
                Text(String(name.prefix(1))).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
        }
    }
}

/// A repo with no space open: its name, what it holds, and the way back in.
struct RestingRow: View {
    let oracle: HubOracle
    @State private var copied = false
    var body: some View {
        HStack(spacing: 10) {
            HubGlyph(status: oracle.status)
            Text(oracle.name).lineLimit(1)
            Text(oracle.repo == oracle.name.lowercased() ? "" : oracle.repo).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 8)
            Text("\(oracle.resumable) resumable · \(oracle.cold) cold").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let r = oracle.resume {
                Button(copied ? "copied" : "resume") { WorkFormat.copy(r); copied = true }.handCursor()
                    .buttonStyle(.borderless).help(r).frame(width: 64, alignment: .trailing)
            } else {
                Color.clear.frame(width: 64, height: 1)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .contextMenu {
            if let p = oracle.checkout { Button("Open folder") { WorkFormat.open(URL(fileURLWithPath: p)) } }
        }
    }
}

// MARK: one herdr session — its spaces, the way herdr's sidebar lists them

struct SessionSpaces: View {
    @ObservedObject var store: HubStore
    let session: String
    var body: some View {
        let s = store.sessions.first { $0.name == session }
        let spaces = store.spaces.filter { $0.session == session }.sorted { $0.number < $1.number }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(session).font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(s?.running == true ? "running · \(spaces.count) spaces" : "stopped").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if s?.running == true { Button("Open in WezTerm") { store.openSession(session) }.controlSize(.small) }
                }
                if s?.running != true {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This herdr session is not running. Open it in WezTerm, or from any terminal:").foregroundStyle(.secondary)
                        Text("herdr --session \(session)").font(.callout.monospaced()).textSelection(.enabled)
                        Button("Open in WezTerm") { store.openSession(session) }.buttonStyle(.borderedProminent).controlSize(.small).handCursor()
                    }
                    .padding(14)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
                }
                VStack(spacing: 2) {
                    ForEach(spaces) { sp in
                        SpaceLine(space: sp, app: sp.repo.map { store.apps[HubParse.displayName($0).lowercased()] } ?? nil, store: store)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(session)
    }
}

struct SpaceLine: View {
    let space: HubSpace
    let app: URL?
    let store: HubStore
    @State private var hover = false
    var body: some View {
        HStack(spacing: 10) {
            if space.linked { Text("└").font(.callout.monospaced()).foregroundStyle(.tertiary) }
            HubGlyph(status: space.status)
            VStack(alignment: .leading, spacing: 1) {
                Text(space.label).font(.custom("Avenir Next", size: 15).weight(.medium)).lineLimit(1).truncationMode(.middle)
                if let r = space.repo, r != space.label {
                    Text(r).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text("\(space.panes) \(space.panes == 1 ? "pane" : "panes") · \(space.agents) \(space.agents == 1 ? "agent" : "agents")")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if app != nil, let r = space.repo {
                Button("Open app") { store.openApp(HubParse.displayName(r).lowercased()) }.controlSize(.small).handCursor()
            }
            Button("Show in herdr") { store.showInHerdr(space) }.controlSize(.small).handCursor()
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .padding(.leading, space.linked ? 14 : 0)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? Color.primary.opacity(0.05) : Color.clear))
        .onHover { hover = $0 }
    }
}

// MARK: the status tray — on/off from the window footer or from the menu itself

struct HubMenu: View {
    @ObservedObject var store: HubStore
    @Binding var menuBar: Bool
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let need = store.spaces.filter { $0.status == "done" || $0.status == "blocked" }.count
        let working = store.spaces.filter { $0.status == "working" }.count
        Text("\(need) need you · \(working) working · \(store.spaces.count) spaces")
        Divider()
        ForEach(store.appOracles) { o in
            Button { store.openApp(o.appKey) } label: { Label("\(o.name) — \(HubParse.word(o.status))", systemImage: "app") }
        }
        let live = store.oracles.filter { $0.isLive && store.apps[$0.appKey] == nil }.prefix(12)
        if !live.isEmpty {
            Divider()
            ForEach(Array(live)) { o in
                Button {
                    if let s = o.spaces.first { store.showInHerdr(s) }
                } label: { Label("\(o.name) — \(HubParse.word(o.status))", systemImage: o.status == "working" ? "circle.lefthalf.filled" : "circle") }
            }
        }
        Divider()
        Button("Open ARRA Oracles") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
        Button("Refresh") { Task { await store.refresh() } }
        Divider()
        Button("Hide from menu bar") { menuBar = false }
        Button("Quit ARRA Oracles") { NSApp.terminate(nil) }
    }
}
#endif

// MARK: - Search issues & PRs by meaning — embedded on the ANE (EmbeddingGemma 2 via Chippy :11435)

struct IndexSearchView: View {
    @ObservedObject var store: HubStore
    @ObservedObject var index: GHIndex
    @State private var query = ""
    @State private var kind = "all"
    @State private var openOnly = false
    private var slugs: [String] { Array(Set(store.oracles.compactMap { $0.checkout.flatMap(GHIndex.slug(fromCheckout:)) })).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                // Relic Studio's Embedding screen, for issues & PRs (Nat: "like this")
                Text("SEMANTIC MEMORY").font(.caption.weight(.bold)).tracking(2.5).foregroundStyle(Color.orange)
                Text("Issues & PRs").font(.custom("Avenir Next", size: 34).weight(.bold))
                Text("Every oracle's issues and pull requests, ready for meaning.").font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 22) {
                    CoverageRing(ready: index.docs.count, pending: index.pending, running: index.running)
                        .frame(width: 230)
                    VStack(alignment: .leading, spacing: 0) {
                        Label("Vector engine", systemImage: "cpu").font(.headline).foregroundStyle(HubStyle.accent).padding(.bottom, 8)
                        EngineRow(name: "Engine", value: index.engine.map { $0.ok ? "\($0.kind) · 127.0.0.1:11435 · \($0.workers) workers" : "not answering" } ?? "checking…")
                        EngineRow(name: "Model", value: GHIndex.model)
                        EngineRow(name: "Model check", value: index.engine.map { $0.ok && $0.models.contains(GHIndex.model) ? "✓ served" : "✗ not served — open the ANEEmbed app (ane-oracle)" } ?? "—",
                                  good: index.engine.map { $0.ok && $0.models.contains(GHIndex.model) })
                        EngineRow(name: "Vector space", value: index.engine.map { String($0.space.prefix(36)) + ($0.space.count > 36 ? "…" : "") } ?? "—")
                        EngineRow(name: "Index", value: "\(index.docs.count) items · \(Set(index.docs.map(\.repo)).count) repos" + (index.built.map { " · built \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                        Divider().padding(.vertical, 10)
                        Label("Batch controls", systemImage: "square.stack.3d.up").font(.headline).foregroundStyle(Color.orange).padding(.bottom, 8)
                        HStack(spacing: 10) {
                            Button { Task { await index.index(repos: slugs) } } label: {
                                Label(index.running ? "Embedding…" : "Run batch", systemImage: "play.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large).disabled(index.running || slugs.isEmpty).handCursor()
                            .help("Read issues + PRs of \(slugs.count) oracle repos with gh; embed only what is new or changed")
                            Button { Task { await index.checkEngine() } } label: { Label("Refresh", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).controlSize(.large).handCursor()
                        }
                        if !index.progress.isEmpty {
                            HStack(spacing: 6) {
                                if index.running { ProgressView().controlSize(.small) }
                                Text(index.progress).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }.padding(.top, 8)
                        }
                        if let p = index.problem { Text(p).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.top, 6) }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                }
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("e.g. flood sensors, ontology of the fleet, ANE embedding speed…", text: $query)
                        .textFieldStyle(.plain).font(.custom("Avenir Next", size: 16))
                        .onSubmit { Task { await index.search(query, kind: kind == "all" ? nil : kind, openOnly: openOnly) } }
                    if index.searching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
                HStack(spacing: 12) {
                    Picker("", selection: $kind) { Text("All").tag("all"); Text("Issues").tag("issue"); Text("PRs").tag("pr") }
                        .pickerStyle(.segmented).frame(width: 230)
                    Toggle("Open only", isOn: $openOnly).toggleStyle(.checkbox)
                    Spacer()
                }
                .onChange(of: kind) { if !query.isEmpty { Task { await index.search(query, kind: kind == "all" ? nil : kind, openOnly: openOnly) } } }
                .onChange(of: openOnly) { if !query.isEmpty { Task { await index.search(query, kind: kind == "all" ? nil : kind, openOnly: openOnly) } } }
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(index.hits) { h in HitCard(hit: h) }
                    if index.hits.isEmpty && !query.isEmpty && !index.searching {
                        Text("press ↩ to search").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
        .task {
            await index.checkEngine()
            if let q = UserDefaults.standard.string(forKey: "hubQuery"), !q.isEmpty, query.isEmpty {   // -hubQuery "…"
                query = q; await index.search(q)
            }
        }
        .task {   // first visit, or older than 6 h: refresh the index in the background
            if !index.running, index.docs.isEmpty || (index.built.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true) {
                if store.oracles.isEmpty { await store.refresh() }
                await index.index(repos: slugs)
            }
        }
    }
}

struct HitCard: View {
    let hit: IndexHit
    @State private var hover = false
    var body: some View {
        let d = hit.doc
        Button { if let u = URL(string: d.url) { NSWorkspace.shared.open(u) } } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(String(format: "%.0f%%", max(0, hit.score) * 100)).font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(HubStyle.accent).frame(width: 40, alignment: .leading)
                    Text(d.kind == "pr" ? "PR" : "issue").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Text(d.state.lowercased()).font(.caption2).foregroundStyle(d.state == "OPEN" ? Color.green : Color.secondary)
                    Text("\(d.repo)#\(d.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                }
                Text(d.title).font(.custom("Avenir Next", size: 15).weight(.medium)).lineLimit(2)
                if !d.snippet.isEmpty { Text(d.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0.045)))
        }
        .buttonStyle(.plain).handCursor()
        .onHover { hover = $0 }
        .help(d.url)
    }
}

/// The coverage ring of Relic Studio's Embedding screen: ready vs pending.
struct CoverageRing: View {
    let ready: Int, pending: Int, running: Bool
    var body: some View {
        let total = max(1, ready + pending)
        let cover = Double(ready) / Double(total)
        VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.07), lineWidth: 16)
                Circle().trim(from: 0, to: cover).stroke(HubStyle.accent.gradient, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 4) {
                    Text(ready == 0 && pending == 0 ? "—" : String(format: "%.0f%%", cover * 100)).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(running ? "embedding…" : (ready == 0 ? "awaiting first batch" : "coverage")).font(.caption).tracking(1.5).foregroundStyle(.secondary)
                }
            }
            .frame(width: 190, height: 190)
            HStack(spacing: 26) {
                VStack(spacing: 3) { Text("\(ready)").font(.headline.monospacedDigit()).foregroundStyle(.green); Text("READY").font(.caption2).tracking(1.5).foregroundStyle(.secondary) }
                VStack(spacing: 3) { Text("\(pending)").font(.headline.monospacedDigit()).foregroundStyle(.orange); Text("PENDING").font(.caption2).tracking(1.5).foregroundStyle(.secondary) }
            }
        }
    }
}

struct EngineRow: View {
    let name: String, value: String
    var good: Bool? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value).foregroundStyle(good == false ? Color.orange : (good == true ? Color.green : Color.primary)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.callout).padding(.vertical, 3)
    }
}
