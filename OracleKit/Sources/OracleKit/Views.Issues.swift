import SwiftUI

/// Picking up an issue on the Issues page. The app runs /herdr-ticket's script itself — no agent in between, no
/// message to send — so seconds after the click the worktree (named from the issue), its herdr space and a STATEFUL
/// claude working the issue exist, and the drawer shows that claude. The one-shot is the option. (Nat, 2026-10-08:
/// "click pickup it feel broken … one shot is an option, start with stateful")
enum PickUp {
    enum Action: Equatable { case agent, oneshot, open }
    struct Item: Equatable { let label: String; let action: Action }
    /// No worktree names the issue: Pick up (an interactive agent), or as a one-shot. Once one does: open its session.
    static func actions(inWorktree: Bool) -> [Item] {
        inWorktree ? [Item(label: "Open session", action: .open)]
                   : [Item(label: "Pick up", action: .agent), Item(label: "Pick up as a one-shot", action: .oneshot)]
    }
    static var script: String { NSHomeDirectory() + "/.claude/skills/herdr-ticket/ticket.sh" }
    /// What a click runs, minus `bash <script>`: also the tooltip, so the human can run it by hand.
    static func command(_ action: Action, issue n: Int) -> String {
        switch action {
        case .agent: return "ticket.sh pick \(n)"
        case .oneshot: return "ticket.sh pick \(n) --oneshot"
        case .open: return "ticket.sh open \(n)"
        }
    }
    static func arguments(_ action: Action, issue n: Int, repo: String) -> [String] {
        [script] + command(action, issue: n).split(separator: " ").dropFirst().map(String.init) + ["--repo", repo, "--json"]
    }
    /// The script's one JSON line: the pane the agent is in, a worktree that already exists, or why not + the fix.
    enum Outcome: Equatable { case started(pane: String), existing, failed(String) }
    static func outcome(status: Int32, json: String) -> Outcome {
        let d = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        if status == 0, d["ok"] as? Bool == true {
            if let pane = d["pane"] as? String, !pane.isEmpty { return .started(pane: pane) }
            if d["existing"] as? Bool == true { return .existing }
        }
        let why = d["error"] as? String ?? "ticket.sh exited \(status) without saying why"
        return .failed(([why] + (d["fix"] as? [String] ?? [])).joined(separator: "\n"))
    }
    enum Progress: Equatable { case running, failed(String) }
    #if os(macOS)
    /// `session` is the herdr server the oracle's panes live on (HERDR_SESSION for every herdr call the script makes).
    static func run(_ action: Action, issue n: Int, repo: String, session: String) async -> Outcome {
        guard FileManager.default.fileExists(atPath: script) else {
            return .failed("the /herdr-ticket skill is not installed on this Mac\nnpx skills@latest add nat-build-with-oracle/skills")
        }
        let env = session.isEmpty ? [:] : ["HERDR_SESSION": session]
        guard let r = await Shell.capture("bash", arguments(action, issue: n, repo: repo), env: env, timeout: 120) else {
            return .failed("bash would not start\nbash \(script) pick \(n) --repo \(repo)")
        }
        let o = outcome(status: r.status, json: r.out)
        // an issue that already has a worktree but no live agent: open its session instead
        if o == .existing, action != .open { return await run(.open, issue: n, repo: repo, session: session) }
        return o
    }
    #endif
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
    /// Runs a PickUp action for an issue (Mac only: the phone runs no scripts); `picking` marks cards starting or failed.
    var onPick: ((GHItem, PickUp.Action) -> Void)? = nil
    var picking: [Int: PickUp.Progress] = [:]
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
                    ForEach(rows) { it in
                        GHCard(item: it, status: status(it), detail: detail(it), onSend: onSend.map { f in { f(it) } }, picks: picks(it),
                               busy: picking[it.number] == .running, failure: failure(it))
                    }
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
        case .issues:
            switch picking[it.number] {
            case .running: return ("starting…", accent)
            case .failed: return ("couldn't start", .red)
            case nil: return tree(it) != nil ? ("in a worktree", .green) : ("no worktree yet", accent)
            }
        }
    }
    private func picks(_ it: GHItem) -> [GHCard.Pick] {
        guard kind == .issues, let pick = onPick, picking[it.number] != .running else { return [] }
        return PickUp.actions(inWorktree: tree(it) != nil).map { a in
            GHCard.Pick(label: a.label, command: PickUp.command(a.action, issue: it.number)) { pick(it, a.action) }
        }
    }
    private func failure(_ it: GHItem) -> String? {
        if case .failed(let why) = picking[it.number] { return why }
        return nil
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
    /// PickUp actions: all of them in the context menu, the first as a pill while the pointer is over the card.
    var picks: [Pick] = []
    struct Pick { let label: String; let command: String; let run: () -> Void }
    /// A pick is running for this card (a spinner instead of the status), or the last one failed (why + the fix).
    var busy = false
    var failure: String? = nil
    @State var hover = false   // not private: GHCardRenderTests draws the hover pill
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
                if busy {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(status.label).font(.caption.weight(.semibold)).foregroundStyle(status.color)
                    }
                } else if hover, let p = picks.first {
                    // a gesture, not a nested Button: the whole card is already a Button (it opens GitHub)
                    Text(p.label).font(.caption.weight(.semibold)).foregroundStyle(status.color)
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(Capsule().fill(status.color.opacity(0.16)))
                        .contentShape(Capsule())
                        .highPriorityGesture(TapGesture().onEnded { p.run() })
                        .help(p.command)
                } else if let failure {
                    Text(status.label).font(.caption.weight(.semibold)).foregroundStyle(status.color).help(failure)
                } else {
                    Text(status.label).font(.caption).foregroundStyle(.secondary)
                }
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
            ForEach(picks.indices, id: \.self) { i in Button(picks[i].label, action: picks[i].run).handCursor() }
            if let failure { Button("Copy why it couldn't start") { WorkFormat.copy(failure) } }
            if !picks.isEmpty || failure != nil { Divider() }
            if let onSend { Button("Send to agent…", action: onSend).handCursor() }
            if let u = item.url { Button("Open on GitHub") { WorkFormat.open(u) } }
        }
    }
}
