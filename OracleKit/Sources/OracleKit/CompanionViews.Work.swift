#if os(iOS)
import SwiftUI

// MARK: - Work: one card per /herdr-wt worktree, its panes, the pane's live screen

/// Work item states, in the Mac's order (WorkItem.State). A word the phone does not know counts as open, never hidden.
enum PhoneState: Int, Comparable {
    case needsYou, working, open, resumable, cold
    init(_ label: String) {
        switch label {
        case "needs you": self = .needsYou
        case "working": self = .working
        case "resumable": self = .resumable
        case "cold": self = .cold
        default: self = .open
        }
    }
    static func < (a: PhoneState, b: PhoneState) -> Bool { a.rawValue < b.rawValue }
}

/// A pane the phone opens: where it is, what it is doing, its state when it was tapped.
struct PhonePaneRef: Identifiable, Hashable {
    let place: String, title: String, status: String
    var id: String { place }
}

struct PhoneWorkView: View {
    @ObservedObject var store: OracleStore
    @ObservedObject private var client = CompanionClient.shared
    @State private var work: CompanionAPI.Work?
    @State private var failed: String?
    @State private var readAt: Date?            // when a read last worked: a failing one keeps the page and says since when
    @State private var pane: PhonePaneRef?
    @State private var copied: String?
    @State private var allResumable = false
    @State private var showCold = true          // open, like the Mac: a cold list on view is a list that gets cleaned up
    @State private var copiedPlan = false
    @State private var reading = false          // a read is in flight: onAppear, the poll and a pull do not stack
    private static var actionDone = false       // launch arguments last the whole process: open the test pane once
    private var c: OracleConfig { store.config }
    private var repo: String { client.hello?.repoSlug ?? c.repoSlug }

    var body: some View {
        Group {
            if client.isPaired { page } else {
                PhoneUnpaired(config: c, symbol: "square.stack.3d.up",
                              gives: "Work is read from herdr on your Mac: every worktree of \(c.name), its agents and what each is doing — and the live screen of any pane, here on your \(PhoneStyle.device).")
            }
        }
        .navigationTitle("Work")
    }

