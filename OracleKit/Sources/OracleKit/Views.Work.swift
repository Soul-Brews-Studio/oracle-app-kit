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
