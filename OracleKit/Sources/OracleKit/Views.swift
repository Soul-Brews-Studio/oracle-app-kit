import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum Section: Hashable { case space(String), tree(String), inbox, prs, issues, extra(String) }

public struct OracleRootView: View {
    @StateObject private var store: OracleStore
    @State private var section: Section?
    @State private var showCold = false
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
            List(selection: $section) {
                IdentityCard(config: c, acts: store.activity)
                    .listRowSeparator(.hidden)
                let home = WorkFormat.homeSession(store.activity)
                let spaces = orderedSpaces(home: home)
                let closed = closedTrees(spaces)
                if !spaces.isEmpty {
                    SwiftUI.Section("Spaces") {
                        ForEach(rootSpaces(spaces)) { s in
                            SpaceRowLabel(space: s, item: workItem(for: s), child: false, home: home, accent: c.color)
                                .tag(Section.space(s.place))
                            ForEach(childSpaces(of: s, in: spaces)) { k in
                                SpaceRowLabel(space: k, item: workItem(for: k), child: true, home: home, accent: c.color)
                                    .tag(Section.space(k.place))
                            }
                        }
                    }
                }
                if !closed.isEmpty {
                    let resumable = closed.filter { $0.state == .resumable }
                    let cold = closed.filter { $0.state == .cold }
                    SwiftUI.Section("Resumable") {
                        ForEach(resumable) { w in
                            TreeRowLabel(item: w, status: "resumable", accent: c.color).tag(Section.tree(w.path))
                        }
                        if !cold.isEmpty {
                            DisclosureGroup(isExpanded: $showCold) {
                                ForEach(cold) { w in TreeRowLabel(item: w, status: "cold", accent: c.color).tag(Section.tree(w.path)) }
                            } label: { Text("\(cold.count) cold").foregroundStyle(.secondary) }
                        }
                    }
                }
                SwiftUI.Section {
                    #if os(macOS)
                    Label("Inbox", systemImage: store.unread.isEmpty ? "tray" : "tray.full")
                        .badge(store.unread.isEmpty ? Text(store.inbox.count >= 300 ? "300+" : "\(store.inbox.count)")
                                                    : Text("\(store.unread.count) new"))
                        .tag(Section.inbox)
                    #endif
                    Label("Pull requests", systemImage: "arrow.triangle.pull").badge(store.prs.count).tag(Section.prs)
                    Label("Issues", systemImage: "exclamationmark.circle").badge(store.issues.count).tag(Section.issues)
                    ForEach(c.extras.sections) { x in Label(x.title, systemImage: x.symbol).tag(Section.extra(x.id)) }
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 290)
        } detail: {
            detail
                .toolbar {
                    ToolbarItem { Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") } }
                    #if os(iOS)
                    ToolbarItem { Button { showSettings = true } label: { Image(systemName: "gear") } }
                    #endif
                }
        }
        .tint(c.color)
        .overlay(alignment: .bottom) { footer }
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
            section = store.unread.isEmpty ? nil : .inbox         // a widget tap lands where the news is
        }
        .onReceive(NotificationCenter.default.publisher(for: .oracleFilesDropped)) { n in
            if let count = n.object as? Int { store.noteDrop(count); section = .inbox }
        }
        #else
        .sheet(isPresented: $showSettings) { TokenSettings(onSave: { Task { await store.refresh() } }) }
        #endif
        .onAppear { store.start() }
        .onChange(of: store.spaces) { _, _ in fixSelection() }
        .onChange(of: store.work) { _, _ in fixSelection() }
    }

    /// Show the pick in the sidebar too: nothing picked, or the picked space closed → the default.
    private func fixSelection() {
        switch section {
        case nil: section = defaultSection
        case .space(let p)? where !store.spaces.contains(where: { $0.place == p }): section = defaultSection
        case .tree(let path)? where !store.work.contains(where: { $0.path == path }): section = defaultSection
        default: break
        }
    }

    // MARK: spaces and worktrees for the sidebar — herdr's order, linked worktrees nested under their repo

    private func orderedSpaces(home: String) -> [HerdrSpace] {
        store.spaces.sorted { a, b in
            if (a.session == home) != (b.session == home) { return a.session == home }
            return a.session != b.session ? a.session < b.session : a.number < b.number
        }
    }
    private func rootSpaces(_ spaces: [HerdrSpace]) -> [HerdrSpace] {
        spaces.filter { s in
            !s.linked || !spaces.contains { !$0.linked && $0.repoRoot != nil && $0.repoRoot == s.repoRoot && $0.session == s.session }
        }
    }
    private func childSpaces(of s: HerdrSpace, in spaces: [HerdrSpace]) -> [HerdrSpace] {
        guard !s.linked, let root = s.repoRoot else { return [] }
        return spaces.filter { $0.linked && $0.repoRoot == root && $0.session == s.session }
    }
    private func workItem(for s: HerdrSpace) -> WorkItem? {
        if let path = s.checkout { return store.work.first { $0.path == path } }
        // herdr does not always know a plain space's repo; its label is the checkout folder
        return store.work.first { $0.isMain && $0.folder == s.label }
    }
    /// Worktrees with no herdr space and no pane: the ones to resume, and the cold ones.
    private func closedTrees(_ spaces: [HerdrSpace]) -> [WorkItem] {
        store.work.filter { w in
            w.panes.isEmpty && !spaces.contains { $0.checkout == w.path || (w.isMain && $0.checkout == nil && $0.label == w.folder) }
        }
    }
    /// Nothing picked yet: the most urgent space, else the first worktree to resume.
    private var defaultSection: Section? {
        let spaces = orderedSpaces(home: WorkFormat.homeSession(store.activity))
        if let s = spaces.min(by: { WorkFormat.rank($0.status) < WorkFormat.rank($1.status) }) { return .space(s.place) }
        return closedTrees(spaces).first.map { .tree($0.path) }
    }

    @ViewBuilder private var detail: some View {
        switch section ?? defaultSection {
        case .space(let p)?:
            if let s = store.spaces.first(where: { $0.place == p }) {
                SpaceDetail(store: store, space: s, item: workItem(for: s)).id(p)
            } else {
                Text("That space is closed now.").foregroundStyle(.secondary)
            }
        case .tree(let path)?:
            if let w = store.work.first(where: { $0.path == path }) {
                ClosedTreeDetail(item: w, repo: c.repoSlug).id(path)
            } else {
                Text("That worktree is gone.").foregroundStyle(.secondary)
            }
        case nil:
            #if os(macOS)
            Text("Nothing from herdr or maw for \(c.localPath)").foregroundStyle(.secondary)
            #else
            Text("Work is read from herdr on the Mac.").foregroundStyle(.secondary)
            #endif
        case .inbox?: InboxList(store: store)
        case .prs?: GHList(title: "Open pull requests", items: store.prs, empty: "No open pull requests")
        case .issues?: GHList(title: "Open issues", items: store.issues, empty: "No open issues")
        case .extra(let id)?: c.extras.sections.first { $0.id == id }.map { $0.view() } ?? AnyView(EmptyView())
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let d = store.lastDrop { Label(d, systemImage: "tray.and.arrow.down").foregroundStyle(c.color) }
            ForEach(store.problems, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            Spacer()
            if let t = store.lastRefresh { Text("updated \(t.formatted(date: .omitted, time: .standard))").foregroundStyle(.secondary) }
        }
        .font(.caption).padding(.horizontal, 12).padding(.vertical, 6).background(.bar)
    }
}

