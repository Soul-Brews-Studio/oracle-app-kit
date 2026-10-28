import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Work: one row per /herdr-wt worktree
// Layout card: neo-oracle ψ/writing/diagrams/2026-10-07_oracle-app-work-view.txt

#if os(macOS)
struct WorkView: View {
    @ObservedObject var store: OracleStore
    var openPane: Binding<String?> = .constant(nil)
    @State private var allResumable = false
    @State private var showCold = false         // folded to one line; a click opens it
    @State private var copiedPlan = false
    @State private var copied: String?
    @State private var actionError: String?     // what a Close / Open answered when it failed, with the command
    @State private var cleaning: WorkItem?      // Clean up…: the worktree whose dry-run plan the confirm shows
    @State private var cleanPlan = ""
    private var c: OracleConfig { store.config }

    /// Run a herdr action from a card, then refresh; keep its error on the page.
    private func act(_ f: @escaping () async -> String?) {
        Task { actionError = await f(); await store.refresh() }
    }

    var body: some View {
        let work = store.work
        let g = WorkGroups.make(work: work, places: store.places)
        let next: [WorkParse.NextIssue] = work.isEmpty ? [] : WorkParse.unstarted(issues: store.issues, prs: store.prs, work: work)
        let twins = WorkParse.twins(store.activity)
        let home = WorkFormat.homeSession(store.activity)
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                WorkHero(acts: store.activity, color: c.color)
                if let e = actionError {
                    Text(e).font(.system(size: 11)).foregroundStyle(.orange).textSelection(.enabled)
                }
                // live first: each running session over the cards whose panes are in it
                ForEach(g.running) { r in
                    VStack(alignment: .leading, spacing: 10) {
                        SessionHeader(store: store, place: r.place)
                        ForEach(r.live) { liveCard($0, twins: twins, home: home) }
                    }
                }
                if !g.live.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        if g.running.isEmpty { WorkFormat.header("LIVE", g.live.count) }
                        ForEach(g.live) { liveCard($0, twins: twins, home: home) }
                    }
                }
                // each stopped session over the worktrees its saved conversations belong to
                ForEach(g.stopped) { s in
                    VStack(alignment: .leading, spacing: 4) {
                        SessionHeader(store: store, place: s.place, toResume: s.toResume)
                        ForEach(s.rows) { treeRow($0) }
                        // what Resume also brings back that has no row here: one quiet line each, no buttons
                        ForEach(s.extras) { e in
                            Text(e.line).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                .padding(.vertical, 2).padding(.horizontal, 4)
                        }
                    }
                }
                if !g.resumable.isEmpty {
                    block("RESUMABLE", g.resumable.count) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(allResumable ? g.resumable : Array(g.resumable.prefix(6))) { treeRow($0) }
                        }
                        if g.resumable.count > 6 {
                            Button(allResumable ? "show less" : "\(g.resumable.count - 6) more") { allResumable.toggle() }.handCursor()
                                .buttonStyle(.plain).foregroundStyle(c.color).padding(.leading, 4)
                        }
                    }
                }
                if !g.cold.isEmpty { coldBlock(g.cold) }
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
        .overlay { if work.isEmpty && g.stopped.isEmpty { emptyNote } }
        .navigationTitle("Work")
        .confirmationDialog("Clean up \(cleaning?.folder ?? "")?", isPresented: Binding(get: { cleaning != nil }, set: { if !$0 { cleaning = nil } }),
                            titleVisibility: .visible) {
            Button("Clean up — run the plan", role: .destructive) {
                if let w = cleaning { act { await WorkFormat.clean([w.path], go: true) } }
            }
            Button("Copy the command") { if let w = cleaning { WorkFormat.copy(WorkFormat.cleanCommand([w.path], go: true)) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(cleanPlan.isEmpty ? "maw herdr clean did not answer with a plan." : cleanPlan)
        }
    }

    private func liveCard(_ w: WorkItem, twins: [String: String], home: String) -> some View {
        LiveCard(item: w, config: c, twins: twins, home: home, copied: $copied, openPane: openPane,
                 close: { place in act { await HerdrControl.closePane(place: place) } },
                 shells: panesOf(w, store: store).filter { p in !w.panes.contains { $0.place == p } }) {
            store.bringToMain(w)
            if w.panes.contains(where: { $0.place == openPane.wrappedValue }) { openPane.wrappedValue = nil }   // bring here closes its drawer
        }
    }

    private func treeRow(_ w: WorkItem) -> some View {
        TreeRow(item: w, config: c, copied: $copied,
                // main and bodies: only with their exact claude id (ticket.sh resumes claude, not codex)
                open: (w.isMain || w.isBody) && (w.resumeId == nil || w.resumeProvider == "codex") ? nil : {
                    act { await HerdrControl.open(worktree: w.path, repo: w.repoRoot ?? c.localPath,
                                                  sessionId: w.isMain || w.isBody ? w.resumeId : nil) }
                },
                clean: { review(w) })
    }

    /// Clean up…: the dry-run plan first (`maw herdr clean <path>` changes nothing), then the confirm runs it with --go.
    private func review(_ w: WorkItem) {
        Task {
            cleanPlan = await Shell.run("maw", WorkFormat.cleanArgs([w.path], go: false), timeout: 30)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            cleaning = w
        }
    }

    /// COLD folded to one line; a click lists them, each with its own Clean up…
    private func coldBlock(_ cold: [WorkItem]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { withAnimation(.snappy) { showCold.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: showCold ? "chevron.down" : "chevron.right").font(.caption2.bold())
                        Text(WorkGroups.coldLine(cold.count)).font(.callout)
                    }
                    .foregroundStyle(.secondary).contentShape(Rectangle())
                }.buttonStyle(.plain).handCursor()
                // the plan only: maw herdr clean lists what it would remove; nothing changes without --go
                let plan = WorkFormat.cleanCommand(cold.map(\.path))
                Button(copiedPlan ? "plan copied" : "copy cleanup plan") { WorkFormat.copy(plan); copiedPlan = true }.handCursor()
                    .buttonStyle(.plain).foregroundStyle(c.color).font(.caption).help(plan)
            }
            if showCold {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(cold) { treeRow($0).opacity(0.7) }
                }
            }
        }
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
        if let p = store.places.first(where: { !$0.running }) {
            Text("Nothing running here: \(p.session) is \(HerdrPlaces.stoppedSince(p.savedAt)).").foregroundStyle(.secondary)
        } else {
            Text("Nothing from maw herdr ls for \(c.localPath)").foregroundStyle(.secondary)
        }
        #else
        Text("Work is read from herdr on the Mac.").foregroundStyle(.secondary)
        #endif
    }
}
#endif

