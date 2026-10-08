import SwiftUI
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
    @State private var section: Section? = ["memory": Section.memory, "map": .map, "trace": .trace, "settings": .settings][UserDefaults.standard.string(forKey: "oracleSection") ?? ""] ?? .status   // -oracleSection memory|map|trace|settings
    #endif
    @State private var dropTargeted = false
    @State private var inboxHot = false
    @State private var issueHot = false
    @State private var draft: IssueDraft?
    @State private var heyText = ""
    @State private var openPane: String?      // the ACTIVE pane in the drawer (message box + esc go to it)
    @State private var openPanes: [String] = []   // every pane in the drawer, stacked, at most 3 (Nat: "open 2nd and 3rd pane")
    @State private var escMonitor: Any?
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
                detail
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)   // Work always fills its column
                    #if os(macOS)
                    .safeAreaInset(edge: .bottom) { HeyComposer(store: store, text: $heyText, focus: openPane) }
                    #endif
                #if os(macOS)
                // the 3rd column exists only while a pane is open (Nat: 3 columns all the time was "too nested").
                // Work narrows to `workNarrow` and the drawer takes the rest of the window
                if !openPanes.isEmpty, section == .status {
                    let room = Self.drawerRoom(total: geo.size.width, work: workNarrow)
                    DrawerHandle(width: Binding(get: { Double(room) },
                                                set: { workNarrow = max(420, Double(geo.size.width) - $0 - Double(DrawerHandle.width)) }))
                    VStack(spacing: 0) {
                        ForEach(openPanes, id: \.self) { place in
                            TerminalColumn(store: store, place: place, active: place == openPane,
                                           activate: { openPane = place }, close: { closePane(place) })
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
                        if e.keyCode == 53, openPane != nil { openPane = nil; return nil }
                        return e
                    }
                }
                if !wasEmpty, isEmpty {
                    Drawer.grow(by: -drawerGrown); drawerGrown = 0   // give back exactly what it took
                    if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
                }
            }
            .onChange(of: section) { _, s in if s != .status { openPanes = []; openPane = nil } }
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
        case .prs: GHList(kind: .prs, items: store.prs, work: store.work, accent: c.color) { heyText = Self.brief($0, pr: true) }
        case .issues: GHList(kind: .issues, items: store.issues, work: store.work, accent: c.color) { heyText = Self.brief($0, pr: false) }
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

// MARK: - Sidebar, after ARRA Chat: brand row · pill nav · "where this runs" footer

