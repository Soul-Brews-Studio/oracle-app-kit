#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Oracles (the landing app) — sidebar: all herdr sessions · detail: every oracle as a card
// Same look as the oracle apps: ARRA-style sidebar, cards like the Work view.

enum HubPick: Hashable { case all, search, trace, settings, session(String) }

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
    @State private var pick: HubPick = ["search": HubPick.search, "trace": .trace, "settings": .settings][UserDefaults.standard.string(forKey: "hubPage") ?? ""] ?? .all   // -hubPage search|trace|settings
    @ObservedObject private var index = GHIndex.shared
    @State private var focusTick = 0
    var body: some View {
        NavigationSplitView {
            HubSidebar(store: store, pick: $pick, menuBar: $menuBar)
                .navigationSplitViewColumnWidth(min: 240, ideal: 272)
        } detail: {
            switch pick {
            case .all: OracleBoard(store: store)
            case .search: IndexSearchView(store: store, index: index, focusTick: focusTick)
            case .trace: TraceView(name: "ARRA Oracles", accent: HubStyle.accent)
            case .settings: SettingsView(title: "ARRA Oracles", accent: HubStyle.accent, indexes: [index]) { pick = .trace }
            case .session(let name): SessionSpaces(store: store, session: name)
            }
        }
        .tint(HubStyle.accent)
        .background {   // ⌘K: search, from anywhere in the hub
            Button("") { pick = .search; focusTick += 1 }.keyboardShortcut("k", modifiers: .command).opacity(0).allowsHitTesting(false)
        }
        .onAppear { store.start() }
        .task {   // keep the ANE index fresh in the background: on launch when it is missing or older than 6 h
            for _ in 0..<20 where store.oracles.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            let slugs = Array(Set(store.oracles.compactMap { $0.checkout.flatMap(GHIndex.slug(fromCheckout:)) })).sorted()
            if !slugs.isEmpty, let why = index.staleReason {
                await index.index(repos: slugs, vaults: store.oracles.compactMap(\.checkout), why: "automatic at launch — \(why)")
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
            NavRow(symbol: "sparkle.magnifyingglass", title: "Search issues & PRs", badge: "⌘K",
                   on: pick == .search, accent: HubStyle.accent) { pick = .search }
                .padding(.horizontal, 12)
            NavRow(symbol: "list.bullet.rectangle", title: "Trace", badge: nil, on: pick == .trace, accent: HubStyle.accent, sub: true) { pick = .trace }
                .padding(.horizontal, 12)
                .help("Every query asked of the hub's index — search and MCP — and a cloud of what is searched")
            NavRow(symbol: "gearshape", title: "Settings", badge: nil, on: pick == .settings, accent: HubStyle.accent) { pick = .settings }
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
            Text(AppVersion.calver).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                .help("This build — CalVer, Bangkok time at build")
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
    @State private var confirmStop = false
    @State private var stopping = false
    @State private var stopError: String?
    @State private var resume: (resumes: [String: Int], lost: [String])?
    @State private var closed: [ClosedSpace] = []
    @State private var starting = false
    @State private var folded: Set<String> = []   // main spaces whose worktree rows are hidden; key = session:repo
    @State private var reopenError: String?
    var body: some View {
        let s = store.sessions.first { $0.name == session }
        let spaces = store.spaces.filter { $0.session == session }.sorted { $0.number < $1.number }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(session).font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(s?.running == true ? "running · \(spaces.count) spaces" : "stopped").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    if s?.running == true {
                        Button(stopping ? "Stopping…" : "Stop session", role: .destructive) {
                            resume = nil; confirmStop = true
                            Task { resume = await store.resumeCheck(session) }
                        }
                            .controlSize(.small).disabled(stopping).handCursor()
                            .help("herdr session stop \(session) — ends every pane in it")
                        Button("Open in WezTerm") { store.openSession(session) }.controlSize(.small)
                    }
                }
                if let e = stopError {
                    Text(e).font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                }
                if s?.running != true {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("This herdr session is not running. Open it in WezTerm, or from any terminal:").foregroundStyle(.secondary)
                        Text("herdr --session \(session)").font(.callout.monospaced()).textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button(starting ? "Starting…" : "Start in background") {
                                starting = true; stopError = nil
                                Task { stopError = await store.startSession(session); starting = false }
                            }.buttonStyle(.borderedProminent).controlSize(.small).disabled(starting).handCursor()
                                .help("herdr --session \(session) server, detached — no window; agents with a saved session resume")
                            Button("Open in WezTerm") { store.openSession(session) }.controlSize(.small).handCursor()
                        }
                    }
                    .padding(14)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
                }
                VStack(spacing: 2) {
                    ForEach(spaces) { sp in
                        let key = sp.session + ":" + (sp.repo ?? "")
                        let kids = sp.linked || sp.repo == nil ? [] : spaces.filter { $0.linked && $0.repo == sp.repo }
                        if !(sp.linked && folded.contains(key)) {   // a worktree row hides while its main space is folded
                            SpaceLine(space: sp, app: sp.repo.map { store.apps[HubParse.displayName($0).lowercased()] } ?? nil, store: store,
                                      children: kids,
                                      fold: kids.isEmpty ? nil : Binding(get: { folded.contains(key) },
                                                                          set: { if $0 { folded.insert(key) } else { folded.remove(key) } }))
                        }
                    }
                }
                if !closed.isEmpty { recentlyClosed(running: s?.running == true) }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(session)
        .confirmationDialog("Stop \(session)?", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("Stop \(session)", role: .destructive) {
                stopping = true; stopError = nil
                Task { stopError = await store.stopSession(session); stopping = false }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(stopWarning)
        }
        .onChange(of: session) { _, _ in stopError = nil; reopenError = nil; loadClosed() }
        .onChange(of: store.lastRefresh) { _, _ in loadClosed() }
        .onAppear { loadClosed() }
    }

    /// This session's closed spaces, newest first; inside one group the main space before its worktrees.
    private func loadClosed() {
        closed = ClosedSpaces.load().filter { $0.session == session }
            .sorted { ($0.closedAt, $0.linked == true ? 0 : 1) > ($1.closedAt, $1.linked == true ? 0 : 1) }
    }

    /// Spaces closed from this page: what they held, and Reopen (same cwd, each agent resumed).
    private func recentlyClosed(running: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            WorkFormat.header("RECENTLY CLOSED", closed.count, note: running ? "reopen brings each agent back resumed" : "start the session to reopen")
            ForEach(closed) { c in
                HStack(spacing: 10) {
                    Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.label).font(.custom("Avenir Next", size: 14).weight(.medium)).lineLimit(1).truncationMode(.middle)
                        Text(c.agents.isEmpty ? "no agents" : c.agents.map { "\($0.kind)\($0.sessionId == nil ? " (no session)" : "")" }.joined(separator: " · "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(c.closedAt.formatted(date: .omitted, time: .shortened)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Button("Reopen") { reopenError = nil; Task { reopenError = await store.reopen(c); loadClosed() } }
                        .controlSize(.small).disabled(!running).handCursor()
                    Button("Forget") { store.forget(c); loadClosed() }.controlSize(.small).handCursor()
                }
                .padding(.vertical, 5).padding(.horizontal, 10)
            }
            if let e = reopenError { Text(e).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
        }
        .padding(.top, 10)
    }

    /// What stopping ends, counted from the live spaces — busy agents named first.
    private var stopWarning: String {
        let spaces = store.spaces.filter { $0.session == session }
        let agents = spaces.reduce(0) { $0 + $1.agents }, panes = spaces.reduce(0) { $0 + $1.panes }
        let busy = spaces.filter { ["working", "done", "blocked"].contains($0.status) }
            .map { "\($0.label) (\(HubParse.word($0.status)))" }
        var t = "Ends \(spaces.count) spaces, \(panes) panes and \(agents) agents."
        if !busy.isEmpty { t += "\nStill active: " + busy.joined(separator: ", ") + "." }
        guard let r = resume else { return t + "\nChecking which agents will resume…" }
        let back = r.resumes.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ")
        t += "\nReopen resumes " + (back.isEmpty ? "no agents" : back) + " where they were."
        if !r.lost.isEmpty { t += "\nNo saved session, back as a plain shell: " + r.lost.joined(separator: ", ") + "." }
        return t
    }
}

struct SpaceLine: View {
    let space: HubSpace
    let app: URL?
    let store: HubStore
    var children: [HubSpace] = []        // worktree spaces under this main space: closing it closes them too
    var fold: Binding<Bool>? = nil       // main space with worktrees: hide / show its rows
    @State private var hover = false
    @State private var confirmClose = false
    @State private var agents: [String: [ClosedAgent]]?
    @State private var closeError: String?
    var body: some View {
        HStack(spacing: 10) {
            if space.linked { Text("└").font(.callout.monospaced()).foregroundStyle(.tertiary) }
            if let f = fold {   // fold the worktree rows under this main space
                Button { withAnimation(.snappy) { f.wrappedValue.toggle() } } label: {
                    Image(systemName: f.wrappedValue ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 10)
                }.buttonStyle(.plain).handCursor().help(f.wrappedValue ? "Show its \(children.count) worktrees" : "Hide its worktrees")
            }
            HubGlyph(status: space.status)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(space.label).font(.custom("Avenir Next", size: 15).weight(.medium)).lineLimit(1).truncationMode(.middle)
                    if fold?.wrappedValue == true {
                        Text("+\(children.count) \(children.count == 1 ? "worktree" : "worktrees")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
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
            Button("Close") {
                agents = nil; closeError = nil; confirmClose = true
                Task {
                    var all: [String: [ClosedAgent]] = [:]
                    for sp in [space] + children { all[sp.id] = await store.agents(in: sp) ?? [] }
                    agents = all
                }
            }
                .controlSize(.small).handCursor().help("Close this space only; the rest of \(space.session) keeps running")
        }
        .overlay(alignment: .bottomLeading) {
            if let e = closeError { Text(e).font(.caption).foregroundStyle(.orange).textSelection(.enabled).offset(y: 14) }
        }
        .confirmationDialog(children.isEmpty ? "Close \(space.label)?" : "Close \(space.label) and its \(children.count) worktree spaces?",
                            isPresented: $confirmClose, titleVisibility: .visible) {
            Button(children.isEmpty ? "Close space" : "Close the group (\(children.count + 1) spaces)", role: .destructive) {
                let all = agents ?? [:]
                Task { closeError = await store.closeSpace(space, children: children, agents: all) }
            }.disabled(agents == nil)
            Button("Cancel", role: .cancel) {}
        } message: { Text(closeMessage) }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .padding(.leading, space.linked ? 14 : 0)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hover ? Color.primary.opacity(0.05) : Color.clear))
        .onHover { hover = $0 }
    }

    private var closeMessage: String {
        guard let all = agents else { return "Reading the agents in this space…" }
        let a = ([space] + children).flatMap { all[$0.id] ?? [] }
        var t = children.isEmpty ? "" : "herdr closes a repo's main space only together with its worktree spaces: "
            + children.map(\.label).joined(separator: ", ") + ". The worktrees stay on disk.\n"
        if a.isEmpty { return t + "No agents here; nothing to resume." }
        let lines = a.map { "\($0.name) (\($0.kind))" + ($0.sessionId == nil ? " — no saved session, cannot resume" : "") }
        t += "Ends: " + lines.joined(separator: ", ") + ".\nSaved first, so Reopen under \"Recently closed\" brings them back resumed"
        return t + (children.isEmpty ? "." : " — the main space first, then each worktree.")
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
    private static var launchQueryDone = false   // launch arguments last the whole process: apply -hubQuery once
    private static var launchActionDone = false
    @ObservedObject var store: HubStore
    @ObservedObject var index: GHIndex
    @ObservedObject private var load = ModelLoad.shared
    var focusTick = 0
    @State private var query = ""
    @State private var kind = "all"
    @State private var openOnly = false
    @FocusState private var fieldFocused: Bool
    private var slugs: [String] { Array(Set(store.oracles.compactMap { $0.checkout.flatMap(GHIndex.slug(fromCheckout:)) })).sorted() }
    private var vaults: [String] { store.oracles.compactMap(\.checkout) }   // their ψ vaults
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                // Relic Studio's Embedding screen, for issues & PRs (Nat: "like this")
                Text("SEMANTIC MEMORY").font(.caption.weight(.bold)).tracking(2.5).foregroundStyle(Color.orange)
                Text("Issues, PRs & ψ notes").font(.custom("Avenir Next", size: 34).weight(.bold))
                Text("Every oracle's issues, pull requests and ψ vault notes, ready for meaning.").font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 22) {
                    CoverageRing(ready: index.docs.count, pending: index.pending, running: index.running,
                                 progress: index.phase == "embedding" ? Double(index.textDone) / Double(max(1, index.textTotal))
                                         : index.phase == "reading" ? Double(index.repoDone) / Double(max(1, index.repoTotal)) : nil,
                                 phase: index.phase)
                        .frame(width: 230)
                    VStack(alignment: .leading, spacing: 0) {
                        Label("Vector engine", systemImage: "cpu").font(.headline).foregroundStyle(HubStyle.accent).padding(.bottom, 8)
                        EngineRow(name: "Engine", value: index.engine.map { $0.ok ? ($0.kind.hasPrefix("bundled") ? $0.kind : "\($0.kind) · 127.0.0.1:11435 · \($0.workers) workers") : "not answering" } ?? "checking…")
                        if load.loading || load.failed != nil || load.absent { ModelLoadRow(load: load, fallback: index.engine?.ok == true && index.engine?.kind.hasPrefix("bundled") == false) }
                        if index.engine?.kind.hasPrefix("bundled") == true { NeuralEngineRow() }
                        if !load.absent { EnginePicker(load: load) }
                        EngineRow(name: "Model", value: GHIndex.model)
                        EngineRow(name: "Model check", value: index.engine.map { $0.ok && $0.models.contains(GHIndex.model) ? "✓ served" : "✗ not served — nothing embeds this model yet: see the debug log" } ?? "—",
                                  good: index.engine.map { $0.ok && $0.models.contains(GHIndex.model) })
                        EngineRow(name: "Vector space", value: index.engine.map { String($0.space.prefix(36)) + ($0.space.count > 36 ? "…" : "") } ?? "—")
                        EngineRow(name: "Index", value: "\(index.docs.count) items · \(index.docs.filter { $0.kind == "note" }.count) notes · \(Set(index.docs.map(\.repo)).count) oracles" + (index.built.map { " · built \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
                        Divider().padding(.vertical, 10)
                        Label("Batch controls", systemImage: "square.stack.3d.up").font(.headline).foregroundStyle(Color.orange).padding(.bottom, 8)
                        HStack(spacing: 10) {
                            if index.running {
                                Button { index.stop() } label: {
                                    Label(index.stopping ? "Stopping…" : "Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large).disabled(index.stopping).handCursor()
                                .keyboardShortcut(".", modifiers: .command)
                                .help("Stop the batch (⌘.) — reading: the index stays as it was; embedding: what is done is kept, the rest keeps its old vectors")
                            } else {
                                Button { Task { await index.index(repos: slugs, vaults: vaults, why: "Run batch button") } } label: {
                                    Label("Run batch", systemImage: "play.fill").frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent).tint(.orange).controlSize(.large).disabled(slugs.isEmpty || index.cooldown).handCursor()
                                .help("Read issues + PRs of \(slugs.count) oracle repos with gh; embed only what is new or changed")
                            }
                            Button { Task { await index.reembedAll(repos: slugs, vaults: vaults) } } label: {
                                Label("Re-embed all", systemImage: "bolt.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered).tint(.cyan).controlSize(.large).disabled(index.running || index.cooldown || index.docs.isEmpty).handCursor()
                            .help("Embed all \(index.docs.count) items again — in-process on this Mac's Neural Engine once the bundled model has loaded. Watch the speed and the debug log.")
                            Button { Task { await index.checkEngine() } } label: { Label("Refresh", systemImage: "arrow.clockwise").frame(maxWidth: .infinity) }
                                .buttonStyle(.bordered).controlSize(.large).handCursor()
                        }
                        if index.running || !index.rateHistory.isEmpty {
                            LiveTelemetry(index: index).padding(.top, 10)
                        }
                        if !index.progress.isEmpty {
                            Text(index.progress).font(.caption.monospaced()).foregroundStyle(.secondary).padding(.top, 6)
                        }
                        if let p = index.problem { Text(p).font(.caption).foregroundStyle(.orange).textSelection(.enabled).padding(.top, 6) }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.045)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                }
                DebugLogView()
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Ask by meaning — flood sensors, ontology of the fleet, ANE speed…   ⌘K", text: $query)
                        .textFieldStyle(.plain).font(.custom("Avenir Next", size: 16)).focused($fieldFocused)
                        .onSubmit { Task { await index.search(query, kind: kind == "all" ? nil : kind, openOnly: openOnly) } }
                    if index.searching { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(fieldFocused ? HubStyle.accent : Color.primary.opacity(0.1), lineWidth: fieldFocused ? 1.5 : 1))
                .shadow(color: fieldFocused ? HubStyle.accent.opacity(0.45) : .clear, radius: 14)
                .animation(.easeOut(duration: 0.2), value: fieldFocused)
                HStack(spacing: 12) {
                    Picker("", selection: $kind) { Text("All").tag("all"); Text("Issues").tag("issue"); Text("PRs").tag("pr"); Text("Notes").tag("note") }
                        .pickerStyle(.segmented).frame(width: 300)
                    Toggle("Open only", isOn: $openOnly).toggleStyle(.checkbox)
                    Spacer()
                }
                .onChange(of: kind) { if !query.isEmpty { Task { await index.search(query, kind: kind == "all" ? nil : kind, openOnly: openOnly) } } }
                .onChange(of: openOnly) { if !query.isEmpty { Task { await index.search(query, kind: kind == "all" ? nil : kind, openOnly: openOnly) } } }
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(index.hits.enumerated()), id: \.element.id) { i, h in
                        HitCard(hit: h, rank: i)
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                            .animation(.spring(response: 0.45, dampingFraction: 0.85).delay(Double(i) * 0.03), value: index.hits.map(\.id))
                    }
                    if index.hits.isEmpty && !query.isEmpty && !index.searching {
                        Text("press ↩ to search").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
        .onChange(of: focusTick) { fieldFocused = true }
        .onAppear { if focusTick > 0 { fieldFocused = true } }
        .onChange(of: load.finished) { Task { await index.checkEngine() } }   // the bundled model is ready: show it
        .task {   // -hubAction reembed | batch: once the bundled model is up, Re-embed all or Run batch (to time the ANE, test Stop)
            let action = UserDefaults.standard.string(forKey: "hubAction") ?? ""   // -hubAction reembed | batch
            guard !Self.launchActionDone, action == "reembed" || action == "batch" else { return }
            Self.launchActionDone = true   // launch arguments last the whole process: run it once
            for _ in 0..<1200 where ModelLoad.shared.loading || store.oracles.isEmpty {   // 10 min at most
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }   // the page went away
            }
            let stopAfter = UserDefaults.standard.double(forKey: "hubStopAfter")   // -hubStopAfter 15: press Stop 15 s in (tests Stop)
            if stopAfter > 0 { Task { try? await Task.sleep(for: .seconds(stopAfter)); index.stop() } }
            if action == "batch" { await index.index(repos: slugs, vaults: vaults, why: "-hubAction batch (test)") } else { await index.reembedAll(repos: slugs, vaults: vaults) }
        }
        .task {
            GHIndex.active = index
            await index.checkEngine()
            if !Self.launchQueryDone, let q = UserDefaults.standard.string(forKey: "hubQuery"), !q.isEmpty, query.isEmpty {   // -hubQuery "…", once
                Self.launchQueryDone = true
                query = q; await index.search(q)
            }
        }
        .task {   // first visit, or older than 6 h: refresh the index in the background
            if !index.running, let why = index.staleReason {
                if store.oracles.isEmpty { await store.refresh() }
                await index.index(repos: slugs, vaults: vaults, why: "automatic on opening Search — \(why)")
            }
        }
    }
}

struct HitCard: View {
    let hit: IndexHit
    var rank = 0
    var oracleName = "oracle"
    @State private var hover = false
    @State private var copied = false
    var body: some View {
        let d = hit.doc
        Button {
            if d.kind == "history" {   // a session line: copy the command that reopens the session
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(d.url, forType: .string)
                copied = true; Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } else if let u = URL(string: d.url) { NSWorkspace.shared.open(u) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(String(format: "%.0f%%", max(0, hit.score) * 100)).font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(HubStyle.accent).frame(width: 40, alignment: .leading)
                    Text(d.kind == "pr" ? "PR" : d.kind == "note" ? "ψ note" : d.kind == "history" ? (d.state == "user" ? "you" : oracleName) : "issue").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Text(d.kind == "note" || d.kind == "history" ? String(d.updated.prefix(10)) : d.state.lowercased()).font(.caption2).foregroundStyle(d.state == "OPEN" ? Color.green : Color.secondary)
                    Text(d.kind == "note" ? "\(d.repo) · ψ/\(d.state)\(d.number > 0 ? " · part \(d.number + 1)" : "")" : d.kind == "history" ? (copied ? "resume command copied ✓" : "session · \(String(d.updated.dropFirst(11).prefix(5)))") : "\(d.repo)#\(d.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    Spacer()
                }
                Text(d.title).font(.custom("Avenir Next", size: 15).weight(.medium)).lineLimit(2)
                GeometryReader { g in   // the match, as a glowing bar
                    let w = g.size.width * CGFloat(max(0, min(1, (hit.score - 0.4) / 0.5)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule().fill(LinearGradient(colors: [HubStyle.accent.opacity(0.5), HubStyle.accent], startPoint: .leading, endPoint: .trailing))
                            .frame(width: w).shadow(color: HubStyle.accent.opacity(0.7), radius: 6)
                    }
                }
                .frame(height: 3)
                if !d.snippet.isEmpty { Text(d.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0.045)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(hover ? HubStyle.accent.opacity(0.6) : Color.clear, lineWidth: 1))
            .shadow(color: hover ? HubStyle.accent.opacity(0.35) : .clear, radius: 12)
            .scaleEffect(hover ? 1.008 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
        }
        .buttonStyle(.plain).handCursor()
        .onHover { hover = $0 }
        .help(d.kind == "history" ? "Click to copy:  " + d.url : d.url)
    }
}

/// The coverage ring of Relic Studio's Embedding screen, alive: a glowing sweep spins while it works, the arc fills
/// with the current phase (reading repos → embedding texts), and settles on coverage when done.
struct CoverageRing: View {
    let ready: Int, pending: Int, running: Bool
    var progress: Double? = nil
    var phase = "idle"
    var readingLabel = "READING REPOS"
    @State private var spin = false
    @State private var pulse = false
    var body: some View {
        let total = max(1, ready + pending)
        let cover = Double(ready) / Double(total)
        let shown = progress ?? cover
        VStack(spacing: 14) {
            ZStack {
                ForEach(0..<60, id: \.self) { i in   // tick marks
                    Capsule().fill(Color.primary.opacity(i % 5 == 0 ? 0.28 : 0.1)).frame(width: 1.5, height: i % 5 == 0 ? 9 : 5)
                        .offset(y: -108).rotationEffect(.degrees(Double(i) * 6))
                }
                Circle().stroke(Color.primary.opacity(0.07), lineWidth: 14).frame(width: 182, height: 182)
                Circle().trim(from: 0, to: shown)
                    .stroke(AngularGradient(colors: [HubStyle.accent.opacity(0.35), HubStyle.accent, Color.cyan], center: .center),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: 182, height: 182)
                    .shadow(color: HubStyle.accent.opacity(running ? 0.9 : 0.45), radius: running ? 16 : 8)
                    .animation(.easeOut(duration: 0.4), value: shown)
                if running {   // the scanning sweep
                    Circle().trim(from: 0, to: 0.12)
                        .stroke(LinearGradient(colors: [.clear, Color.cyan], startPoint: .leading, endPoint: .trailing), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 212, height: 212)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1.6).repeatForever(autoreverses: false), value: spin)
                        .onAppear { spin = true }.onDisappear { spin = false }
                }
                VStack(spacing: 4) {
                    Text(ready == 0 && pending == 0 && !running ? "—" : String(format: "%.0f%%", shown * 100))
                        .font(.system(size: 38, weight: .heavy, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText()).animation(.easeOut, value: Int(shown * 100))
                    Text(running ? (phase == "reading" ? readingLabel : "EMBEDDING") : (ready == 0 ? "AWAITING FIRST BATCH" : "COVERAGE"))
                        .font(.caption2.weight(.semibold)).tracking(1.8).foregroundStyle(running ? Color.cyan : .secondary)
                        .opacity(running && pulse ? 0.45 : 1)
                        .animation(running ? .easeInOut(duration: 0.8).repeatForever() : .default, value: pulse)
                        .onAppear { pulse = true }
                }
            }
            .frame(width: 230, height: 230)
            HStack(spacing: 26) {
                VStack(spacing: 3) { Text("\(ready)").font(.headline.monospacedDigit()).foregroundStyle(.green).contentTransition(.numericText()); Text("READY").font(.caption2).tracking(1.5).foregroundStyle(.secondary) }
                VStack(spacing: 3) { Text("\(pending)").font(.headline.monospacedDigit()).foregroundStyle(.orange).contentTransition(.numericText()); Text("PENDING").font(.caption2).tracking(1.5).foregroundStyle(.secondary) }
            }
        }
    }
}

/// Live telemetry while a batch runs: the repo being read, texts done, and a throughput sparkline (texts/s per batch).
struct LiveTelemetry: View {
    @ObservedObject var index: GHIndex
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(index.rateHistory.last.map { "\(Int($0))" } ?? "—").font(.system(size: 26, weight: .heavy, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Color.cyan).contentTransition(.numericText())
                VStack(alignment: .leading, spacing: 1) {
                    Text(index.via.isEmpty ? "texts/s" : "texts/s · \(index.via)").font(.caption).foregroundStyle(.secondary)
                    if let c = index.lastCall {
                        Text(c.tokens > 0 ? "last call \(c.texts) texts · \(grouped(c.tokens)) tok · \(Int(c.ms)) ms · \(short(Double(c.tokens) * 1000 / max(c.ms, 1))) tok/s"
                                          : "last call \(c.texts) texts · \(Int(c.ms)) ms")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if index.phase == "reading" {
                    Text(index.currentRepo.isEmpty ? "\(grouped(index.repoDone))/\(grouped(index.repoTotal)) transcripts" : "repo \(index.repoDone + 1)/\(index.repoTotal) · \(index.currentRepo)").font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else if index.textTotal > 0 {
                    Text("\(index.textDone)/\(index.textTotal) texts").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            Sparkline(values: index.rateHistory).frame(height: 34)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            let top = max(1, values.max() ?? 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: values.count < 2 ? 0 : g.size.width * CGFloat(i) / CGFloat(values.count - 1), y: g.size.height * (1 - CGFloat(v / top)))
            }
            ZStack {
                Path { p in guard let f = pts.first else { return }; p.move(to: CGPoint(x: f.x, y: g.size.height)); pts.forEach { p.addLine(to: $0) }; p.addLine(to: CGPoint(x: pts.last!.x, y: g.size.height)) }
                    .fill(LinearGradient(colors: [Color.cyan.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                Path { p in guard let f = pts.first else { return }; p.move(to: f); pts.dropFirst().forEach { p.addLine(to: $0) } }
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)).shadow(color: Color.cyan.opacity(0.8), radius: 4)
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

/// The bundled model loading: which part loads now, compiled or from the cache, elapsed, time left, and why the
/// first launch takes minutes.
struct ModelLoadRow: View {
    @ObservedObject var load: ModelLoad
    var fallback = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Bundled model").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    if let f = load.failed {
                        Text("did not load — \(f)").foregroundStyle(.orange).lineLimit(2).textSelection(.enabled)
                        if let retry = load.retry { Button("Retry") { retry() }.controlSize(.small).handCursor() }
                    } else if load.absent {
                        Text("not in this build — embedding goes through 127.0.0.1:11435").foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        let secs = Int(ctx.date.timeIntervalSince(load.started ?? ctx.date))
                        let now = load.next.map { "worker \($0.worker + 1) · bucket \($0.bucket)" } ?? "warm-up"
                        let left = load.eta.map { eta -> String in   // counts down between parts
                            let m = max(0, eta - ctx.date.timeIntervalSince(load.lastStepAt ?? ctx.date))
                            return m >= 90 ? " · ~\(Int(m / 60 + 0.5)) min left" : " · ~\(Int(m)) s left"
                        } ?? ""
                        Text("part \(min(load.done + 1, max(load.total, 1)))/\(max(load.total, 1)) · \(now) · \(secs / 60)m \(String(format: "%02d", secs % 60))s\(left)")
                            .monospacedDigit().foregroundStyle(Color.cyan).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .font(.callout)
                if load.loading {
                    ProgressView(value: Double(load.done), total: Double(max(load.total, 1))).tint(.cyan)
                    Text((load.steps.contains { $0.seconds >= 2 }
                          ? "First launch: the Neural Engine compiles each bucket once for this app (~30 s each), then caches it — later launches take seconds. "
                          : "Loading from the Neural Engine cache. ") +
                         (fallback ? "Meanwhile search goes through the ANE service on 127.0.0.1:11435." : "Search and batches wait for it."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// The in-process Neural Engine, live — the "power up" you can watch: one light per worker, lit while its model runs,
/// texts/s and tokens/s over the last 10 s, the last call; under it the ANE itself, for the whole Mac (IOReport).
struct NeuralEngineRow: View {
    @ObservedObject private var meter = ANEMeter.shared
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let a = GHIndex.loaded?.activity() ?? EmbedActivity()
            let live = a.textsPerSecond > 0 || a.busy.contains(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .center, spacing: 10) {
                    Text(a.devices.allSatisfy { $0 == "ANE" } ? "Neural Engine" : "Workers").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                    HStack(spacing: 4) {
                        ForEach(Array(a.busy.enumerated()), id: \.offset) { i, on in
                            let tint: Color = i < a.devices.count && a.devices[i] == "GPU" ? .orange : .cyan
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(on ? tint : Color.primary.opacity(0.12))
                                .frame(width: 30, height: 13)
                                .overlay(Text(i < a.devices.count ? a.devices[i] : "\(i + 1)").font(.system(size: 8, weight: .bold, design: .rounded)).foregroundStyle(on ? Color.black : tint.opacity(0.8)))
                                .shadow(color: on ? tint : .clear, radius: on ? 6 : 0)
                        }
                    }
                    .help("This app's workers and where each runs (ANE or GPU): lit while its model runs")
                    if live {
                        Text("\(short(a.textsPerSecond)) texts/s · \(short(a.tokensPerSecond)) tok/s").monospacedDigit().foregroundStyle(Color.cyan)
                    } else {
                        Text("idle").foregroundStyle(.secondary)
                    }
                    if let c = a.last.first {
                        Text("· last \(c.texts) texts in \(Int(c.ms)) ms").monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("\(grouped(a.texts)) texts").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .help("embedded in this app since launch")
                }
                if let u = meter.utilization, let g = meter.gbs {
                    HStack(spacing: 10) {
                        Spacer().frame(width: 110)
                        Text(String(format: "ANE %.0f%% · %.1f GB/s", u, g)).font(.caption.monospacedDigit())
                            .foregroundStyle(g > 1 ? Color.cyan : .secondary)
                        Sparkline(values: meter.history).frame(width: 110, height: 14)
                        Text("whole Mac").font(.caption2).foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .help("The Neural Engine itself, read from IOReport once a second: time out of its idle state, and memory bandwidth. Counts every app using it.")
                }
            }
            .font(.callout).padding(.vertical, 3)
        }
        .onAppear { meter.watch() }
        .onDisappear { meter.unwatch() }
    }
}

/// The debug log, like a console: every model part, repo read, embed call and search, with its speed.
/// Also written to ~/Library/Logs/ARRA Oracles/embed.log.
struct DebugLogView: View {
    @ObservedObject private var log = HubLog.shared
    @AppStorage("hub.debugLog") private var open = true
    @AppStorage("hub.verboseLog") private var verbose = true
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right").rotationEffect(.degrees(open ? 90 : 0)).font(.caption.weight(.bold))
                        Label("Debug log", systemImage: "terminal").font(.headline)
                    }
                    .foregroundStyle(Color.cyan)
                }
                .buttonStyle(.plain).handCursor()
                Text("\(log.lines.count) lines").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Toggle("Verbose", isOn: $verbose).toggleStyle(.checkbox).font(.caption)
                    .help("A scan logs one line per transcript: size, lines, prose, tools, thinking, milliseconds")
                Spacer()
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(log.text, forType: .string) }
                    .buttonStyle(.borderless).handCursor()
                Button { NSWorkspace.shared.open(HubLog.file) } label: { Image(systemName: "doc.text.magnifyingglass") }
                    .buttonStyle(.borderless).handCursor().help(HubLog.file.path)
            }
            if open {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(log.lines) { l in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(HubLog.clock(l.at)).foregroundStyle(.tertiary)
                                    Text(l.kind.rawValue.uppercased()).foregroundStyle(Self.color(l.kind)).frame(width: 50, alignment: .leading)
                                    Text(l.text).foregroundStyle(l.kind == .error ? Color.orange : Color.primary.opacity(0.85))
                                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                }
                                .font(.system(size: 11, design: .monospaced)).id(l.id)
                            }
                            if log.lines.isEmpty { Text("nothing yet").font(.caption.monospaced()).foregroundStyle(.secondary) }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.35)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.cyan.opacity(0.15)))
                    .onAppear { if let id = log.lines.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                    .onChange(of: log.lines.last?.id) { if let id = log.lines.last?.id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) } } }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
    static func color(_ k: HubLog.Kind) -> Color {
        switch k {
        case .load: return .cyan
        case .read: return .secondary
        case .embed: return .green
        case .search: return HubStyle.accent
        case .info: return .secondary
        case .error: return .orange
        }
    }
}

/// Where the bundled model runs: both workers on the Neural Engine (low power), both on the GPU, or one on each
/// (fastest). Saved per Mac; a change reloads the model while the running engine keeps answering. The GPU's first
/// load compiles too, then comes from the cache like the ANE's.
struct EnginePicker: View {
    @ObservedObject var load: ModelLoad
    @AppStorage("hub.engineMode") private var mode = "ane"
    var body: some View {
        HStack(alignment: .center) {
            Text("Run on").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Picker("", selection: $mode) {
                Text("ANE").tag("ane"); Text("GPU").tag("gpu"); Text("Both").tag("both")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 210)
            .help("ANE: two Neural Engine workers, low power. GPU: two GPU workers, ~5× faster. Both: two GPU workers plus one ANE worker.")
            if load.loading { ProgressView().controlSize(.small) }
            Spacer(minLength: 0)
        }
        .font(.callout).padding(.vertical, 3)
        .onChange(of: mode) {
            HubLog.shared.add(.load, "engine picker: \(mode.uppercased()) — loading the model there; the current engine answers meanwhile")
            load.reload?(mode)
        }
    }
}
