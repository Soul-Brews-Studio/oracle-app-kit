import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Section: Hashable { case status, inbox, prs, issues, extra(String) }

public struct OracleRootView: View {
    @StateObject private var store: OracleStore
    @State private var section: Section? = .status
    @State private var dropTargeted = false
    @State private var inboxHot = false
    @State private var issueHot = false
    @State private var draft: IssueDraft?
    #if os(iOS)
    @State private var showSettings = false
    #endif

    public init(config: OracleConfig) { _store = StateObject(wrappedValue: OracleStore(config: config)) }

    private var c: OracleConfig { store.config }

    public var body: some View {
        NavigationSplitView {
            OracleSidebar(store: store, section: $section)
                .navigationSplitViewColumnWidth(min: 240, ideal: 272)
        } detail: {
            detail
                .toolbar {
                    #if os(iOS)
                    ToolbarItem { Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") } }
                    ToolbarItem { Button { showSettings = true } label: { Image(systemName: "gear") } }
                    #endif
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
        .onReceive(NotificationCenter.default.publisher(for: .oracleFilesDropped)) { n in
            if let count = n.object as? Int { store.noteDrop(count); section = .inbox }
        }
        #else
        .sheet(isPresented: $showSettings) { TokenSettings(onSave: { Task { await store.refresh() } }) }
        #endif
        .onAppear { store.start() }
    }

    @ViewBuilder private var detail: some View {
        switch section ?? .status {
        case .status: WorkView(store: store)
        case .inbox: InboxList(store: store)
        case .prs: GHList(title: "Open pull requests", items: store.prs, empty: "No open pull requests")
        case .issues: GHList(title: "Open issues", items: store.issues, empty: "No open issues")
        case .extra(let id): c.extras.sections.first { $0.id == id }.map { $0.view() } ?? AnyView(EmptyView())
        }
    }

}

// MARK: - Sidebar, after ARRA Chat: brand row · pill nav · "where this runs" footer

struct OracleSidebar: View {
    @ObservedObject var store: OracleStore
    @Binding var section: Section?
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
                Text("\(c.name) Oracle").font(.custom("Avenir Next", size: 20).weight(.semibold)).tracking(-0.4).lineLimit(1)
                Spacer(minLength: 4)
                SidebarIconButton(symbol: "arrow.clockwise", help: "Refresh") { Task { await store.refresh() } }
            }
            .padding(.horizontal, 18).frame(height: 70)
            VStack(spacing: 3) {
                NavRow(symbol: "square.stack.3d.up", title: "Work", badge: store.work.isEmpty ? nil : "\(store.work.count)",
                       on: (section ?? .status) == .status, accent: c.color) { section = .status }
                #if os(macOS)
                NavRow(symbol: store.unread.isEmpty ? "tray" : "tray.full", title: "Inbox",
                       badge: store.unread.isEmpty ? (store.inbox.isEmpty ? nil : store.inbox.count >= 300 ? "300+" : "\(store.inbox.count)")
                                                   : "\(store.unread.count) new",
                       on: section == .inbox, accent: c.color) { section = .inbox }
                #endif
                NavRow(symbol: "arrow.triangle.pull", title: "Pull requests", badge: store.prs.isEmpty ? nil : "\(store.prs.count)",
                       on: section == .prs, accent: c.color) { section = .prs }
                NavRow(symbol: "exclamationmark.circle", title: "Issues", badge: store.issues.isEmpty ? nil : "\(store.issues.count)",
                       on: section == .issues, accent: c.color) { section = .issues }
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
            HStack(spacing: 8) {
                Circle().fill(store.problems.isEmpty ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(store.problems.isEmpty ? "Live on this Mac" : "Needs a look")
                    .font(.custom("Avenir Next", size: 13).weight(.semibold))
            }
            Text(c.repoSlug).font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary.opacity(0.85))
            if let t = store.lastRefresh {
                Text("herdr · maw · gh — updated \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let d = store.lastDrop {
                Label(d, systemImage: "tray.and.arrow.down").font(.system(size: 11)).foregroundStyle(c.color)
            }
            ForEach(store.problems, id: \.self) { p in
                Text(p).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
            }
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
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 18)
                Text(title).font(.custom("Avenir Next", size: 15).weight(on ? .semibold : .medium)).lineLimit(1)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(on ? accent : Color.secondary)
                }
            }
            .foregroundStyle(on ? accent : Color.primary.opacity(0.8))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(on ? accent.opacity(0.16) : (hover ? Color.primary.opacity(0.06) : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        .buttonStyle(.plain).help(help)
        .onHover { hover = $0 }
    }
}

// MARK: - Work: one row per /herdr-wt worktree
// Layout card: neo-oracle ψ/writing/diagrams/2026-10-07_oracle-app-work-view.txt

struct WorkView: View {
    @ObservedObject var store: OracleStore
    @State private var allResumable = false
    @State private var showCold = false
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
                        ForEach(live) { LiveCard(item: $0, config: c, twins: twins, home: home, copied: $copied) }
                    }
                }
                if !resumable.isEmpty {
                    block("RESUMABLE", resumable.count) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(allResumable ? resumable : Array(resumable.prefix(6))) { TreeRow(item: $0, config: c, copied: $copied) }
                        }
                        if resumable.count > 6 {
                            Button(allResumable ? "show less" : "\(resumable.count - 6) more") { allResumable.toggle() }
                                .buttonStyle(.link).padding(.leading, 4)
                        }
                    }
                }
                if !cold.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Button { withAnimation(.snappy) { showCold.toggle() } } label: {
                            HStack(spacing: 6) {
                                WorkFormat.header("COLD", cold.count, note: "no session to resume")
                                Image(systemName: showCold ? "chevron.down" : "chevron.right")
                                    .font(.caption2.bold()).foregroundStyle(.secondary)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.slug).font(.headline).lineLimit(1)
                Text(item.branch).font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                WorkLinks(item: item, repo: config.repoSlug)
                Text(item.state.label).font(.caption).foregroundStyle(.secondary)
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
                }
                .font(.callout)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .contextMenu { WorkMenu(item: item, repo: config.repoSlug, copied: $copied) }
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
                Button(copied == item.id ? "copied" : "resume") { WorkFormat.copy(cmd); copied = item.id }
                    .buttonStyle(.borderless).help(cmd)
                    .frame(width: 64, alignment: .trailing)
            } else {
                Color.clear.frame(width: 64, height: 1)
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
                Button("Cancel", role: .cancel) { onDone() }.keyboardShortcut(.cancelAction)
                Button(sending ? "Creating…" : "Create issue") {
                    sending = true
                    Task { _ = await store.createIssue(title: title, body: text); onDone() }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
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
        }.buttonStyle(.plain)
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
    static func open(_ u: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(u)
        #else
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
            .buttonStyle(.plain)
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

struct GHList: View {
    let title: String; let items: [GHItem]; let empty: String
    @Environment(\.openURL) private var openURL
    var body: some View {
        List(items) { it in
            Button { if let u = it.url { openURL(u) } } label: {
                VStack(alignment: .leading) {
                    Text("#\(it.number) \(it.title)").font(.body)
                    Text("\(it.author)\(it.isDraft ? " · draft" : "")\(it.updatedAt.map { " · " + $0.formatted(.relative(presentation: .named)) } ?? "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
        }
        .overlay { if items.isEmpty { Text(empty).foregroundStyle(.secondary) } }
        .navigationTitle(title)
    }
}

#if os(iOS)
struct TokenSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var token = TokenStore.read() ?? ""
    let onSave: () -> Void
    var body: some View {
        NavigationStack {
            Form {
                Section("GitHub token (read-only is enough)") { SecureField("ghp_… or github_pat_…", text: $token) }
                Section { Text("Kept in this iPad's Keychain. Used only to read PRs and issues.").font(.footnote) }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Save") { TokenStore.write(token); onSave(); dismiss() } }
        }
    }
}
#endif

public extension Notification.Name {
    static let oracleFilesDropped = Notification.Name("oracleFilesDropped")
    static let oracleOpenSection = Notification.Name("oracleOpenSection")
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
        if !own.isEmpty {
            NSApp.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(name: .oracleOpenSection, object: own.first?.host ?? "open")
        }
        guard !drops.isEmpty else { return }
        if ready { deliver(drops) } else { pending += drops }
    }
    /// Copy ONCE here, then tell every window to refresh (each window copying would duplicate files).
    private func deliver(_ urls: [URL]) {
        let n = OracleStore.copyIntoInbox(urls, config: OracleConfig.current)
        NotificationCenter.default.post(name: .oracleFilesDropped, object: n)
    }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        ready = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            if !pending.isEmpty { deliver(pending); pending = [] }
        }
    }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
#endif

/// The whole app in one scene; a thin app's @main body is just `OracleScene(config:)`.
public struct OracleScene: Scene {
    let config: OracleConfig
    public init(config: OracleConfig) { self.config = config; OracleConfig.current = config }
    public var body: some Scene {
        #if os(macOS)
        // One window per oracle app: a Dock drop or a restored state must never open a second one.
        Window(config.name, id: "main") { OracleRootView(config: config) }
            .defaultSize(width: 980, height: 640)
        #else
        WindowGroup(config.name) { OracleRootView(config: config) }
        #endif
    }
}