struct OracleSidebar: View {
    @ObservedObject var store: OracleStore
    @AppStorage("oracle.workTreeOpen") private var workOpen = true
    @Binding var section: Section?
    @Binding var menuBar: Bool
    var openPane: Binding<String?> = .constant(nil)
    #if os(macOS)
    static let hubApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "co.laris.oracle.hub")
    #endif
    var body: some View {
        let c = store.config
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                ZStack {
                    Circle().fill(c.color.gradient).frame(width: 30, height: 30)
                    Image(systemName: c.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
                #if os(iOS)
                .accessibilityHidden(true)   // the oracle's name is the next line; the symbol alone is read as its raw name
                #endif
                Text("\(c.name) Oracle").font(.custom("Avenir Next", size: 20).weight(.semibold)).tracking(-0.4).lineLimit(1)
                Spacer(minLength: 4)
                SidebarIconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refresh() } }
            }
            .padding(.horizontal, 18).frame(height: 70)
            VStack(spacing: 3) {
                // the worktree tree folds: expanded by default, on every page while open; click Work again to fold it
                NavRow(symbol: "square.stack.3d.up", title: "Work",
                       badge: (store.work.isEmpty ? "" : "\(store.work.count) ") + (workOpen ? "▾" : "▸"),
                       on: (section ?? .status) == .status, accent: c.color) {
                    if (section ?? .status) == .status { workOpen.toggle() } else { section = .status; workOpen = true }
                }
                .help(workOpen ? "Click again to fold the worktrees" : "Click again to show the worktrees")
                if workOpen { WorkTree(store: store, openPane: openPane) }   // herdr-style, LIVE only
                NavRow(symbol: store.unread.isEmpty ? "tray" : "tray.full", title: "Inbox",
                       badge: store.unread.isEmpty ? (store.inbox.isEmpty ? nil : store.inbox.count >= 300 ? "300+" : "\(store.inbox.count)")
                                                   : "\(store.unread.count) new",
                       on: section == .inbox, accent: c.color) { section = .inbox }
                NavRow(symbol: "arrow.triangle.pull", title: "Pull requests", badge: store.prs.isEmpty ? nil : "\(store.prs.count)",
                       on: section == .prs, accent: c.color) { section = .prs }
                NavRow(symbol: "exclamationmark.circle", title: "Issues", badge: store.issues.isEmpty ? nil : "\(store.issues.count)",
                       on: section == .issues, accent: c.color) { section = .issues }
                NavRow(symbol: "brain", title: "Memory", badge: nil, on: section == .memory, accent: c.color) { section = .memory }
                    .help("\(c.name)'s own session history, searched by meaning")
                NavRow(symbol: "point.3.filled.connected.trianglepath.dotted", title: "Map", badge: nil, on: section == .map, accent: c.color, sub: true) { section = .map }
                    .help("\(c.name)'s memory as one 3-D space — close means related")
                NavRow(symbol: "list.bullet.rectangle", title: "Trace", badge: nil, on: section == .trace, accent: c.color, sub: true) { section = .trace }
                    .help("Every query asked of \(c.name)'s memory — the page and MCP — and a cloud of what is searched")
                NavRow(symbol: "gearshape", title: "Settings", badge: nil, on: section == .settings, accent: c.color) { section = .settings }
                    #if os(macOS)
                    .help("Engine, vector search, MCP, and the trace of every query")
                    #endif
                ForEach(c.extras.sections) { x in
                    NavRow(symbol: x.symbol, title: x.title, badge: nil, on: section == .extra(x.id), accent: c.color) { section = .extra(x.id) }
                }
            }
            .padding(.horizontal, 12)
            #if os(macOS)
            // back to the landing app: every oracle and every herdr session
            if let hub = OracleSidebar.hubApp {
                NavRow(symbol: "circle.hexagongrid", title: "ARRA Oracles", badge: "↗", on: false, accent: c.color) {
                    NSWorkspace.shared.openApplication(at: hub, configuration: NSWorkspace.OpenConfiguration())
                }
                .help("Open ARRA Oracles — every oracle and every herdr session")
                .padding(.horizontal, 12).padding(.top, 14)
            }
            #endif
            Spacer(minLength: 16)
            footer(c)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// Where this runs and how fresh it is — ARRA's "Local on this Mac" block.
    private func footer(_ c: OracleConfig) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            #if os(iOS)
            PhoneFooterStatus()
            #else
            HStack(spacing: 8) {
                Circle().fill(store.problems.isEmpty ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(store.problems.isEmpty ? "Live on this Mac" : "Needs a look")
                    .font(.custom("Avenir Next", size: 13).weight(.semibold))
            }
            #endif
            Text(c.repoSlug).font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary.opacity(0.85))
            if let t = store.lastRefresh {
                #if os(iOS)
                Text("updated \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                #else
                Text("herdr · maw · gh — updated \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                #endif
            }
            Text(AppVersion.calver).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                .help("This build — CalVer, Bangkok time at build")
            if let d = store.lastDrop {
                Label(d, systemImage: "tray.and.arrow.down").font(.system(size: 11)).foregroundStyle(c.color)
            }
            ForEach(store.problems, id: \.self) { p in
                Text(p).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
            }
            #if os(macOS)
            Toggle("Show in menu bar", isOn: $menuBar).toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
            #endif
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

struct NavRow: View {
    let symbol: String, title: String
    let badge: String?
    let on: Bool
    let accent: Color
    var sub = false   // a page under the row above (Trace under Memory): indented, smaller, hung on a └
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: sub ? 8 : 12) {
                if sub { Text("└").font(.system(size: 13, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 18) }
                Image(systemName: symbol).font(.system(size: sub ? 12 : 14, weight: .medium)).frame(width: sub ? 16 : 18)
                Text(title).font(.custom("Avenir Next", size: sub ? 14 : 15).weight(on ? .semibold : .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(on ? accent : Color.secondary)
                }
            }
            .foregroundStyle(on ? accent : Color.primary.opacity(0.8))
            .padding(.horizontal, 14).padding(.vertical, sub ? 7 : 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? accent.opacity(0.16) : (hover ? Color.primary.opacity(0.06) : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .onHover { hover = $0 }
    }
}

struct SidebarIconButton: View {
    let symbol: String, help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .foregroundStyle(hover ? Color.primary : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Color.primary.opacity(0.08) : Color.clear))
        }
        .buttonStyle(.plain).handCursor().help(help)
        #if os(iOS)
        .accessibilityLabel(help)
        #endif
        .onHover { hover = $0 }
    }
}

// MARK: - Work: one row per /herdr-wt worktree
// Layout card: neo-oracle ψ/writing/diagrams/2026-10-07_oracle-app-work-view.txt

#if os(macOS)
struct WorkView: View {
    @ObservedObject var store: OracleStore
    var openPane: Binding<String?> = .constant(nil)
    @State private var allResumable = false
    @State private var showCold = true          // open: a cold list on view is a list that gets cleaned up
    @State private var copiedPlan = false
    @State private var copied: String?
    private var c: OracleConfig { store.config }

    var body: some View {
        let work = store.work
        let live = work.filter { $0.state <= .open }
        let resumable = work.filter { $0.state == .resumable }
        let cold = work.filter { $0.state == .cold }
        let next: [WorkParse.NextIssue] = work.isEmpty ? [] : WorkParse.unstarted(issues: store.issues, prs: store.prs, work: work)
        let twins = WorkParse.twins(store.activity)
        let home = WorkFormat.homeSession(store.activity)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                WorkHero(acts: store.activity, color: c.color)
                if !live.isEmpty {
                    block("LIVE", live.count) {
                        ForEach(live) { w in
                            LiveCard(item: w, config: c, twins: twins, home: home, copied: $copied, openPane: openPane,
                                     shells: panesOf(w, store: store).filter { p in !w.panes.contains { $0.place == p } }) {
                                #if os(macOS)
                                store.bringToMain(w)
                                if w.panes.contains(where: { $0.place == openPane.wrappedValue }) { openPane.wrappedValue = nil }   // bring here closes its drawer
                                #endif
                            }
                        }
                    }
                }
                if !resumable.isEmpty {
                    block("RESUMABLE", resumable.count) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(allResumable ? resumable : Array(resumable.prefix(6))) { TreeRow(item: $0, config: c, copied: $copied) }
                        }
                        if resumable.count > 6 {
                            Button(allResumable ? "show less" : "\(resumable.count - 6) more") { allResumable.toggle() }.handCursor()
                                .buttonStyle(.link).padding(.leading, 4)
                        }
                    }
                }
                if !cold.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Button { withAnimation(.snappy) { showCold.toggle() } } label: {
                                HStack(spacing: 6) {
                                    WorkFormat.header("COLD", cold.count, note: "no session to resume — clean them up")
                                    Image(systemName: showCold ? "chevron.down" : "chevron.right")
                                        .font(.caption2.bold()).foregroundStyle(.secondary)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).handCursor()
                            // the plan only: maw herdr clean lists what it would remove; nothing changes without --go
                            let plan = WorkFormat.cleanCommand(cold.map(\.path))
                            Button(copiedPlan ? "plan copied" : "copy cleanup plan") { WorkFormat.copy(plan); copiedPlan = true }.handCursor()
                                .buttonStyle(.link).font(.caption).help(plan)
                        }
                        if showCold {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(cold) { TreeRow(item: $0, config: c, copied: $copied).opacity(0.7) }
                            }
                        }
                    }
                }
                if !next.isEmpty {
                    block("NEXT", next.count, note: next.count == 1 ? "issue with no worktree yet" : "issues with no worktree yet") {
                        NextBox(next: next)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay { if work.isEmpty { emptyNote } }
        .navigationTitle("Work")
    }

    private func block<Content: View>(_ title: String, _ n: Int, note: String = "",
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkFormat.header(title, n, note: note)
            content()
        }
    }

    @ViewBuilder private var emptyNote: some View {
        #if os(macOS)
        Text("Nothing from maw herdr ls for \(c.localPath)").foregroundStyle(.secondary)
        #else
        Text("Work is read from herdr on the Mac.").foregroundStyle(.secondary)
        #endif
    }
}
#endif

/// The widget's rule: needs you > working > idle — one big word, the counts, the urgent pane's ask.
struct WorkHero: View {
    let acts: [OracleSnapshot.Activity]; let color: Color
    var body: some View {
        let need = acts.filter { $0.status == "blocked" || $0.status == "done" }.count
        let working = acts.filter { $0.status == "working" }.count
        let urgent = acts.min { WorkFormat.rank($0.status) < WorkFormat.rank($1.status) }
        VStack(alignment: .leading, spacing: 6) {
            Text(need > 0 ? "needs you" : working > 0 ? "working" : "idle")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(need + working > 0 ? color : Color.secondary)
            Text("\(acts.count) \(acts.count == 1 ? "pane" : "panes") · \(working) working · \(need) need you")
                .font(.callout).foregroundStyle(.secondary)
            if let t = urgent?.title, !t.isEmpty {
                Text("“\(t)”").font(.callout).lineLimit(2).foregroundStyle(.primary.opacity(0.85))
            }
        }
    }
}

