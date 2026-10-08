import SwiftUI
import os
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Section: Hashable { case status, inbox, prs, issues, memory, map, trace, settings, extra(String) }

public struct OracleRootView: View {
    @ObservedObject private var store: OracleStore
    @Binding private var menuBar: Bool
    #if os(iOS)
    @State private var section: Section? = ["work": Section.status, "inbox": .inbox, "prs": .prs, "issues": .issues, "memory": .memory, "map": .map, "trace": .trace, "settings": .settings][UserDefaults.standard.string(forKey: "oracleSection") ?? ""] ?? .status   // -oracleSection work|inbox|prs|issues|memory|map|trace|settings
    #else
    @State private var section: Section? = ["memory": Section.memory, "map": .map, "trace": .trace, "settings": .settings, "prs": .prs, "issues": .issues][UserDefaults.standard.string(forKey: "oracleSection") ?? ""] ?? .status   // -oracleSection memory|map|trace|settings|prs|issues
    #endif
    @State private var dropTargeted = false
    @State private var inboxHot = false
    @State private var issueHot = false
    @State private var draft: IssueDraft?
    @State private var heyText = ""
    @State private var picking: [Int: PickUp.Progress] = [:]   // Issues cards whose Pick up is running or failed
    @State private var openPane: String?      // the ACTIVE pane in the drawer (message box + esc go to it)
    @State private var openPanes: [String] = []   // every pane in the drawer, stacked, at most 3 (Nat: "open 2nd and 3rd pane")
    @State private var escMonitor: Any?
    @State private var fitMonitor: Any?
    @State private var drawerFull = false  // the drawer over the whole page (⤢), esc comes back (Nat: "how to full screen")   // double-click the title bar, or the empty space beside the page: fit ↔ back
    @AppStorage("oracle.drawerWidth") private var drawerWidth: Double = 560   // what opening the drawer adds to the window, when the screen has room
    /// Work's width while the drawer is open: the drawer takes the rest (Nat, 2026-10-08: "when expand … the middle
    /// can narrow"). Dragging the drawer's edge moves it; remembered.
    @AppStorage("oracle.workNarrow") private var workNarrow: Double = 480
    // how much the drawer has grown the window — macOS saves the window frame on quit, so growth must be undone on launch
    @AppStorage("oracle.drawerGrown") private var drawerGrown: Double = 0
    #if os(iOS)
    @State private var showSettings = false
    /// iPhone: the stack shows the list of pages (.sidebar) or one page (.detail); -oracleSection (tests) starts on the page
    @State private var column: NavigationSplitViewColumn = UserDefaults.standard.string(forKey: "oracleSection") == nil ? .sidebar : .detail
    @State private var paneSheet: PhonePaneRef?      // a pane tapped in the sidebar's worktree tree
    @State private var pairLink: PhonePairLink?      // an opened pairing link, shown before it pairs
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    public init(store: OracleStore, menuBar: Binding<Bool>) { self.store = store; _menuBar = menuBar }

    private var c: OracleConfig { store.config }

    /// The drawer's width: everything but Work's narrow width and the handle, and never under 360.
    static func drawerRoom(total: CGFloat, work: Double) -> CGFloat {
        max(360, total - CGFloat(max(420, work)) - 7)
    }

    #if os(macOS)
    /// The page's column width, for fitting the window to it (Work 760, the GitHub lists 900); nil for the others.
    private var fitPage: CGFloat? {
        switch section ?? .status {
        case .status: return 760
        case .prs, .issues: return 900
        default: return nil
        }
    }