    private var page: some View {
        let items = work?.items ?? []
        let live = items.filter { PhoneState($0.state) <= .open }
        let resumable = items.filter { PhoneState($0.state) == .resumable }
        let cold = items.filter { PhoneState($0.state) == .cold }
        let home = PhoneFormat.home(work?.activity ?? [])
        let taken = Set(items.compactMap(\.issue))
        let next: [WorkParse.NextIssue] = items.isEmpty ? [] : store.issues.filter { !taken.contains($0.number) }
            .map { i in WorkParse.NextIssue(issue: i, pr: store.prs.first { $0.closes.contains(i.number) }) }
        return ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let w = work { PhoneWorkHero(panes: w.activity, color: c.color) }   // "idle" is an answer: not before there is one
                ForEach(work?.problems ?? [], id: \.self) { Text($0).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
                if let failed { PhoneReadFailure(problem: failed, since: readAt) { Task { await load() } } }
                if !live.isEmpty {
                    block("LIVE", live.count) {
                        ForEach(live) { w in
                            PhoneLiveCard(item: w, slug: slug(w), repo: repo, home: home, accent: c.color, copied: $copied) { pane = $0 }
                        }
                    }
                }
                if !resumable.isEmpty {
                    block("RESUMABLE", resumable.count) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(allResumable ? resumable : Array(resumable.prefix(6))) {
                                PhoneTreeRow(item: $0, slug: slug($0), born: born($0), repo: repo, copied: $copied)
                            }
                        }
                        if resumable.count > 6 {
                            Button(allResumable ? "show less" : "\(resumable.count - 6) more") { allResumable.toggle() }.padding(.leading, 4)
                        }
                    }
                }
                if !cold.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Button { withAnimation(.snappy) { showCold.toggle() } } label: {
                                HStack(spacing: 6) {
                                    WorkFormat.header("COLD", cold.count, note: "no session to resume")
                                    Image(systemName: showCold ? "chevron.down" : "chevron.right").font(.caption2.bold()).foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).accessibilityValue(showCold ? "shown" : "hidden")
                            Spacer(minLength: 4)
                            // the plan only: maw herdr clean lists what it would remove; nothing changes without --go
                            Button(copiedPlan ? "plan copied" : "copy cleanup plan") {
                                WorkFormat.copy(WorkFormat.cleanCommand(cold.map(\.path))); copiedPlan = true
                            }
                            .font(.caption)
                        }
                        if showCold {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(cold) { PhoneTreeRow(item: $0, slug: slug($0), born: born($0), repo: repo, copied: $copied).opacity(0.7) }
                            }
                        }
                    }
                }
                if !next.isEmpty {
                    block("NEXT", next.count, note: next.count == 1 ? "issue with no worktree yet" : "issues with no worktree yet") { NextBox(next: next) }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay {
            if work == nil && failed == nil {
                VStack(spacing: 8) { ProgressView(); Text("reading herdr on the Mac…").font(.callout).foregroundStyle(.secondary) }
            } else if work != nil && items.isEmpty && failed == nil {
                Text("Nothing from maw herdr ls on the Mac for \(c.name).").foregroundStyle(.secondary).padding()
            }
        }
        .refreshable { await load() }
        .onAppear { Task { await load() } }   // not a .task: the push into this page cancels it
        .task {   // the Mac's own refresh is every 20 s: ask every 10 — only while this page is on screen (the loop ends with it: Back, another page)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                if Task.isCancelled { break }
                await load()
            }
        }
        .onForeground { Task { await load() } }
        .onChange(of: client.pairing) { work = nil; readAt = nil; Task { await load() } }
        .sheet(item: $pane) { p in PhonePaneScreen(ref: p, accent: c.color, home: home) }
        .onReceive(NotificationCenter.default.publisher(for: .oraclePhoneReload)) { _ in Task { await load() } }
    }

    private func load() async {
        if reading { return }
        reading = true; defer { reading = false }
        if let w = await client.shielded({ await $0.work() }) { work = w; readAt = Date(); failed = nil } else { failed = PhoneFormat.why(client) }
        if !Self.actionDone, let place = UserDefaults.standard.string(forKey: "workPane"), !place.isEmpty, let w = work {   // -workPane <place> (tests)
            Self.actionDone = true
            let p = w.activity.first { $0.place == place } ?? w.items.flatMap(\.panes).first { $0.place == place }
            pane = PhonePaneRef(place: place, title: p?.title ?? "", status: p?.status ?? "")
        }
    }

    /// The /herdr-wt slug of a worktree (its folder without the oracle and the date); the main checkout keeps its folder.
    private func slug(_ w: CompanionAPI.WorkItem) -> String { w.isMain ? w.folder : WorkParse.parseFolder(w.folder, oracle: c.name.lowercased()).slug }
    private func born(_ w: CompanionAPI.WorkItem) -> Date? { w.isMain ? nil : WorkParse.parseFolder(w.folder, oracle: c.name.lowercased()).born }

    private func block<Content: View>(_ title: String, _ n: Int, note: String = "", @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WorkFormat.header(title, n, note: note)
            content()
        }
    }
}

/// The widget's rule: needs you > working > idle — one big word, the counts, the urgent pane's ask.
struct PhoneWorkHero: View {
    let panes: [CompanionAPI.Pane]
    let color: Color
    var body: some View {
        let need = panes.filter { $0.status == "blocked" || $0.status == "done" }.count
        let working = panes.filter { $0.status == "working" }.count
        let urgent = panes.min { WorkFormat.rank($0.status) < WorkFormat.rank($1.status) }
        VStack(alignment: .leading, spacing: 6) {
            Text(need > 0 ? "needs you" : working > 0 ? "working" : "idle")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(need + working > 0 ? color : Color.secondary)
            Text("\(panes.count) \(panes.count == 1 ? "pane" : "panes") · \(working) working · \(need) need you")
                .font(.callout).foregroundStyle(.secondary)
            if let t = urgent?.title, !t.isEmpty {
                Text("“\(t)”").font(.callout).lineLimit(2).foregroundStyle(.primary.opacity(0.85))
            }
        }
    }
}

/// The state word with its dot — ◐ needs you, ● working, ○ the rest, as the Mac's sidebar tree draws it.
struct PhoneStateWord: View {
    let state: String
    var body: some View {
        let s = PhoneState(state)
        let color: Color = s == .needsYou ? .orange : s == .working ? .green : .secondary
        HStack(spacing: 5) {
            Circle().fill(s <= .working ? color : Color.clear).overlay(Circle().stroke(color, lineWidth: s <= .working ? 0 : 1)).frame(width: 7, height: 7)
            Text(state).font(.caption).foregroundStyle(s <= .working ? color : Color.secondary)
        }
    }
}