struct LiveCard: View {
    let item: WorkItem; let config: OracleConfig; let twins: [String: String]; let home: String
    @Binding var copied: String?
    var openPane: Binding<String?> = .constant(nil)
    var shells: [String] = []          // plain shell panes of this worktree's herdr space
    var bring: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.slug).font(.headline).lineLimit(1)
                Text(item.branch).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                WorkLinks(item: item, repo: config.repoSlug)
                Text(item.state.label).font(.caption).foregroundStyle(.secondary)
                #if os(macOS)
                // its WezTerm window, moved to the main display and focused — Window Arranger's ⌘⏎ "ย้ายมา"
                Button("bring here", action: bring).buttonStyle(.borderless).font(.caption.weight(.medium)).handCursor()
                    .help("Bring this worktree's WezTerm window to the main display and focus it")
                #endif
            }
            ForEach(item.panes.sorted { WorkFormat.rank($0.status) < WorkFormat.rank($1.status) }, id: \.place) { p in
                HStack(spacing: 8) {
                    Circle().fill(WorkFormat.dot(p.status, config.color)).frame(width: 7, height: 7)
                    Text(WorkFormat.pane(p.place, home: home)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .frame(width: 104, alignment: .leading)
                    if let twin = twins[p.place] {
                        Text("same session as \(WorkFormat.pane(twin, home: home)) — two panes, one transcript")
                            .foregroundStyle(.orange).lineLimit(1)
                    } else {
                        Text(p.title).lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 6)
                    if let s = p.since { Text(WorkFormat.ago(s)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                    Image(systemName: openPane.wrappedValue == p.place ? "chevron.right.circle.fill" : "chevron.right")
                        .font(.caption).foregroundStyle(openPane.wrappedValue == p.place ? config.color : Color.secondary.opacity(0.6))
                }
                .font(.callout)
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(openPane.wrappedValue == p.place ? config.color.opacity(0.14) : Color.clear))
                .contentShape(Rectangle())
                .handCursor()
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { openPane.wrappedValue = openPane.wrappedValue == p.place ? nil : p.place } }
                .help("Show this pane's terminal here (click again to close)")
            }
            ForEach(shells, id: \.self) { place in   // no agent here: its shell, openable all the same
                HStack(spacing: 8) {
                    Circle().stroke(Color.secondary, lineWidth: 1).frame(width: 7, height: 7)
                    Text(WorkFormat.pane(place, home: home)).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
                    Text("shell").foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Image(systemName: openPane.wrappedValue == place ? "chevron.right.circle.fill" : "chevron.right")
                        .font(.caption).foregroundStyle(openPane.wrappedValue == place ? config.color : Color.secondary.opacity(0.6))
                }
                .font(.callout)
                .padding(.vertical, 3).padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(openPane.wrappedValue == place ? config.color.opacity(0.14) : Color.clear))
                .contentShape(Rectangle()).handCursor()
                .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { openPane.wrappedValue = openPane.wrappedValue == place ? nil : place } }
                .help("Show this shell's terminal here")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .contextMenu {
            #if os(macOS)
            Button("Bring WezTerm here", action: bring).handCursor()
            Divider()
            #endif
            WorkMenu(item: item, repo: config.repoSlug, copied: $copied)
        }
    }
}

/// A resumable or cold worktree: slug, its issue and PR, age, and the way back in.
struct TreeRow: View {
    let item: WorkItem; let config: OracleConfig
    @Binding var copied: String?
    var body: some View {
        HStack(spacing: 10) {
            Text(item.slug).lineLimit(1).truncationMode(.middle)
            WorkLinks(item: item, repo: config.repoSlug)
            Spacer(minLength: 8)
            Text(item.born.map(WorkFormat.ago) ?? "").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            if let cmd = item.resumeCommand {
                Button(copied == item.id ? "copied" : "resume") { WorkFormat.copy(cmd); copied = item.id }.handCursor()
                    .buttonStyle(.borderless).help(cmd)
                    .frame(width: 64, alignment: .trailing)
            } else {
                let clean = WorkFormat.cleanCommand([item.path])
                Button(copied == item.id ? "copied" : "clean up") { WorkFormat.copy(clean); copied = item.id }.handCursor()
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help(clean)
                    .frame(width: 64, alignment: .trailing)
            }
        }
        .padding(.vertical, 4).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .contextMenu { WorkMenu(item: item, repo: config.repoSlug, copied: $copied) }
    }
}

/// Open issues no worktree names — /herdr-wt starts here: issue first, then the tree.
struct NextBox: View {
    let next: [WorkParse.NextIssue]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(next) { n in
                HStack(spacing: 10) {
                    Text("#\(n.issue.number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    Text(n.issue.title).lineLimit(1)
                    Spacer(minLength: 8)
                    if let pr = n.pr { WorkChip(text: "PR #\(pr.number)") { if let u = pr.url { WorkFormat.open(u) } } }
                }
                .contentShape(Rectangle())
                .handCursor()
                .onTapGesture { if let u = n.issue.url { WorkFormat.open(u) } }
                .contextMenu {
                    if let u = n.issue.url { Button("Open issue #\(n.issue.number)") { WorkFormat.open(u) } }
                    if let pr = n.pr, let u = pr.url { Button("Open PR #\(pr.number)") { WorkFormat.open(u) } }
                }
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }
}

// MARK: - Drop: DaisyDisk-style dashed zones — Inbox, or draft a new issue

struct DropOverlay: View {
    let config: OracleConfig
    @Binding var inboxHot: Bool
    @Binding var issueHot: Bool
    let onInbox: ([URL]) -> Bool
    let onIssue: ([URL]) -> Bool
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            HStack(spacing: 16) {
                DropZone.inbox(hot: inboxHot, accent: config.color)
                    .dropDestination(for: URL.self) { urls, _ in onInbox(urls) } isTargeted: { inboxHot = $0 }
                #if os(macOS)
                DropZone.issue(repo: config.repoSlug, hot: issueHot, accent: config.color)
                    .dropDestination(for: URL.self) { urls, _ in onIssue(urls) } isTargeted: { issueHot = $0 }
                #endif
            }
            .padding(18)
        }
        .transition(.opacity)
    }
}

/// One dashed drop zone, DaisyDisk-style. Kept apart from .dropDestination so it can be rendered in tests.
struct DropZone: View {
    let title: String, symbol: String, note: String
    let hot: Bool
    let accent: Color
    static func inbox(hot: Bool, accent: Color) -> DropZone {
        DropZone(title: "Inbox", symbol: "tray.and.arrow.down", note: "files are copied · links become notes\nin ψ/inbox/dropped", hot: hot, accent: accent)
    }
    static func issue(repo: String, hot: Bool, accent: Color) -> DropZone {
        DropZone(title: "New issue", symbol: "exclamationmark.bubble", note: "drafts an issue in \(repo)\nyou read it before it posts", hot: hot, accent: accent)
    }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(hot ? accent : Color.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(note).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hot ? accent.opacity(0.10) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(hot ? accent : Color.primary.opacity(0.45), style: StrokeStyle(lineWidth: hot ? 2 : 1.5, dash: [9, 6])))
        .contentShape(Rectangle())
    }
}