    /// Double-clicks, read as AppKit events: on the title bar (instead of macOS's zoom, which went wide again) or on
    /// the empty space right of the page's column, above the message box. Only while no drawer is open beside the page.
    /// A SwiftUI gesture on the page's background never saw these clicks (measured: no log line for any of them).
    private func installFitMonitor() {
        guard fitMonitor == nil else { return }
        fitMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
            guard e.clickCount == 2, let w = e.window, w.canBecomeMain, openPanes.isEmpty, let page = fitPage else { return e }
            let p = e.locationInWindow
            if p.y >= w.contentLayoutRect.maxY {   // the title bar and toolbar
                fitLog.notice("double-click on the title bar")
                Drawer.toggleFit(page: page, window: w)
                return nil                          // not also macOS's zoom
            }
            guard p.x > Drawer.sidebarWidth(in: w) + page + 4, p.y > 96 else { return e }
            fitLog.notice("double-click beside the page")
            Drawer.toggleFit(page: page, window: w)
            return e
        }
    }
    #endif

    private func closePane(_ place: String) {
        if place == openPane { openPane = nil } else { openPanes.removeAll { $0 == place } }
    }

    public var body: some View {
        #if os(iOS)
        phoneBody
        #else
        NavigationSplitView {
            OracleSidebar(store: store, section: $section, menuBar: $menuBar, openPane: $openPane)
                .navigationSplitViewColumnWidth(min: 240, ideal: 272)
        } detail: {
            GeometryReader { geo in
            HStack(spacing: 0) {
                #if os(macOS)
                let full = drawerFull && !openPanes.isEmpty && section == .status
                #else
                let full = false
                #endif
                if !full {
                detail
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)   // Work always fills its column
                    #if os(macOS)
                    .safeAreaInset(edge: .bottom) { HeyComposer(store: store, text: $heyText, focus: openPane) }
                    #endif
                }
                #if os(macOS)
                // the 3rd column exists only while a pane is open (Nat: 3 columns all the time was "too nested").
                // Work narrows to `workNarrow` and the drawer takes the rest of the window — or all of it, full screen
                if !openPanes.isEmpty, section == .status {
                    let room = full ? geo.size.width : Self.drawerRoom(total: geo.size.width, work: workNarrow)
                    if !full {
                        DrawerHandle(width: Binding(get: { Double(room) },
                                                    set: { workNarrow = max(420, Double(geo.size.width) - $0 - Double(DrawerHandle.width)) }))
                    }
                    VStack(spacing: 0) {
                        ForEach(openPanes, id: \.self) { place in
                            TerminalColumn(store: store, place: place, active: place == openPane,
                                           activate: { openPane = place }, close: { closePane(place) },
                                           full: full, toggleFull: { withAnimation(.easeOut(duration: 0.15)) { drawerFull.toggle() } })
                            if place != openPanes.last { Divider() }
                        }
                    }
                    .frame(width: room)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                #endif
            }
            }
            #if os(macOS)
            // a right DRAWER: the window grows by the drawer's width so Work keeps its size (Nat: "not resize the current")
            // a click anywhere sets openPane: a new place joins the stack (the oldest leaves past 3); nil = close the active one
            .onChange(of: openPane) { old, new in
                // the drawer lives on Work: a pane opened from another page (a sidebar tree row) brings Work with it
                if new != nil, section != .status { section = .status }
                if let new {
                    if !openPanes.contains(new) { openPanes.append(new); if openPanes.count > 3 { openPanes.removeFirst() } }
                } else if let old, openPanes.contains(old) {
                    openPanes.removeAll { $0 == old }
                    openPane = openPanes.last
                }
            }
            .onChange(of: openPanes.isEmpty) { wasEmpty, isEmpty in
                if wasEmpty, !isEmpty {
                    let dx = drawerWidth + DrawerHandle.width; Drawer.grow(by: dx); drawerGrown += dx
                    escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in   // esc closes the ACTIVE pane
                        if LiveTerminal.typing { return e }   // …unless you are typing into a pane: then esc is the agent's
                        if e.keyCode == 53, drawerFull { withAnimation(.easeOut(duration: 0.15)) { drawerFull = false }; return nil }   // full screen first
                        if e.keyCode == 53, openPane != nil { openPane = nil; return nil }
                        return e
                    }
                }
                if !wasEmpty, isEmpty {
                    drawerFull = false
                    Drawer.grow(by: -drawerGrown); drawerGrown = 0   // give back exactly what it took
                    if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
                }
            }
            .onChange(of: section) { _, s in if s != .status { openPanes = []; openPane = nil } }
            .onAppear { installFitMonitor() }
            .onAppear {   // quit with the drawer open: the saved frame still holds the drawer's width — take it back
                guard drawerGrown > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Drawer.grow(by: -drawerGrown, animate: false); drawerGrown = 0 }
            }
            .task {   // -oracleOpenPane <session:pane> (tests): that pane's drawer, once the window has settled
                guard let p = UserDefaults.standard.string(forKey: "oracleOpenPane") else { return }
                try? await Task.sleep(for: .seconds(2))
                openPane = p
            }
            #endif
                .toolbar {
                }
        }
        .tint(c.color)
        #if os(macOS)
        .dropDestination(for: URL.self) { urls, _ in store.receive(urls) > 0 } isTargeted: { dropTargeted = $0 }
        .overlay {
            // the overlay's own zones take the drag once it shows, so it stays while any of the three is hot
            if dropTargeted || inboxHot || issueHot {
                DropOverlay(config: c, inboxHot: $inboxHot, issueHot: $issueHot,
                            onInbox: { store.receive($0) > 0 },
                            onIssue: { urls in
                                let d = OracleStore.issueDraft(urls, oracle: c.name)
                                draft = IssueDraft(title: d.title, text: d.body)
                                return true
                            })
            }
        }
        .animation(.easeOut(duration: 0.12), value: dropTargeted || inboxHot || issueHot)
        .sheet(item: $draft) { d in IssueDraftSheet(store: store, title: d.title, text: d.text) { draft = nil } }
        .onReceive(NotificationCenter.default.publisher(for: .oracleOpenSection)) { _ in
            section = store.unread.isEmpty ? .status : .inbox     // a widget tap lands where the news is
        }
        .onReceive(NotificationCenter.default.publisher(for: .oracleServiceIssue)) { _ in takeServiceIssue() }
        .onReceive(NotificationCenter.default.publisher(for: .oracleServiceMessage)) { _ in takeServiceIssue() }
        .onAppear { takeServiceIssue() }
        .onReceive(NotificationCenter.default.publisher(for: .oracleFilesDropped)) { n in
            if let count = n.object as? Int { store.noteDrop(count); section = .inbox }
        }
        #endif
        .onAppear {
            store.start()
            #if os(macOS)
            CompanionServer.shared.attach(store: store)   // #46: the phone's work, inbox, PRs and messages come from this store
            #endif
        }
        #endif
    }

    #if os(macOS)
    private func takeServiceIssue() {
        if let d = ServiceInbox.pendingIssue { draft = d; ServiceInbox.pendingIssue = nil }
        if let m = ServiceInbox.pendingMessage { heyText = m; ServiceInbox.pendingMessage = nil }
    }
    #endif

    /// What "Send to agent…" puts in the composer for an issue or PR — edited before it is sent.
    static func brief(_ it: GHItem, pr: Bool) -> String {
        (pr ? "Review PR #\(it.number): " : "Pick up issue #\(it.number): ") + it.title + (it.url.map { " — " + $0.absoluteString } ?? "")
    }

    #if os(macOS)
    /// Pick up (or open) an issue's agent: the script makes the worktree, its space and the agent; then Work shows it
    /// with the agent's pane open in the drawer, where the message box talks to it.
    private func pickUp(_ it: GHItem, _ action: PickUp.Action) {
        guard picking[it.number] != .running else { return }
        picking[it.number] = .running
        let session = WorkFormat.homeSession(store.activity)
        Task { @MainActor in
            switch await PickUp.run(action, issue: it.number, repo: c.localPath, session: session) {
            case .started(let pane):
                picking[it.number] = nil
                await store.refresh()
                section = .status
                openPane = session.isEmpty ? pane : "\(session):\(pane)"
            case .existing:
                picking[it.number] = nil
                await store.refresh()
            case .failed(let why):
                picking[it.number] = .failed(why)
            }
        }
    }
    #endif

    @ViewBuilder private var detail: some View {
        switch section ?? .status {
        #if os(iOS)
        case .status: PhoneWorkView(store: store)
        case .inbox: PhoneInboxView(store: store)
        // the phone has no message box for "Send to agent…" to fill: the cards do not offer it
        case .prs: GHList(kind: .prs, items: store.prs, work: store.work, accent: c.color, problems: store.problems, answered: store.lastRefresh)
        case .issues: GHList(kind: .issues, items: store.issues, work: store.work, accent: c.color, problems: store.problems, answered: store.lastRefresh)
        #else
        case .status: WorkView(store: store, openPane: $openPane)
        case .inbox: InboxList(store: store)
        case .prs: GHList(kind: .prs, items: store.prs, work: store.work, accent: c.color, onSend: { heyText = Self.brief($0, pr: true) })
        case .issues: GHList(kind: .issues, items: store.issues, work: store.work, accent: c.color,
                             onSend: { heyText = Self.brief($0, pr: false) }, onPick: { pickUp($0, $1) }, picking: picking)
        #endif
        case .memory:
            #if os(macOS)
            HistoryView(config: c)   // the oracle's own sessions, searched by meaning
            #else
            PhoneMemoryView(store: store)   // searched on the Mac over the companion API
            #endif
        case .map:
            #if os(macOS)
            if #available(macOS 26, *) { MapView(name: c.name, accent: c.color, index: GHIndex.history(c.repoSlug)) }   // the memory as one 3-D space
            else { Text("The Map needs macOS 26").foregroundStyle(.secondary) }
            #else
            PhoneMapView(store: store)
            #endif
        case .trace:
            #if os(macOS)
            TraceView(name: c.name, accent: c.color)   // every query asked of that memory, page and MCP
            #else
            PhoneTraceView(store: store)
            #endif
        case .settings:
            #if os(macOS)
            SettingsView(title: c.name, accent: c.color, indexes: [GHIndex.history(c.repoSlug)]) { section = .trace }
            #else
            PhoneSettingsView(store: store)   // the pairing and the GitHub token
            #endif
        case .extra(let id): c.extras.sections.first { $0.id == id }.map { $0.view() } ?? AnyView(EmptyView())
        }
    }

}