/// #11 and PR #31, as chips that open GitHub.
struct PhoneChips: View {
    let item: CompanionAPI.WorkItem
    let repo: String
    var body: some View {
        HStack(spacing: 4) {
            if let n = item.issue, let u = URL(string: "https://github.com/\(repo)/issues/\(n)") { WorkChip(text: "#\(n)") { WorkFormat.open(u) } }
            if let n = item.prNumber, let u = URL(string: "https://github.com/\(repo)/pull/\(n)") { WorkChip(text: "PR #\(n)") { WorkFormat.open(u) } }
        }
    }
}

struct PhoneLiveCard: View {
    let item: CompanionAPI.WorkItem
    let slug: String, repo: String, home: String
    let accent: Color
    @Binding var copied: String?
    let open: (PhonePaneRef) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(slug).font(.headline).lineLimit(1)
                if item.isMain {
                    Text("main").font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                Spacer(minLength: 8)
                PhoneStateWord(state: item.state)
            }
            HStack(spacing: 8) {
                Text(item.branch).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                PhoneChips(item: item, repo: repo)
            }
            if let t = item.prTitle, !t.isEmpty {
                Text(t).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            ForEach(item.panes.sorted { WorkFormat.rank($0.status) < WorkFormat.rank($1.status) }) { p in paneRow(p) }
            if let cmd = item.resumeCommand {
                Button { WorkFormat.copy(cmd); copied = item.id } label: {
                    Label(copied == item.id ? "resume command copied" : "copy resume command", systemImage: copied == item.id ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless).padding(.top, 2)
            }
        }
        .padding(14).phoneCard()
        .contextMenu {
            if let cmd = item.resumeCommand { Button("Copy resume command") { WorkFormat.copy(cmd); copied = item.id } }
            Button("Copy path") { WorkFormat.copy(item.path) }
        }
    }

