import SwiftUI
#if os(macOS)
import AppKit
#endif

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

/// Under "Work" in the sidebar: this oracle's LIVE worktrees as herdr draws them — name, branch dimmed underneath,
/// worktrees hanging off the main checkout with ├─ / └─, a state dot. A row with a pane opens its terminal drawer;
/// one without brings its WezTerm window here. RESUMABLE and COLD stay on the Work page (Nat: no long extra sections).
/// Every pane of a worktree, agents first, then the plain shells of its herdr space (agent-less panes are not in
/// `activity`, so a worktree with only a shell had nothing to open).
@MainActor func panesOf(_ w: WorkItem, store: OracleStore) -> [String] {
    let agents = w.panes.sorted { WorkFormat.rank($0.status) < WorkFormat.rank($1.status) }.map(\.place)
    let shells = WorkParse.shells(of: w, work: store.work, spaces: store.spaces).map(\.place)   // the deepest owner (#88)
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
                    // branch on top, like herdr's sidebar: a /herdr-rename (git branch -m) shows here at once, the folder never moves
                    Text(w.branch.isEmpty ? w.folder : w.branch).font(.callout.weight(open ? .semibold : .regular)).lineLimit(1).truncationMode(.tail)
                    if let n = w.issue { Text("#\(n)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                    Spacer(minLength: 0)
                }
                Text(pane.map { "\(w.folder) · \(WorkFormat.pane($0, home: home))" } ?? w.folder)
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