/// The whole app in one scene; a thin app's @main body is just `OracleScene(config:)`.
/// The store and the menu-bar switch belong to the App (`@StateObject` + `@AppStorage` there) — the shape
/// ARRA Oracles ended up with after its MenuBarExtra loop. Each oracle app passes them in:
///     @StateObject private var store = OracleStore(config: .neo)
///     @AppStorage("oracle.menuBar") private var menuBar = false
///     var body: some Scene { OracleScene(store: store, menuBar: $menuBar) }
public struct OracleScene: Scene {
    let store: OracleStore
    @Binding var menuBar: Bool
    public init(store: OracleStore, menuBar: Binding<Bool>) {
        self.store = store; _menuBar = menuBar; OracleConfig.current = store.config
    }
    public var body: some Scene {
        #if os(macOS)
        // One window per oracle app: a Dock drop or a restored state must never open a second one.
        Window("\(store.config.name) Oracle", id: "main") { OracleRootView(store: store, menuBar: $menuBar) }
            .defaultSize(width: 980, height: 640)
        // The oracle's own status tray, off until switched on. The binding writes on change only — the
        // status item writes the same value back on every update, and an @AppStorage write re-renders forever.
        MenuBarExtra("\(store.config.name) Oracle", systemImage: store.config.symbol,
                     isInserted: Binding(get: { menuBar }, set: { if $0 != menuBar { menuBar = $0 } })) {
            OracleMenu(store: store, menuBar: $menuBar)
        }
        #else
        WindowGroup("\(store.config.name) Oracle") { OracleRootView(store: store, menuBar: $menuBar) }
        #endif
    }
}

