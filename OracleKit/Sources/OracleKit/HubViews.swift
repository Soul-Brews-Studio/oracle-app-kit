#if os(macOS)
import SwiftUI
import AppKit

// MARK: - Oracles (the landing app) — sidebar: all herdr sessions · detail: every oracle as a card
// Same look as the oracle apps: ARRA-style sidebar, cards like the Work view.

enum HubPick: Hashable { case all, search, trace, map, screens, network, settings, session(String), group(String), remote(RemoteSession) }

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
    @State private var jumping = false   // the ⌘K switcher
    @State private var pick: HubPick = UserDefaults.standard.string(forKey: "hubSession").map { HubPick.session($0) }   // -hubSession <name> (tests)
        ?? UserDefaults.standard.string(forKey: "hubRemote").flatMap { s -> HubPick? in   // -hubRemote <target>|<session> (tests)
            let p = s.split(separator: "|").map(String.init)
            return p.count == 2 ? .remote(RemoteSession(target: p[0], session: p[1])) : nil
        }
        ?? ["search": HubPick.search, "trace": .trace, "map": .map, "screens": .screens, "network": .network, "settings": .settings][UserDefaults.standard.string(forKey: "hubPage") ?? ""] ?? .all   // -hubPage search|trace|map|screens|network|settings
    @ObservedObject private var index = GHIndex.shared
    @State private var focusTick = 0
    // Pages visited, like a browser's (Nat: Discord's mouse 4 / 5): back and forward, and the move in flight so
    // going back is not itself recorded as a visit
    @State private var back: [HubPick] = []
    @State private var forward: [HubPick] = []
    @State private var travelling = false
    @State private var mouse: Any?

    private func goBack() { guard let p = back.popLast() else { return }; forward.append(pick); travelling = true; pick = p }
    private func goForward() { guard let p = forward.popLast() else { return }; back.append(pick); travelling = true; pick = p }

    var body: some View {
        NavigationSplitView {
            HubSidebar(store: store, pick: $pick, menuBar: $menuBar)
                .navigationSplitViewColumnWidth(min: 240, ideal: 272)
        } detail: {
            switch pick {
            case .all: OracleBoard(store: store)
            case .search: IndexSearchView(store: store, index: index, focusTick: focusTick)
            case .trace: TraceView(name: "ARRA Oracles", accent: HubStyle.accent)
            case .map: FleetMapPage(accent: HubStyle.accent)
            case .screens: ScreensPage(store: store, accent: HubStyle.accent)
            case .network: NetworkPage(store: store, pick: $pick)
            case .settings: SettingsView(title: "ARRA Oracles", accent: HubStyle.accent, indexes: [index, FleetMap.shared.index]) { pick = .trace }
            case .session(let name): SessionSpaces(store: store, session: name)
            case .group(let name): SessionGroupPage(store: store, name: name, pick: $pick)   // a session name across machines
            case .remote(let r): RemoteSessionPage(store: store, remote: r)   // same as a local session's page (Nat)
            }
        }
        .tint(HubStyle.accent)
        .onChange(of: pick) { old, _ in
            if travelling { travelling = false } else { back.append(old); forward = []; if back.count > 50 { back.removeFirst() } }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { goBack() } label: { Image(systemName: "chevron.left") }.disabled(back.isEmpty)
                    .help("Back — mouse button 4, ⌘[")
                Button { goForward() } label: { Image(systemName: "chevron.right") }.disabled(forward.isEmpty)
                    .help("Forward — mouse button 5, ⌘]")
            }
        }
        .background {   // ⌘[ ⌘]: back and forward
            Button("") { goBack() }.keyboardShortcut("[", modifiers: .command).opacity(0).allowsHitTesting(false)
            Button("") { goForward() }.keyboardShortcut("]", modifiers: .command).opacity(0).allowsHitTesting(false)
        }
        .onAppear {
            // mouse 4 / 5 (buttonNumber 3 / 4): a LOCAL monitor — only the hub's own windows, no Accessibility or
            // Input Monitoring permission
            guard mouse == nil else { return }
            mouse = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { e in
                HubLog.shared.add(.info, "mouse: button \(e.buttonNumber + 1) (buttonNumber \(e.buttonNumber))\(e.buttonNumber == 3 ? " → back" : e.buttonNumber == 4 ? " → forward" : "")")
                switch e.buttonNumber {
                case 3: goBack(); return nil
                case 4: goForward(); return nil
                default: return e
                }
            }
        }
        .background {   // ⌘K: jump to an oracle or a session; ⌘F: search issues, PRs and notes (Nat, 2026-10-09)
            Button("") { jumping = true }.keyboardShortcut("k", modifiers: .command).opacity(0).allowsHitTesting(false)
            Button("") { pick = .search; focusTick += 1 }.keyboardShortcut("f", modifiers: .command).opacity(0).allowsHitTesting(false)
        }
        .sheet(isPresented: $jumping) {
            HubJumpPalette(store: store) { j in
                switch j {
                case .session(let name, _): pick = .session(name)
                case .oracle(_, _, let session, let key): if let session { pick = .session(session) } else { store.openApp(key) }
                }
            }
        }
        .onAppear { store.start() }
        .task {   // keep the ANE index fresh in the background: on launch when it is missing or older than 6 h
            for _ in 0..<20 where store.oracles.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            let slugs = Array(Set(store.oracles.compactMap { $0.checkout.flatMap(GHIndex.slug(fromCheckout:)) })).sorted()
            if !slugs.isEmpty, let why = index.staleReason {
                await index.index(repos: slugs, vaults: store.oracles.compactMap(\.checkout), why: "automatic at launch — \(why)")
            }
            // #37: the fleet map's layout, in the background, the first time (later the Map page keeps it fresh)
            let fleet = FleetMap.shared
            if #available(macOS 26, *), fleet.index.layout.meta == nil, MapLayout.engine != nil {   // the map itself needs macOS 26
                await fleet.load(why: "launch: no fleet layout yet")
                await fleet.index.layout.fit(docs: fleet.index.docs, space: fleet.index.space, why: "launch: no fleet layout yet")
                await fleet.index.clusters.refresh(layout: fleet.index.layout, docs: fleet.index.docs)
            }
        }
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
                    Text("\(running) of \(store.localSessions.count) herdr sessions running · \(store.spaces.count) spaces · \(store.oracles.count) repos"
                         + (store.remotes.isEmpty ? "" : " · \(store.remotes.count) remote"))
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
            .frame(maxWidth: .infinity)   // centred in what the sidebar and the drawer leave (#57); a narrow window is unchanged
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
        Button("Refresh") { Task { await store.refresh(remotes: true) } }
        Divider()
        Button("Hide from menu bar") { menuBar = false }
        Button("Quit ARRA Oracles") { NSApp.terminate(nil) }
    }
}
#endif