struct IssueDraft: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// What a dropped link or file would post as an issue — the human edits and sends it, never the app alone.
struct IssueDraftSheet: View {
    @ObservedObject var store: OracleStore
    @State var title: String
    @State var text: String
    let onDone: () -> Void
    @State private var sending = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New issue in \(store.config.repoSlug)").font(.headline)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $text).font(.callout.monospaced()).frame(minHeight: 180)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
            HStack {
                Text("Posts to GitHub. It shows up in Work → NEXT for /herdr-wt.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }.keyboardShortcut(.cancelAction).handCursor()
                Button(sending ? "Creating…" : "Create issue") {
                    sending = true
                    Task {
                        let url = await store.createIssue(title: title, body: text)
                        #if os(macOS)
                        if let url, let u = URL(string: url) { NSWorkspace.shared.open(u) }   // Nat: "when issue created, open the gh issue link"
                        #endif
                        onDone()
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).handCursor()
                .disabled(sending || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}

struct WorkLinks: View {
    let item: WorkItem; let repo: String
    var body: some View {
        HStack(spacing: 4) {
            if let n = item.issue, let u = URL(string: "https://github.com/\(repo)/issues/\(n)") {
                WorkChip(text: "#\(n)") { WorkFormat.open(u) }
            }
            if let pr = item.pr { WorkChip(text: "PR #\(pr.number)") { if let u = pr.url { WorkFormat.open(u) } } }
        }
    }
}

struct WorkChip: View {
    let text: String; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.caption.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
        }.buttonStyle(.plain).handCursor()
    }
}

struct WorkMenu: View {
    let item: WorkItem; let repo: String
    @Binding var copied: String?
    var body: some View {
        #if os(macOS)
        Button("Open folder") { WorkFormat.open(URL(fileURLWithPath: item.path)) }
        #endif
        if let cmd = item.resumeCommand { Button("Copy resume command") { WorkFormat.copy(cmd); copied = item.id } }
        else { Button("Copy cleanup command") { WorkFormat.copy(WorkFormat.cleanCommand([item.path])) } }
        Button("Copy path") { WorkFormat.copy(item.path) }
        if let n = item.issue, let u = URL(string: "https://github.com/\(repo)/issues/\(n)") {
            Button("Open issue #\(n)") { WorkFormat.open(u) }
        }
        if let pr = item.pr, let u = pr.url { Button("Open PR #\(pr.number)") { WorkFormat.open(u) } }
    }
}

enum WorkFormat {
    static func rank(_ s: String) -> Int { ["blocked": 0, "done": 1, "working": 2, "idle": 3][s] ?? 4 }
    static func dot(_ s: String, _ accent: Color) -> Color {
        switch s {
        case "blocked": return .red
        case "done": return .green
        case "working": return accent
        default: return Color.secondary.opacity(0.45)
        }
    }
    /// "laris-co:w22:pA" → "w22:pA" in the usual session; another session keeps its name
    static func pane(_ place: String, home: String) -> String {
        guard let i = place.firstIndex(of: ":") else { return place }
        return place[..<i] == home ? String(place[place.index(after: i)...]) : place
    }
    static func homeSession(_ acts: [OracleSnapshot.Activity]) -> String {
        let names = acts.compactMap { $0.place.split(separator: ":").first.map(String.init) }
        return Dictionary(grouping: names, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? ""
    }
    static func ago(_ d: Date) -> String {
        let s = max(0, Int(-d.timeIntervalSinceNow))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
    static func copy(_ s: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        #else
        UIPasteboard.general.string = s
        #endif
    }
    /// A web link, or on the Mac a folder. On the phone the links come from the Mac's answers, and a `tel:` or another
    /// app's scheme is not a PR.
    static func open(_ u: URL) {
        let web = ["http", "https"].contains(u.scheme?.lowercased() ?? "")
        #if os(macOS)
        guard web || u.isFileURL else { return }
        NSWorkspace.shared.open(u)
        #else
        guard web else { return }
        UIApplication.shared.open(u)
        #endif
    }
    static func showInHerdr(_ s: HerdrSpace, tabId: String?) {
        #if os(macOS)
        Task.detached {
            _ = await Shell.run("herdr", ["--session", s.session, "workspace", "focus", s.workspaceId])
            if let tabId { _ = await Shell.run("herdr", ["--session", s.session, "tab", "focus", tabId]) }
        }
        #endif
    }
    /// `maw herdr clean` plans removing worktrees whose commits are pushed (or merged); it changes nothing
    /// until run again with --go.
    static func cleanCommand(_ paths: [String]) -> String {
        "maw herdr clean " + paths.map { "'\($0)'" }.joined(separator: " ")
    }
    static func header(_ title: String, _ n: Int, note: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).tracking(1.4)
            Text("\(n)").font(.caption.monospacedDigit())
            if !note.isEmpty { Text(note).font(.caption) }
        }
        .foregroundStyle(.secondary)
    }
}

struct InboxList: View {
    @ObservedObject var store: OracleStore
    enum Show: String, CaseIterable { case all = "All", unread = "Unread", read = "Read" }
    @State private var show: Show = .all
    private var unreadCount: Int { store.unread.count }
    private var readCount: Int { store.inbox.count - store.unread.count }
    private var items: [InboxItem] {
        switch show {
        case .all: return store.inbox
        case .unread: return store.inbox.filter { store.isUnread($0) }
        case .read: return store.inbox.filter { !store.isUnread($0) }
        }
    }
    var body: some View {
        List(items) { i in
            let unread = store.isUnread(i)
            Button {
                store.markRead(i)
                #if os(macOS)
                NSWorkspace.shared.open(URL(fileURLWithPath: i.path))
                #endif
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(unread ? store.config.color : .clear)
                        .overlay(Circle().stroke(unread ? .clear : Color.secondary.opacity(0.35), lineWidth: 1))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(i.name)
                            .font(unread ? .body.weight(.semibold) : .body)
                            .foregroundStyle(unread ? .primary : .secondary)
                        Text("\(unread ? "unread" : "read") · \(i.folder) · \(i.modified.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(unread ? AnyShapeStyle(store.config.color) : AnyShapeStyle(.tertiary))
                    }
                }
            }
            .buttonStyle(.plain).handCursor()
            .contextMenu {
                if unread { Button("Mark as read") { store.markRead(i) } }
                else { Button("Mark as unread") { store.markUnread(i) } }
            }
        }
        .overlay {
            if items.isEmpty {
                Text(show == .unread ? "Nothing unread." : show == .read ? "Nothing read yet."
                     : "Inbox is empty. Drop files or links on the app icon or this window.")
                    .foregroundStyle(.secondary)
            }
        }
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $show) {
                    Text("All \(store.inbox.count)").tag(Show.all)
                    Text("Unread \(unreadCount)").tag(Show.unread)
                    Text("Read \(readCount)").tag(Show.read)
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem { Button("Mark all read") { store.markAllRead() }.disabled(unreadCount == 0) }
        }
        .navigationTitle(unreadCount == 0 ? "Inbox" : "Inbox · \(unreadCount) unread")
    }
}