#if os(macOS)
/// The tray's menu: the oracle's state, its panes by urgency, unread inbox, and the way back to the window.
struct OracleMenu: View {
    @ObservedObject var store: OracleStore
    @Binding var menuBar: Bool
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let need = store.activity.filter { $0.status == "blocked" || $0.status == "done" }.count
        let working = store.activity.filter { $0.status == "working" }.count
        let name = store.config.name
        Text("\(name) Oracle — " + (need > 0 ? "\(need) need you" : working > 0 ? "\(working) working" : "idle"))
        Divider()
        ForEach(store.activity.sorted { WorkFormat.rank($0.status) < WorkFormat.rank($1.status) }.prefix(8), id: \.place) { a in
            Button { open() } label: {
                Label(String(a.title.prefix(64)), systemImage: a.status == "working" ? "circle.lefthalf.filled"
                      : (a.status == "done" || a.status == "blocked") ? "checkmark.circle" : "circle")
            }
        }
        if !store.unread.isEmpty {
            Divider()
            Button("\(store.unread.count) unread in the inbox") { open() }
        }
        Divider()
        Button("Open \(name) Oracle") { open() }
        Button("Refresh") { Task { await store.refresh() } }
        Divider()
        Button("Hide from menu bar") { menuBar = false }
        Button("Quit \(name)") { NSApp.terminate(nil) }
    }
    private func open() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}