    private func paneRow(_ p: CompanionAPI.Pane) -> some View {
        Button { open(PhonePaneRef(place: p.place, title: p.title, status: p.status)) } label: {
            HStack(spacing: 8) {
                Circle().fill(WorkFormat.dot(p.status, accent)).frame(width: 7, height: 7)
                Text(WorkFormat.pane(p.place, home: home)).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                Text(p.title).font(.callout).lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 6)
                if let s = p.since { Text(WorkFormat.ago(s)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.secondary.opacity(0.6)).accessibilityHidden(true)
            }
            .padding(.vertical, 6).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A resumable or cold worktree: slug, its issue and PR, age, and the way back in.
struct PhoneTreeRow: View {
    let item: CompanionAPI.WorkItem
    let slug: String
    let born: Date?
    let repo: String
    @Binding var copied: String?
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(slug).lineLimit(1).truncationMode(.middle)
                PhoneChips(item: item, repo: repo)
            }
            Spacer(minLength: 8)
            if let b = born { Text(WorkFormat.ago(b)).font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
            if let cmd = item.resumeCommand {
                Button(copied == item.id ? "copied" : "resume") { WorkFormat.copy(cmd); copied = item.id }.buttonStyle(.bordered).controlSize(.small)
            } else {
                Button(copied == item.id ? "copied" : "clean up") { WorkFormat.copy(WorkFormat.cleanCommand([item.path])); copied = item.id }
                    .buttonStyle(.bordered).controlSize(.small).tint(.secondary)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .contextMenu {
            if let cmd = item.resumeCommand { Button("Copy resume command") { WorkFormat.copy(cmd); copied = item.id } }
            else { Button("Copy cleanup command") { WorkFormat.copy(WorkFormat.cleanCommand([item.path])) } }
            Button("Copy path") { WorkFormat.copy(item.path) }
        }
    }
}

/// One herdr pane drawn as its screen, read from the Mac every 2 s: monospaced, never re-wrapped (tables and boxes keep their
/// shape), scrolls both ways, opens at the newest row. With "Allow messages" on at the Mac, a one-line composer sends to it.
struct PhonePaneScreen: View {
    let ref: PhonePaneRef
    let accent: Color
    let home: String
    @ObservedObject private var client = CompanionClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var read: Date?
    @State private var failed: String?
    @State private var follow = true            // stays on the newest row until the reader scrolls
    @AppStorage("oracle.phonePaneFont") private var fontSize = 12.0
    @State private var draft = ""
    @State private var sending = false
    @State private var note: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                screen
                footer.padding(.horizontal, 14).padding(.vertical, 7)
            }
            .background(PhoneStyle.terminalBG)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        HStack(spacing: 6) {
                            Circle().fill(WorkFormat.dot(ref.status, accent)).frame(width: 7, height: 7)
                            Text(WorkFormat.pane(ref.place, home: home)).font(.callout.monospaced().weight(.semibold))
                        }
                        if !ref.title.isEmpty { Text(ref.title).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .secondaryAction) {
                    Button { fontSize = max(8, fontSize - 1) } label: { Label("Smaller text", systemImage: "textformat.size.smaller") }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button { fontSize = min(20, fontSize + 1) } label: { Label("Bigger text", systemImage: "textformat.size.larger") }
                }
            }
            .toolbarBackground(Color(red: 0.07, green: 0.07, blue: 0.09), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
        .preferredColorScheme(.dark)
        .tint(accent)
        .phonePageSheet()
        .presentationDragIndicator(.visible)
        .task(id: ref.place) {
            text = ""; failed = nil; read = nil
            while !Task.isCancelled {
                let place = ref.place
                let s = await client.shielded { await $0.screen(place: place) }
                if Task.isCancelled { break }   // closed while it was reading: nothing to say about it
                if let s {
                    if s.text != text { text = s.text }
                    read = s.read; failed = nil
                } else { failed = PhoneFormat.why(client) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onAppear { Task { await client.refreshHello() } }   // "Allow messages" may have changed on the Mac since pairing
    }

    /// Live, or — once a read has worked and the next one does not — the screen stays and this line says since when and why.
    @ViewBuilder private var footer: some View {
        if let failed, let read {
            PhoneReadFailure(problem: failed, since: read)
        } else {
            Text(read.map { "live · every 2 s · read \($0.formatted(date: .omitted, time: .standard))" } ?? "reading…")
                .font(.caption).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var screen: some View {
        let shown = failed != nil && read == nil ? "can't read \(ref.place)\n  \(failed ?? "")" : (text.isEmpty ? " " : text)   // the problem fills the screen only while there is no screen
        return ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(shown).font(.system(size: fontSize, design: .monospaced)).foregroundStyle(PhoneStyle.terminalText)
                        .fixedSize(horizontal: true, vertical: false).textSelection(.enabled).padding(12)
                    Color.clear.frame(width: 1, height: 1).id("end")
                }
            }
            .onChange(of: text) { if follow { proxy.scrollTo("end", anchor: .bottomLeading) } }
            .onAppear { proxy.scrollTo("end", anchor: .bottomLeading) }
            .simultaneousGesture(DragGesture(minimumDistance: 10).onChanged { _ in follow = false })
            .overlay(alignment: .bottomTrailing) {
                if !follow {
                    Button { follow = true; proxy.scrollTo("end", anchor: .bottomLeading) } label: {
                        Label("newest", systemImage: "arrow.down.to.line").font(.caption.weight(.semibold))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .padding(14)
                }
            }
        }
        .background(PhoneStyle.terminalBG)
    }

    @ViewBuilder private var composer: some View {
        if let hello = client.hello {
            VStack(alignment: .leading, spacing: 5) {
                if ref.title == CompanionAPI.shellTitle {
                    Text("A shell: read-only from the phone — typing into it would run commands on the Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if hello.allowsMessages {
                    HStack(spacing: 10) {
                        TextField("Message this pane — maw herdr hey", text: $draft).textFieldStyle(.plain)
                            .font(.custom("Avenir Next", size: 15)).submitLabel(.send).onSubmit(send)
                            .textInputAutocapitalization(.never)
                        Button(action: send) {
                            Image(systemName: sending ? "ellipsis.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 26)).foregroundStyle(canSend ? accent : Color.secondary.opacity(0.4))
                        }
                        .buttonStyle(.plain).disabled(!canSend)
                        .accessibilityLabel(sending ? "Sending" : "Send message")
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.14)))
                } else {
                    Text("Read-only. To send from here: on the Mac, Settings → Companion → Allow messages.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let note { Text(note).font(.caption).foregroundStyle(note.hasPrefix("sent") ? Color.secondary : Color.orange).textSelection(.enabled) }
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }

    private var canSend: Bool { !sending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private func send() {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        sending = true; note = nil
        Task {
            let ok = await client.hey(place: ref.place, text: message)
            sending = false
            if ok { draft = ""; note = "sent to \(ref.place)" }
            else if client.reachable == false {
                // the request may have reached the pane before the answer was lost: sending again could type it twice
                note = "no answer from the Mac — it may have arrived; look at the pane above before sending again"
            }
            else { note = "not sent — " + (client.problem ?? "on the Mac: Settings → Companion → Allow messages") }
        }
    }
}

#endif