/// The widget's rule: needs you > working > idle — one big word and the live counts (the LIVE rows say what each pane does).
struct WorkHero: View {
    let acts: [OracleSnapshot.Activity]; let color: Color
    var body: some View {
        let need = acts.filter { $0.status == "blocked" || $0.status == "done" }.count
        let working = acts.filter { $0.status == "working" }.count
        VStack(alignment: .leading, spacing: 6) {
            Text(need > 0 ? "needs you" : working > 0 ? "working" : "idle")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(need + working > 0 ? color : Color.secondary)
            Text("\(acts.count) live \(acts.count == 1 ? "pane" : "panes") · \(working) working · \(need) need you")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct LiveCard: View {
    let item: WorkItem; let config: OracleConfig; let twins: [String: String]; let home: String
    @Binding var copied: String?
    var openPane: Binding<String?> = .constant(nil)
    var close: ((String) -> Void)? = nil  // close one pane (its agent quits; the conversation stays resumable)
    var shells: [String] = []          // plain shell panes of this worktree's herdr space
    var bring: () -> Void = {}
    @State private var closing: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // the sidebar's name first (its branch, else its folder); the slug or "body · <repo>" is detail
                let name = item.branch.isEmpty ? item.folder : item.branch
                Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                if item.slug != name {
                    Text(item.slug).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
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
                    if close != nil {
                        Button { closing = p.place } label: { Image(systemName: "xmark").font(.caption2) }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).handCursor()
                            .help("Close this pane: its agent quits, its conversation stays under RESUMABLE")
                    }
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
        .confirmationDialog("Close \(closing.map { WorkFormat.pane($0, home: home) } ?? "")?",
                            isPresented: Binding(get: { closing != nil }, set: { if !$0 { closing = nil } }), titleVisibility: .visible) {
            Button("Close — its agent quits", role: .destructive) { if let p = closing { close?(p) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its conversation stays: it shows under RESUMABLE, where Resume brings it back. "
                 + "If this is the pane you are talking to, that conversation stops mid-reply.")
        }
    }
}

/// A resumable or cold worktree: slug, its issue and PR, age, and the way back in.
struct TreeRow: View {
    let item: WorkItem; let config: OracleConfig
    @Binding var copied: String?
    var open: (() -> Void)? = nil     // resume its own session in a pane (ticket.sh open); nil: copy the command instead
    var clean: (() -> Void)? = nil    // Clean up…: show the dry-run plan, then confirm
    var body: some View {
        HStack(spacing: 10) {
            Text(item.slug).lineLimit(1).truncationMode(.middle)
            WorkLinks(item: item, repo: config.repoSlug)
            Spacer(minLength: 8)
            Text(item.born.map(WorkFormat.ago) ?? "").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            if let open, let cmd = item.resumeCommand {
                Button("Resume", action: open).handCursor()
                    .buttonStyle(.borderless).help("Resume this worktree's own session in a herdr pane — \(cmd)")
                    .frame(width: 64, alignment: .trailing)
            } else if let cmd = item.resumeCommand {
                Button(copied == item.id ? "copied" : "copy resume") { WorkFormat.copy(cmd); copied = item.id }.handCursor()
                    .buttonStyle(.borderless).help(cmd)
                    .frame(width: 64, alignment: .trailing)
            } else if let clean {
                Button("Clean up…", action: clean).handCursor()
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("See what \(WorkFormat.cleanCommand([item.path])) would remove, then confirm")
                    .frame(width: 72, alignment: .trailing)
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
    static func cleanCommand(_ paths: [String], go: Bool = false) -> String {
        "maw herdr clean " + paths.map { "'\($0)'" }.joined(separator: " ") + (go ? " --go" : "")
    }
    /// The same as arguments to `maw`: the plan, or with `go` the removal itself.
    static func cleanArgs(_ paths: [String], go: Bool) -> [String] {
        ["herdr", "clean"] + paths + (go ? ["--go"] : [])
    }
    #if os(macOS)
    /// Run the cleanup for real (--go): nil when it worked, else what to run by hand.
    static func clean(_ paths: [String], go: Bool) async -> String? {
        await Shell.run("maw", cleanArgs(paths, go: go), timeout: 120) == nil ? "maw herdr clean failed — run:  \(cleanCommand(paths, go: go))" : nil
    }
    #endif
    static func header(_ title: String, _ n: Int, note: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).tracking(1.4)
            Text("\(n)").font(.caption.monospacedDigit())
            if !note.isEmpty { Text(note).font(.caption) }
        }
        .foregroundStyle(.secondary)
    }
}