/// Pull requests and issues, after ARRA Chat's "Pick up a thread.": one big line, a segmented filter, one card
/// per item — a status dot, the title, who and when, and which /herdr-wt worktree it belongs to.
struct GHList: View {
    enum Kind { case prs, issues }
    let kind: Kind
    let items: [GHItem]
    let work: [WorkItem]
    let accent: Color
    /// The phone's: why the last read failed, and when one last worked (nil: nothing has answered since launch). An empty
    /// list says "no open …" only once something answered — before that it is "not read", not "none".
    var problems: [String] = []
    var answered: Date? = .distantPast
    var onSend: ((GHItem) -> Void)? = nil
    @State private var filter = 0
    var body: some View {
        let groups = self.groups
        let rows = groups[min(filter, groups.count - 1)].items
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(kind == .prs ? "Pick up a pull request." : "Pick up an issue.")
                    .font(.custom("Avenir Next", size: 30).weight(.bold)).tracking(-0.5)
                #if os(iOS)
                // a phone's width: the native control while the labels fit, else a row of pills that scrolls
                PhoneSegments(options: groups.indices.map { (tag: $0, label: "\(groups[$0].name) · \(groups[$0].items.count)") },
                              selection: $filter, accent: accent)
                if !problems.isEmpty { PhoneReadFailure(problem: problems.joined(separator: "\n"), since: answered) }
                #else
                Picker("Show", selection: $filter) {
                    ForEach(groups.indices, id: \.self) { i in Text("\(groups[i].name) · \(groups[i].items.count)").tag(i) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                #endif
                VStack(spacing: 8) {
                    ForEach(rows) { it in GHCard(item: it, status: status(it), detail: detail(it), onSend: onSend.map { f in { f(it) } }) }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if rows.isEmpty {
                if answered == nil { if problems.isEmpty { ProgressView() } }
                else { Text(kind == .prs ? "No open pull requests here" : "No open issues here").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle(kind == .prs ? "Pull requests" : "Issues")
    }

    private var groups: [(name: String, items: [GHItem])] {
        switch kind {
        case .prs:
            return [("All", items), ("Ready", items.filter { !$0.isDraft }), ("Draft", items.filter(\.isDraft))]
        case .issues:
            let taken = Set(work.compactMap(\.issue))
            return [("All", items), ("No worktree", items.filter { !taken.contains($0.number) }),
                    ("In a worktree", items.filter { taken.contains($0.number) })]
        }
    }
    private func tree(_ it: GHItem) -> WorkItem? {
        switch kind {
        case .prs: return work.first { w in it.branch.map { $0 == w.branch } == true || (w.issue.map { it.closes.contains($0) } ?? false) }
        case .issues: return work.first { $0.issue == it.number }
        }
    }
    private func status(_ it: GHItem) -> (label: String, color: Color) {
        switch kind {
        case .prs: return it.isDraft ? ("draft", Color.secondary.opacity(0.6)) : ("open", .green)
        case .issues: return tree(it) != nil ? ("in a worktree", .green) : ("no worktree yet", accent)
        }
    }
    private func detail(_ it: GHItem) -> String {
        var parts = [it.author]
        if let d = it.updatedAt { parts.append(d.formatted(.relative(presentation: .named))) }
        if let w = tree(it) { parts.append("worktree " + (w.isMain ? w.folder : w.slug)) }
        else if kind == .prs, let b = it.branch { parts.append(b) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct GHCard: View {
    let item: GHItem
    let status: (label: String, color: Color)
    let detail: String
    var onSend: (() -> Void)? = nil
    @State private var hover = false
    var body: some View {
        Button { if let u = item.url { WorkFormat.open(u) } } label: {
            HStack(spacing: 12) {
                Circle().fill(status.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("#\(item.number)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        Text(item.title).font(.custom("Avenir Next", size: 15).weight(.semibold)).lineLimit(1)
                    }
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Text(status.label).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hover ? 0.08 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).handCursor()
        .onHover { hover = $0 }
        .help(item.url?.absoluteString ?? "")
        .contextMenu {
            if let onSend { Button("Send to agent…", action: onSend).handCursor() }
            if let u = item.url { Button("Open on GitHub") { WorkFormat.open(u) } }
        }
    }
}

public extension Notification.Name {
    static let oracleFilesDropped = Notification.Name("oracleFilesDropped")
    static let oracleOpenSection = Notification.Name("oracleOpenSection")
    static let oracleServiceIssue = Notification.Name("oracleServiceIssue")
    static let oracleServiceMessage = Notification.Name("oracleServiceMessage")
}

#if os(macOS)
/// Receives files dropped on the Dock icon (needs CFBundleDocumentTypes in the app's Info.plist).
public final class OracleAppDelegate: NSObject, NSApplicationDelegate {
    private var pending: [URL] = []
    private var ready = false
    public func application(_ application: NSApplication, open urls: [URL]) {
        // A widget tap arrives here as oracle-<name>://open — that is "show me the app", never a drop.
        let own = urls.filter { ($0.scheme ?? "").hasPrefix("oracle-") }
        let drops = urls.filter { !($0.scheme ?? "").hasPrefix("oracle-") }
        for u in own {
            // oracle-<name>://issue|inbox|message?url=&title=&text= — the Chrome "Send to oracle" menu (browser/chrome)
            switch u.host {
            case "issue", "inbox", "message": deliverLink(u)
            case "front":   // the hub's app card: this window on that display (oracle-<name>://front?display=<id>)
                let id = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "display" }?.value.flatMap(UInt32.init)
                Self.bringFront(display: id)
            default:
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .oracleOpenSection, object: u.host ?? "open")
            }
        }
        guard !drops.isEmpty else { return }
        if ready { deliver(drops) } else { pending += drops }
    }
    /// This app's window on the given display (the hub sends the main display's id), centred in its visible frame
    /// and no bigger than it, then in front. Already there: just in front. An app moves its own window, so this
    /// needs no Accessibility; macOS puts it in that display's current Space, where Nat is looking.
    @MainActor static func bringFront(display id: UInt32?) {
        NSApp.activate(ignoringOtherApps: true)
        guard let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) ?? NSApp.windows.first(where: { $0.canBecomeMain })
        else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        let number = { (s: NSScreen) in (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        if let target = NSScreen.screens.first(where: { number($0) == id }) ?? NSScreen.screens.first,
           w.screen.flatMap(number) != number(target) {
            w.setFrame(Self.centred(w.frame.size, in: target.visibleFrame), display: true)
        }
        w.makeKeyAndOrderFront(nil)
    }

    /// A window of this size, centred in a visible frame and shrunk to fit it.
    static func centred(_ size: NSSize, in v: NSRect) -> NSRect {
        let w = min(size.width, v.width), h = min(size.height, v.height)
        return NSRect(x: (v.midX - w / 2).rounded(), y: (v.midY - h / 2).rounded(), width: w, height: h)
    }

    /// Copy ONCE here, then tell every window to refresh (each window copying would duplicate files).
    private func deliver(_ urls: [URL]) {
        let n = OracleStore.copyIntoInbox(urls, config: OracleConfig.current)
        NotificationCenter.default.post(name: .oracleFilesDropped, object: n)
    }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        ready = true
        NSApp.servicesProvider = self          // right-click → Services → New <Name> Oracle issue / Send to … inbox
        NSUpdateDynamicServices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            if !pending.isEmpty { deliver(pending); pending = [] }
        }
    }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Services menu — NSServices in each app's Info.plist (app.yml) names these two messages.

    /// "New <Name> Oracle issue": the selection (text, links or files) becomes an issue draft in the app;
    /// Nat edits it and presses Create — nothing posts by itself.
    @MainActor @objc public func newIssue(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let (urls, text) = Self.read(pboard)
        ServiceInbox.pendingIssue = Self.issueDraft(urls: urls, text: text, oracle: OracleConfig.current.name)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .oracleServiceIssue, object: nil)
    }

    /// "Send to <Name> Oracle inbox": files are copied, links become notes, selected text becomes a note —
    /// the same landing as a Dock drop.
    @MainActor @objc public func sendToInbox(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        var (urls, text) = Self.read(pboard)
        if urls.isEmpty, let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            let note = FileManager.default.temporaryDirectory.appendingPathComponent("selection.md")
            if (try? t.write(to: note, atomically: true, encoding: .utf8)) != nil { urls = [note] }
            text = nil
        }
        if !urls.isEmpty { deliver(urls) }
    }

    /// "Message <Name> Oracle": the selection goes into the app's message box (maw herdr hey); Nat checks the
    /// target pane and sends with ⌘↩ — nothing is sent by the right-click itself.
    @MainActor @objc public func messageOracle(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let (urls, text) = Self.read(pboard)
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let links = urls.map { $0.isFileURL ? $0.path : $0.absoluteString }.filter { $0 != t }
        ServiceInbox.pendingMessage = ([t] + links).filter { !$0.isEmpty }.joined(separator: "\n")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .oracleServiceMessage, object: nil)
    }

    /// The browser's version of the three Services: same draft sheet, inbox landing and message box.
    @MainActor private func deliverLink(_ u: URL) {
        // older extension builds wrote spaces as "+" (URLSearchParams); a real plus always arrives as %2B
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        func item(_ k: String) -> String {
            let raw = (q.first { $0.name == k }?.value ?? "").replacingOccurrences(of: "+", with: "%20")
            return (raw.removingPercentEncoding ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let link = URL(string: item("url")).flatMap { $0.scheme == nil ? nil : $0 }
        let title = item("title"), text = item("text")
        switch u.host {
        case "inbox":
            var urls = link.map { [$0] } ?? []
            if !text.isEmpty {
                let note = FileManager.default.temporaryDirectory.appendingPathComponent("selection.md")
                if (try? text.write(to: note, atomically: true, encoding: .utf8)) != nil { urls.append(note) }
            }
            if !urls.isEmpty { deliver(urls) }
            return
        case "message":
            ServiceInbox.pendingMessage = [text, link?.absoluteString ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            NotificationCenter.default.post(name: .oracleServiceMessage, object: nil)
        default:
            var d = Self.issueDraft(urls: link.map { [$0] } ?? [], text: text, oracle: OracleConfig.current.name)
            // a whole Facebook thread is too big for a URL: the extension left it at ~/.oracle-fb/threads/<id>.md
            // (browser/bridge/server.ts) and sent only the id. Ids are [a-z0-9] — never a path.
            let tid = item("thread")
            if !tid.isEmpty, tid.allSatisfy({ $0.isLetter || $0.isNumber }),
               let md = try? String(contentsOfFile: NSHomeDirectory() + "/.oracle-fb/threads/\(tid).md", encoding: .utf8) {
                d = IssueDraft(title: d.title, text: d.text + "\n\n---\n\n" + md)
            }
            if !title.isEmpty { d = IssueDraft(title: String(title.prefix(100)), text: d.text) }
            ServiceInbox.pendingIssue = d
            NotificationCenter.default.post(name: .oracleServiceIssue, object: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    static func read(_ pb: NSPasteboard) -> (urls: [URL], text: String?) {
        ((pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? [], pb.string(forType: .string))
    }

    static func issueDraft(urls: [URL], text: String?, oracle: String) -> IssueDraft {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !urls.isEmpty {
            let d = OracleStore.issueDraft(urls, oracle: oracle)
            return IssueDraft(title: d.title, text: (t.isEmpty || urls.contains { $0.absoluteString == t } ? "" : t + "\n\n") + d.body)
        }
        let first = t.split(separator: "\n").first.map(String.init) ?? ""
        return IssueDraft(title: String(first.prefix(100)), text: t + "\n\n_Sent to the \(oracle) app from the right-click menu._")
    }
}

/// A right-click issue that arrives before (or while) the window shows: the root view picks it up.
@MainActor enum ServiceInbox { static var pendingIssue: IssueDraft?; static var pendingMessage: String? }
#endif

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

#if os(macOS)
/// Message the oracle's agents from the app — `maw herdr hey --session <s> <pane> <message>`, which runs
/// `herdr --session <s> agent prompt <pane> <message>`. ARRA Chat's composer: one field, a target picker, send.
struct HeyComposer: View {
    @ObservedObject var store: OracleStore
    @Binding var text: String
    var focus: String? = nil       // the pane open in the 3rd column, if any: messages go there
    @State private var target: String?
    @State private var note: String?
    @State private var sending = false
    var body: some View {
        let c = store.config
        let twins = WorkParse.twins(store.activity)
        let panes = store.activity.filter { twins[$0.place] == nil }
            .sorted { (WorkFormat.rank($0.status), $0.place) < (WorkFormat.rank($1.status), $1.place) }
        let chosen = panes.first { $0.place == focus } ?? panes.first { $0.place == target } ?? panes.first { $0.cwd == c.localPath && $0.status == "idle" } ?? panes.first
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message \(c.name) — maw herdr hey", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(.custom("Avenir Next", size: 15)).lineLimit(1...6)
                    .onSubmit { send(to: chosen) }
                Button { send(to: chosen) } label: {
                    Image(systemName: sending ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 24)).foregroundStyle(canSend(chosen) ? c.color : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain).handCursor().disabled(!canSend(chosen))
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (⌘↩)")
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
            HStack(spacing: 10) {
                Menu {
                    ForEach(panes, id: \.place) { p in
                        Button { target = p.place } label: {
                            Text("\(WorkFormat.pane(p.place, home: WorkFormat.homeSession(store.activity))) · \(p.status) · \(String(p.title.prefix(40)))")
                        }
                    }
                } label: {
                    Text(chosen.map { "to \(WorkFormat.pane($0.place, home: WorkFormat.homeSession(store.activity))) · \($0.status)" } ?? "no agent pane open")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton).fixedSize().disabled(panes.isEmpty)
                if let note { Text(note).font(.caption).foregroundStyle(note.hasPrefix("sent") ? Color.secondary : Color.orange).textSelection(.enabled).lineLimit(2) }
                Spacer()
                Text("⌘↩ to send").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
        }
        .padding(.horizontal, 24).padding(.top, 10).padding(.bottom, 14)
        .background(.bar)
    }

    private func canSend(_ p: OracleSnapshot.Activity?) -> Bool {
        p != nil && !sending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func send(to p: OracleSnapshot.Activity?) {
        guard let p, canSend(p) else { return }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true; note = nil
        Task {
            let ok = await store.hey(place: p.place, message: message)
            sending = false
            if ok { text = ""; note = "sent to \(p.place)" }
            else { note = "not sent — run: " + OracleStore.heyCommand(place: p.place, message: message) }
        }
    }
}
#endif


#if os(macOS)
/// The real terminal of one herdr pane, read live (`herdr --session S pane read P`, every second), newest at the bottom.
/// Read-only: typing goes through the message box under the Work column, which targets this pane while it is open.
struct TerminalColumn: View {
    /// The widest row in terminal cells (a CJK or emoji glyph takes two), so the font can be sized to fit it.
    static func columns(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { row in
            row.unicodeScalars.reduce(0) { n, u in n + ((0x1100...0x115F).contains(u.value) || (0x2E80...0xA4CF).contains(u.value) || (0xAC00...0xD7A3).contains(u.value)
                || (0xF900...0xFAFF).contains(u.value) || (0xFE30...0xFE4F).contains(u.value) || (0xFF00...0xFF60).contains(u.value) || (0x1F300...0x1FAFF).contains(u.value) ? 2
                : (u.properties.generalCategory == .nonspacingMark ? 0 : 1)) }
        }.max() ?? 0
    }
    @ObservedObject var store: OracleStore
    let place: String
    var active = true
    var activate: () -> Void = {}
    let close: () -> Void
    var body: some View {
        let act = store.activity.first { $0.place == place }
        let shell = store.spaces.flatMap(\.panes).first { $0.place == place }   // a plain shell pane: no agent record
        let home = WorkFormat.homeSession(store.activity)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(WorkFormat.dot(act?.status ?? shell?.status ?? "", store.config.color)).frame(width: 8, height: 8)
                Text(WorkFormat.pane(place, home: home)).font(.callout.monospaced().weight(.semibold))
                    .foregroundStyle(active ? store.config.color : Color.primary)
                Text(act?.title ?? shell.map { ($0.agent ?? "shell") + " · " + (($0.cwd as NSString).lastPathComponent) } ?? "")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 6)
                if let item = store.work.first(where: { $0.panes.contains { $0.place == place } }) {
                    Button("bring here") { store.bringToMain(item); close() }.buttonStyle(.borderless).font(.caption.weight(.medium)).handCursor()
                        .help("Bring this pane's WezTerm window to the main display")
                }
                Button(action: close) { Image(systemName: "xmark").font(.callout.weight(.semibold)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).handCursor().help(active ? "Close (esc)" : "Close")
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(active ? store.config.color.opacity(0.12) : Color.clear)
            .contentShape(Rectangle()).onTapGesture(perform: activate)   // click a header: that pane becomes the active one
            Divider()
            PaneScreen(place: place)
        }
    }
}

/// One herdr pane drawn as its screen, read live every second: the oracle apps' drawer and the hub's space drawer.
/// `place` = "<session>:<pane>" or a pane id in the default session.
struct PaneScreen: View {
    let place: String
    @State private var text = ""
    @State private var read: Date?
    @State private var failed = false
    /// The largest drawer font: an agent writes its rows at its pane's width (~110 columns here), so a wide drawer
    /// is filled by a bigger font rather than by longer rows, which the pane never has.
    static let maxFont: CGFloat = 20
    @AppStorage("oracle.drawerFit") private var fit = true   // ☑ fit the drawer · ☐ bigger font, scroll (Nat's choice)
    var body: some View {
        VStack(spacing: 0) {
            let shown = failed && text.isEmpty ? "can't read \(place) — is herdr running?\n  herdr pane list" : text
            Group { if fit {
            GeometryReader { geo in
                // a terminal screen, not a scroll view (Nat: "make the right fit, no scroll"): the font shrinks until the
                // widest row fits the drawer (a monospaced cell is ~0.6 of the font size), and only the newest rows that
                // fit the height are shown — widen or heighten the drawer to see more
                let all = shown.split(separator: "\n", omittingEmptySubsequences: false)
                let recent = all.suffix(160).joined(separator: "\n")
                let size = min(Self.maxFont, max(7, (geo.size.width - 26) / (CGFloat(max(TerminalColumn.columns(recent), 40)) * 0.602)))
                let rows = max(4, Int((geo.size.height - 24) / (size * 1.22)))
                Text(all.suffix(rows).joined(separator: "\n"))
                    .font(.system(size: size, design: .monospaced)).foregroundStyle(Color(white: 0.86))
                    .fixedSize(horizontal: true, vertical: false)   // never re-wrap: tables and boxes keep their shape
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(12)
                    .clipped()
            }
            } else {
                // bigger font, scroll both ways; opens at the newest row and the leftmost column. At least 13 pt, and
                // larger when the pane's rows are narrower than the drawer, so a wide drawer is filled, not half empty
                GeometryReader { geo in
                let size = max(13, min(Self.maxFont, (geo.size.width - 26) / (CGFloat(max(TerminalColumn.columns(shown), 40)) * 0.602)))
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(shown).font(.system(size: size, design: .monospaced)).foregroundStyle(Color(white: 0.86))
                                .fixedSize(horizontal: true, vertical: false).textSelection(.enabled).padding(12)
                            Color.clear.frame(width: 1, height: 1).id("end")
                        }
                    }
                    .onChange(of: text) { proxy.scrollTo("end", anchor: .bottomLeading) }
                    .onAppear { proxy.scrollTo("end", anchor: .bottomLeading) }
                }
                }
            } }
            .background(Color(red: 0.04, green: 0.04, blue: 0.06))
            HStack {
                Text(read.map { "live · every 1 s · read \($0.formatted(date: .omitted, time: .standard))" } ?? "reading…")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Toggle("Fit", isOn: $fit).toggleStyle(.checkbox).font(.caption).handCursor()
                    .help("Ticked: shrink the text to fit the drawer, no scrolling. Unticked: bigger font, scroll.")
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
        }
        .task(id: place) {
            text = ""; failed = false
            let parts = place.split(separator: ":", maxSplits: 1).map(String.init)
            let args = parts.count == 2 ? ["--session", parts[0], "pane", "read", parts[1], "--source", "recent", "--lines", "400"]   // the rows as the terminal draws them
                                        : ["pane", "read", place, "--source", "recent", "--lines", "400"]   // the rows as the terminal draws them
            while !Task.isCancelled {
                if let out = await Shell.run("herdr", args, timeout: 4) {
                    let clean = out.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                    if clean != text { text = clean }
                    read = Date(); failed = false
                } else { failed = true }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
#endif

#if os(macOS)
/// Grows or shrinks the app window to the right (or left, at the screen edge) so a drawer adds room instead of
/// taking it from the Work column.
@MainActor enum Drawer {
    /// `leftward`: the window's right edge stays put and it grows to the left — what a drag on the drawer's left edge wants
    static func grow(by dx: CGFloat, leftward: Bool = false, animate: Bool = true) {
        guard let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        var f = w.frame
        f.size.width += dx
        if leftward { f.origin.x -= dx }
        if let vis = w.screen?.visibleFrame {
            if f.width > vis.width { f.size.width = vis.width }
            if f.maxX > vis.maxX { f.origin.x = max(vis.minX, vis.maxX - f.width) }   // no room on the right: open toward the left
            if f.minX < vis.minX { f.origin.x = vis.minX }
        }
        w.setFrame(f, display: true, animate: animate)
    }
}

/// The drawer's left edge: drag it to trade width with the Work column (Nat: "middle more narrow, the right edge stays,
/// so the drawer gets wider"). The window does not move; Work keeps at least 420 px.
struct DrawerHandle: View {
    static let width: CGFloat = 7
    @Binding var width: Double
    /// how wide the drawer may get: the window's content minus the sidebar (~260) and Work's 420 minimum
    private var maxWidth: CGFloat {
        let win = (NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeMain })?.contentView?.bounds.width ?? 1400
        return max(360, win - 260 - 420 - Self.width)
    }
    @State private var start: Double?
    @State private var inside = false
    var body: some View {
        ZStack {
            Color.primary.opacity(inside || start != nil ? 0.12 : 0.04)
            Capsule().fill(Color.primary.opacity(0.35)).frame(width: 2, height: 34)
        }
        .frame(width: Self.width)
        .contentShape(Rectangle())
        .onHover { h in
            guard h != inside else { return }
            inside = h
            if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .onDisappear { if inside { inside = false; NSCursor.pop() } }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { g in
                let base = start ?? width; if start == nil { start = width }
                let next = min(Double(maxWidth), max(360, base - g.translation.width))
                if abs(next - width) >= 1 { width = next }
            }
            .onEnded { _ in start = nil })
        .help("Drag to make the terminal wider or narrower")
    }
}
#endif

/// Under "Work" in the sidebar: this oracle's LIVE worktrees as herdr draws them — name, branch dimmed underneath,
/// worktrees hanging off the main checkout with ├─ / └─, a state dot. A row with a pane opens its terminal drawer;
/// one without brings its WezTerm window here. RESUMABLE and COLD stay on the Work page (Nat: no long extra sections).
/// Every pane of a worktree, agents first, then the plain shells of its herdr space (agent-less panes are not in
/// `activity`, so a worktree with only a shell had nothing to open).
@MainActor func panesOf(_ w: WorkItem, store: OracleStore) -> [String] {
    let agents = w.panes.sorted { WorkFormat.rank($0.status) < WorkFormat.rank($1.status) }.map(\.place)
    let shells = store.spaces.filter { $0.checkout == w.path || $0.panes.contains { $0.cwd == w.path || $0.cwd.hasPrefix(w.path + "/") } }
        .flatMap(\.panes).map(\.place).filter { !agents.contains($0) }
    return agents + shells
}

struct WorkTree: View {
    @ObservedObject var store: OracleStore
    let openPane: Binding<String?>
    var body: some View {
        let live = store.work.filter { $0.state <= .open }
        let main = live.first { $0.isMain }
        let rest = live.filter { !$0.isMain }
        let home = WorkFormat.homeSession(store.activity)
        VStack(alignment: .leading, spacing: 1) {
            if let m = main { row(m, prefix: "", home: home) }
            ForEach(Array(rest.enumerated()), id: \.element.id) { i, w in
                row(w, prefix: main == nil ? "" : (i == rest.count - 1 ? "└─ " : "├─ "), cont: main == nil ? "" : (i == rest.count - 1 ? "   " : "│  "), home: home)
            }
        }
        .padding(.leading, 30).padding(.trailing, 8).padding(.bottom, 4)
    }
    @ViewBuilder private func row(_ w: WorkItem, prefix: String, cont: String = "", home: String) -> some View {
        let pane = panesOf(w, store: store).first
        let open = pane != nil && openPane.wrappedValue == pane
        let dot: (String, Color) = switch w.state {
            case .needsYou: ("◐", .orange); case .working: ("●", .green); default: ("○", .secondary) }
        HStack(alignment: .top, spacing: 0) {
            Text(prefix).font(.caption.monospaced()).foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(dot.0).font(.caption).foregroundStyle(dot.1)
                    Text(w.slug).font(.callout.weight(open ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                    if let n = w.issue { Text("#\(n)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }
                Text(pane.map { "\(w.branch) · \(WorkFormat.pane($0, home: home))" } ?? w.branch)
                    .font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                    .padding(.leading, cont.isEmpty ? 0 : 0)
            }
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(open ? store.config.color.opacity(0.16) : Color.clear))
        .contentShape(Rectangle())
        .handCursor()
        .onTapGesture {
            if let p = pane { openPane.wrappedValue = open ? nil : p } else { bring(w) }
        }
        .help(pane == nil ? "Bring its WezTerm window here" : "Show its terminal in the drawer")
    }
    private func bring(_ w: WorkItem) {
        #if os(macOS)
        store.bringToMain(w)
        #endif
    }
}

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