#endif

#if os(iOS)
extension OracleRootView {
    /// iPhone and iPad: the Mac's split view — the pages on the left, a page on the right (issue #46). The iPad keeps both
    /// columns; the iPhone collapses to a stack, the list of pages first and a page pushed on it.
    /// OracleSidebar's rows only set `section`, so `phonePick` also pushes the page.
    private var phoneBody: some View {
        NavigationSplitView(preferredCompactColumn: $column) {
            GeometryReader { g in   // the list scrolls when the screen is short (iPhone on its side), else its footer sits at the bottom
                ScrollView {
                    OracleSidebar(store: store, section: phonePick, menuBar: $menuBar, openPane: $openPane)
                        .frame(minHeight: g.size.height)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationBarTitleDisplayMode(.inline)      // every page has its own big line
                .refreshable { await store.refresh() }       // PRs and issues; the other pages pull their own
                .toolbar {
                    ToolbarItem {
                        Button { Task { await store.refresh(); NotificationCenter.default.post(name: .oraclePhoneReload, object: nil) } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Refresh")
                    }
                    ToolbarItem { Button { showSettings = true } label: { Image(systemName: "gear") }.accessibilityLabel("Settings") }
                }
        }
        .tint(c.color)
        .sheet(isPresented: $showSettings) { PhoneSettingsSheet(store: store) }
        .sheet(item: $paneSheet) { PhonePaneScreen(ref: $0, accent: c.color, home: WorkFormat.homeSession(store.activity)) }
        .onChange(of: openPane) { _, new in   // a pane tapped in the sidebar's worktree tree opens its screen
            guard let new else { return }
            let a = store.activity.first { $0.place == new }
            paneSheet = PhonePaneRef(place: new, title: a?.title ?? "", status: a?.status ?? "")
            openPane = nil
        }
        // an opened oracle-<name>://pair?… link (Camera, a note, a message) opens the pair sheet with it filled in: the person
        // sees which Mac it is, and that it is this oracle's, before anything pairs — a link alone never re-points the phone
        .onOpenURL { url in if url.host == "pair" { pairLink = PhonePairLink(url: url) } }
        .sheet(item: $pairLink) { CompanionPairView(link: $0.url.absoluteString) }
        .task {   // -companionPair <link> (tests) is the store's: it pairs before the first refresh. Here: ask the Mac who it is
            if CompanionClient.shared.isPaired { await CompanionClient.shared.refreshHello() }
        }
        .onAppear { store.start() }
    }

    /// What the sidebar sees as the open page. On the iPhone, while the list of pages is what shows, none: its Work row folds
    /// the worktree tree when it thinks it is already on Work, and there a tap must open the page.
    private var phonePick: Binding<Section?> {
        Binding(
            get: { () -> Section? in sizeClass == .compact && column == .sidebar ? Section.extra("") : section },
            set: { new in section = new; if new != nil { column = .detail } })
    }
}
#endif