struct IdentityCard: View {
    let config: OracleConfig; let acts: [OracleSnapshot.Activity]
    var body: some View {
        let need = acts.filter { $0.status == "blocked" || $0.status == "done" }.count
        let working = acts.filter { $0.status == "working" }.count
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(config.color.gradient).frame(width: 48, height: 48)
                Image(systemName: config.symbol).font(.title2.weight(.semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name).font(.title2.bold())
                Text(config.tagline).font(.callout).foregroundStyle(.secondary)
                Text(config.repoSlug).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(need > 0 ? "\(need) need you" : working > 0 ? "\(working) working" : "idle").font(.caption.bold())
                    .foregroundStyle(need + working > 0 ? config.color : .secondary)
            }
        }.padding(.vertical, 8)
    }
}

// MARK: - Work: the sidebar lists herdr's spaces (linked worktrees nested) and the worktrees to resume;
// the detail is the picked space with every pane at its real size.
// Cards: neo-oracle ψ/writing/diagrams/2026-10-07_oracle-app-herdr-layout.txt (and …-work-view.txt)

struct SpaceRowLabel: View {
    let space: HerdrSpace; let item: WorkItem?; let child: Bool; let home: String; let accent: Color
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if child { Text("└").font(.callout.monospaced()).foregroundStyle(.tertiary) }
            StatusGlyph(status: space.status, accent: accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(child ? (item?.slug ?? space.label) : space.label).lineLimit(1).truncationMode(.middle)
                if !child, let b = item?.branch, !b.isEmpty {
                    Text(b).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if space.session != home { Text(space.session).font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.leading, child ? 10 : 0)
    }
}

struct TreeRowLabel: View {
    let item: WorkItem; let status: String; let accent: Color
    var body: some View {
        HStack(spacing: 7) {
            StatusGlyph(status: status, accent: accent)
            Text(item.isMain ? item.folder : item.slug).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let n = item.issue { Text("#\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            Text(item.born.map(WorkFormat.ago) ?? "").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// One herdr space: its name, branch, issue and PR, then its tabs with every pane drawn at its real size.
struct SpaceDetail: View {
    @ObservedObject var store: OracleStore
    let space: HerdrSpace
    let item: WorkItem?
    @State private var tabPick: String?
    var body: some View {
        let c = store.config
        let home = WorkFormat.homeSession(store.activity)
        let tab = space.tabs.first { $0.place == (tabPick ?? space.activeTab) } ?? space.tabs.first
        let acts = Dictionary(store.activity.map { ($0.place, $0) }, uniquingKeysWith: { a, _ in a })
        let twins = WorkParse.twins(store.activity)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    // the same name the sidebar shows: a linked worktree by its slug, any other space by herdr's label
                    Text(space.linked ? (item?.slug ?? space.label) : space.label)
                        .font(.title2.weight(.semibold)).lineLimit(1).layoutPriority(1)
                    let sub = [(!space.linked && item?.folder != space.label) ? item?.folder : nil,
                               item?.branch.replacingOccurrences(of: "/", with: "-") == item?.slug ? nil : item?.branch]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                    if !sub.isEmpty {
                        Text(sub).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    if let item { WorkLinks(item: item, repo: c.repoSlug) }
                    Spacer(minLength: 8)
                    #if os(macOS)
                    Button("Show in herdr") { WorkFormat.showInHerdr(space, tabId: tab?.tabId) }.controlSize(.small)
                    #endif
                }
                if space.tabs.count > 1, let tab {
                    HStack(spacing: 6) {
                        ForEach(space.tabs) { t in
                            let on = t.place == tab.place
                            Button { tabPick = t.place } label: {
                                Text(t.label.isEmpty ? "tab" : t.label).font(.callout.monospacedDigit().weight(.medium))
                                    .padding(.horizontal, 14).padding(.vertical, 4)
                                    .foregroundStyle(on ? Color.white : Color.primary)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(on ? c.color : Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                        if tab.zoomed { Text("zoomed").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if let tab { LayoutCanvas(tab: tab, acts: acts, twins: twins, home: home, accent: c.color) }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(space.label)
    }
}

/// A worktree with no herdr space: its name, branch, issue and PR, and the way back in.
struct ClosedTreeDetail: View {
    let item: WorkItem
    let repo: String
    @State private var copied: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(item.isMain ? item.folder : item.slug).font(.title2.weight(.semibold)).lineLimit(1).layoutPriority(1)
                    if !item.branch.isEmpty, item.branch.replacingOccurrences(of: "/", with: "-") != item.slug {
                        Text(item.branch).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    WorkLinks(item: item, repo: repo)
                    Spacer(minLength: 8)
                }
                ClosedTreePanel(item: item, copied: $copied)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(item.slug)
    }
}

/// The tab as herdr draws it: every pane at its real rectangle (terminal cells, scaled).
struct LayoutCanvas: View {
    let tab: HerdrTab
    let acts: [String: OracleSnapshot.Activity]
    let twins: [String: String]
    let home: String
    let accent: Color
    var body: some View {
        let a = tab.area
        GeometryReader { g in
            let sx = g.size.width / CGFloat(max(a.width, 1)), sy = g.size.height / CGFloat(max(a.height, 1))
            ZStack(alignment: .topLeading) {
                ForEach(tab.panes) { p in
                    PaneBoxView(box: p, act: acts[p.place], twin: twins[p.place], home: home, accent: accent)
                        .frame(width: max(0, CGFloat(p.rect.width) * sx - 6), height: max(0, CGFloat(p.rect.height) * sy - 6))
                        .offset(x: CGFloat(p.rect.x - a.x) * sx + 3, y: CGFloat(p.rect.y - a.y) * sy + 3)
                }
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        }
        .aspectRatio(CGFloat(a.width) / (CGFloat(max(a.height, 1)) * 2.1), contentMode: .fit)   // a cell is ~2.1x taller than wide
    }
}

struct PaneBoxView: View {
    let box: HerdrPaneBox
    let act: OracleSnapshot.Activity?
    let twin: String?
    let home: String
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusGlyph(status: box.agent == nil ? "shell" : box.status, accent: accent)
                Text(WorkFormat.pane(box.place, home: home)).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(box.name ?? box.agent ?? box.label ?? "shell").font(.caption.weight(.medium))
                    .foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 2)
                if let s = act?.since { Text(WorkFormat.ago(s)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
            }
            if let twin {
                Text("same session as \(WorkFormat.pane(twin, home: home)) — two panes, one transcript")
                    .font(.callout).foregroundStyle(.orange)
            } else if box.agent != nil {
                Text(act?.title ?? box.status).font(.callout).foregroundStyle(.primary.opacity(act == nil ? 0.5 : 0.9))
            } else {
                Text((box.label.map { $0 + " · " } ?? "") + (box.cwd as NSString).lastPathComponent)
                    .font(.callout.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(box.focused ? 0.075 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(box.focused ? accent.opacity(0.9) : Color.primary.opacity(0.13), lineWidth: box.focused ? 1.5 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contextMenu {
            Button("Copy pane id") { WorkFormat.copy(box.paneId) }
            if let sid = act?.session {
                Button("Copy resume command") {
                    WorkFormat.copy("cd '\(box.cwd)' && " + (box.agent == "codex" ? "codex resume \(sid)" : "claude --resume \(sid)"))
                }
            }
            Button("Copy folder path") { WorkFormat.copy(box.cwd) }
        }
    }
}

/// herdr's sidebar marks: ◐ working · ✓ done · ! blocked · ○ idle.
struct StatusGlyph: View {
    let status: String
    let accent: Color
    var body: some View {
        let look: (symbol: String, color: Color) = {
            switch status {
            case "working": return ("circle.lefthalf.filled", accent)
            case "done": return ("checkmark", .green)
            case "blocked": return ("exclamationmark.circle.fill", .orange)
            case "idle": return ("circle", Color.secondary)
            case "shell": return ("terminal", Color.secondary)
            case "resumable": return ("arrow.uturn.backward", Color.secondary)
            case "cold": return ("moon.zzz", Color.secondary.opacity(0.6))
            default: return ("circle.dotted", Color.secondary.opacity(0.6))
            }
        }()
        Image(systemName: look.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(look.color).frame(width: 12)
    }
}

/// A worktree with no herdr space open: the way back in.
struct ClosedTreePanel: View {
    let item: WorkItem
    @Binding var copied: String?
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: item.resumeCommand == nil ? "moon.zzz" : "arrow.uturn.backward.circle")
                .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(item.resumeCommand == nil ? "No herdr space, no session to resume" : "No herdr space open — the session is waiting")
                .foregroundStyle(.secondary)
            if let b = item.born { Text("made \(WorkFormat.ago(b)) ago").font(.caption).foregroundStyle(.secondary) }
            if let cmd = item.resumeCommand {
                Text(cmd).font(.caption.monospaced()).textSelection(.enabled).multilineTextAlignment(.center)
                Button(copied == item.id ? "Copied" : "Copy resume command") { WorkFormat.copy(cmd); copied = item.id }
                    .buttonStyle(.borderedProminent)
            }
            #if os(macOS)
            Button("Open folder") { WorkFormat.open(URL(fileURLWithPath: item.path)) }.buttonStyle(.link)
            #endif
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [6, 5])))
        .aspectRatio(168 / (42 * 2.1), contentMode: .fit)
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
