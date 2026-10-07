#if os(iOS)
import SwiftUI
import UIKit
import RealityKit
import simd

// The phone pages of issue #46: the same pages as the Mac app — Work, Inbox, Memory, Map, Trace, Settings — drawn from
// what the Mac app serves over the companion API (CompanionClient.shared). Pull requests and issues stay on OracleStore.
// Until the phone is paired every one of these pages is one calm card, "Pair with your Mac".
// Note: Views.swift declares `enum Section`, which shadows SwiftUI's — this file says `SwiftUI.Section`.

// MARK: - Look: the ARRA Chat style of the Mac pages, on a phone

enum PhoneStyle {
    /// A pane's screen and the Map sit on the same near-black surface as the Mac's drawer.
    static let terminalBG = Color(red: 0.04, green: 0.04, blue: 0.06)
    static let terminalText = Color(white: 0.86)
    static let mapBG = Color(red: 0.03, green: 0.03, blue: 0.05)
    /// HitCard's colour on the Mac (the hub's accent) — the match bar and the score.
    static let hit = Color(hex: "#9b8cff")
    static let kinds = ["history", "note", "issue", "pr"]

    static var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }

    static func kindLabel(_ kind: String) -> String {
        switch kind { case "note": "ψ notes"; case "issue": "issues"; case "pr": "PRs"; default: "sessions" }
    }
    /// The Map's colour per kind — MapScene.color on the Mac.
    static func kindColor(_ kind: String, accent: Color) -> UIColor {
        switch kind {
        case "note": UIColor(red: 0.67, green: 0.28, blue: 0.74, alpha: 1)
        case "issue": .orange
        case "pr": UIColor(red: 0.4, green: 0.78, blue: 0.4, alpha: 1)
        default: UIColor(accent)
        }
    }
}

enum PhoneFormat {
    /// The session most panes live in: its panes are shown as "w22:p1", another session keeps its name.
    static func home(_ panes: [CompanionAPI.Pane]) -> String {
        let names = panes.compactMap { $0.place.split(separator: ":").first.map(String.init) }
        return Dictionary(grouping: names, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? ""
    }
    /// Today: the time with seconds; before: the day and the time.
    static func when(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(.dateTime.hour().minute().second())
                                          : d.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
    /// "7 Oct 22:02", and the year once it is not this year's — short enough for a phone row, whatever the calendar.
    static func stamp(_ d: Date) -> String {
        Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) ? d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
                                                                         : d.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }
    /// "21:11" today, "7 Oct 21:11" before.
    static func built(_ d: Date) -> String {
        Calendar.current.isDateInToday(d) ? d.formatted(date: .omitted, time: .shortened) : d.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
    /// The way back to the fix when a call to the Mac failed: what the client said, else the first thing to check.
    @MainActor static func why(_ client: CompanionClient) -> String {
        client.problem ?? "no answer from the Mac — on the Mac open the app, Settings → Companion, switch it on; here Settings → Companion → Pair again"
    }
}

extension CompanionClient {
    /// A call that finishes even when the view that asked is gone. A navigation push can cancel a view's `.task` while the
    /// page settles in, and a cancelled call reads as "can't reach the Mac" (CompanionClient says so) for a Mac that is fine.
    func shielded<T>(_ call: @escaping @MainActor (CompanionClient) async -> T) async -> T {
        await Task { await call(self) }.value
    }
}

extension View {
    /// A reading sheet is page-sized on the iPad (iOS 18 and later; before, the system's form sheet).
    @ViewBuilder func phonePageSheet() -> some View {
        if #available(iOS 18, *) { presentationSizing(.page) } else { self }
    }
    /// Runs when the app comes back to the front: what was true when it left may not be now.
    func onForeground(_ action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in action() }
    }
    /// The rounded card of the Mac pages: a faint fill and a hairline.
    func phoneCard(radius: CGFloat = 12, fill: Double = 0.045) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(fill)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Eyebrow, one big line, a sentence — the head of the Memory, Map and Trace pages.
struct PhoneHeader: View {
    let eyebrow: String, title: String
    var subtitle: String? = nil
    let accent: Color
    @Environment(\.horizontalSizeClass) private var sizeClass
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow).font(.caption.weight(.bold)).tracking(2.5).foregroundStyle(accent)
            Text(title).font(.custom("Avenir Next", size: sizeClass == .compact ? 30 : 34).weight(.bold)).tracking(-0.5)
                .fixedSize(horizontal: false, vertical: true)
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A segmented choice: the native control when it fits the width (iPad), a row of pills that scrolls when it does not (iPhone).
struct PhoneSegments<Tag: Hashable>: View {
    let options: [(tag: Tag, label: String)]
    @Binding var selection: Tag
    let accent: Color
    var body: some View {
        ViewThatFits(in: .horizontal) {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].label).tag(options[$0].tag) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            ScrollViewReader { proxy in   // narrower than the pills: scroll, and keep the chosen one in view
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) { ForEach(options.indices, id: \.self) { pill(options[$0]).id($0) } }
                }
                .onChange(of: selection) {
                    if let i = options.firstIndex(where: { $0.tag == selection }) { withAnimation { proxy.scrollTo(i, anchor: .center) } }
                }
            }
        }
    }
    private func pill(_ o: (tag: Tag, label: String)) -> some View {
        let on = selection == o.tag
        return Button { selection = o.tag } label: {
            Text(o.label).font(.custom("Avenir Next", size: 13.5).weight(.medium)).lineLimit(1)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .foregroundStyle(on ? accent : Color.primary.opacity(0.8))
                .background(Capsule().fill(on ? accent.opacity(0.18) : Color.primary.opacity(0.06)))
        }
        .accessibilityAddTraits(on ? .isSelected : [])   // VoiceOver says which filter is on, as the segmented control did
        .buttonStyle(.plain)
    }
}

// MARK: - Not paired, or the Mac does not answer

/// The sidebar's first footer line: where this phone's data comes from — the paired Mac, or nothing yet.
struct PhoneFooterStatus: View {
    @ObservedObject private var client = CompanionClient.shared
    var body: some View {
        let state: (color: Color, text: String) = !client.isPaired ? (.orange, "Not paired with a Mac")
            : client.refused ? (.orange, "The Mac refused this phone — pair again")
            : client.reachable == false ? (.orange, "Mac not reachable")
            : (.green, "Live from \(client.hello?.host ?? client.pairing?.host ?? "your Mac")")
        HStack(spacing: 8) {
            Circle().fill(state.color).frame(width: 8, height: 8)
            Text(state.text).font(.custom("Avenir Next", size: 13).weight(.semibold))
        }
    }
}

/// "Pair with your Mac": opens CompanionPairView (scan the Mac's code, or paste its link). The view shows the answer —
/// reaching, refused with its fix, or paired — and closes the sheet itself once paired.
struct PhonePairSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            CompanionPairView()
                .navigationTitle("Pair with your Mac").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

/// What every companion page shows before the phone is paired: what pairing gives it, where the code is, one button.
struct PhoneUnpaired: View {
    let config: OracleConfig
    let symbol: String
    let gives: String
    @State private var showPair = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Circle().fill(config.color.gradient).frame(width: 46, height: 46)
                    Image(systemName: symbol).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
                }
                .accessibilityHidden(true)   // decoration: VoiceOver would read the symbol's raw name
                Text("Pair with your Mac").font(.custom("Avenir Next", size: 26).weight(.bold)).tracking(-0.4)
                Text(gives).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("WHERE THE CODE IS").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(config.color)
                    Text("On the Mac, open \(config.name) → Settings → Companion, switch it on, and scan its code here — or paste its link.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
                Button { showPair = true } label: {
                    Label("Pair with your Mac", systemImage: "qrcode.viewfinder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).tint(config.color).padding(.top, 4)
            }
            .padding(20).phoneCard(radius: 16)
            .frame(maxWidth: 520)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showPair) { PhonePairSheet() }
    }
}

/// The Mac did not answer: what the client said (it ends with the fix), and a way to try again.
struct PhoneProblemCard: View {
    let text: String
    var retry: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Can't read from the Mac", systemImage: "exclamationmark.triangle").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text(text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let retry { Button("Try again", action: retry).buttonStyle(.bordered).controlSize(.small) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
    }
}

/// A read that failed, as a page shows it. While the page has nothing to show: the card, with its way to try again. Once it
/// holds data (`since` is when a read last worked): the data stays and one quiet line says since when it is stale, and why.
struct PhoneReadFailure: View {
    let problem: String
    let since: Date?
    var retry: (() -> Void)? = nil
    var body: some View {
        if let since {
            Label { Text("not updated since \(PhoneFormat.built(since)) — \(problem)").textSelection(.enabled) }
                icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            PhoneProblemCard(text: problem, retry: retry)
        }
    }
}

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

// MARK: - Inbox: the Mac's ψ/inbox, newest first, a file opens as text

struct PhoneInboxView: View {
    @ObservedObject var store: OracleStore
    @ObservedObject private var client = CompanionClient.shared
    @State private var inbox: CompanionAPI.Inbox?
    @State private var failed: String?
    @State private var readAt: Date?             // when a read last worked: a failing one keeps the list and says since when
    @State private var show = 0                  // All · Unread · Read
    @State private var openEntry: CompanionAPI.InboxEntry?
    @State private var reading = false
    private static var actionDone = false
    private var c: OracleConfig { store.config }

    var body: some View {
        Group {
            if client.isPaired { page } else {
                PhoneUnpaired(config: c, symbol: "tray",
                              gives: "The files and notes in \(c.name)'s ψ/inbox on your Mac — handoffs, drops, links — newest first, to read here.")
            }
        }
        .navigationTitle("Inbox")
    }

    /// The Mac says unread and this phone has not opened it since it changed — what the sidebar badge and the widget count.
    private func unread(_ e: CompanionAPI.InboxEntry) -> Bool { e.unread && !store.hasRead(path: e.path, modified: e.modified) }

    private var page: some View {
        let all = inbox?.items ?? []
        let unreadCount = all.filter(unread).count
        let rows: [CompanionAPI.InboxEntry] = show == 1 ? all.filter(unread) : show == 2 ? all.filter { !unread($0) } : all
        return List {
            VStack(alignment: .leading, spacing: 10) {
                PhoneSegments(options: [(0, "All \(all.count)"), (1, "Unread \(unreadCount)"), (2, "Read \(all.count - unreadCount)")],
                              selection: $show, accent: c.color)
                if let failed { PhoneReadFailure(problem: failed, since: readAt) { Task { await load() } } }
            }
            .listRowSeparator(.hidden).listRowBackground(Color.clear)
            ForEach(rows) { e in
                Button { openEntry = e } label: { row(e) }.buttonStyle(.plain)
            }
        }
        .listStyle(.plain)
        .sheet(item: $openEntry) { e in
            NavigationStack { PhoneInboxFile(entry: e, accent: c.color) }.phonePageSheet().tint(c.color)
                .onAppear { store.markRead(InboxItem(path: e.path, name: e.name, folder: e.folder, modified: e.modified)) }
        }
        .overlay {
            if inbox == nil && failed == nil { ProgressView() }
            else if inbox != nil && rows.isEmpty {
                Text(show == 1 ? "Nothing unread." : show == 2 ? "Nothing read yet." : "Inbox is empty on the Mac.").foregroundStyle(.secondary)
            }
        }
        .refreshable { await load() }
        .onAppear { Task { await load() } }
        .onForeground { Task { await load() } }
        .onChange(of: client.pairing) { inbox = nil; readAt = nil; Task { await load() } }
        .onChange(of: client.reachable) { _, now in if now == true, failed != nil { Task { await load() } } }
        .onReceive(NotificationCenter.default.publisher(for: .oraclePhoneReload)) { _ in Task { await load() } }
    }

    private func row(_ e: CompanionAPI.InboxEntry) -> some View {
        let u = unread(e)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(u ? c.color : .clear)
                .overlay(Circle().stroke(u ? .clear : Color.secondary.opacity(0.35), lineWidth: 1))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(e.name).font(u ? .body.weight(.semibold) : .body).foregroundStyle(u ? .primary : .secondary).lineLimit(2)
                Text("\(u ? "unread" : "read") · \(e.folder) · \(PhoneFormat.stamp(e.modified))")
                    .font(.caption).foregroundStyle(u ? AnyShapeStyle(c.color) : AnyShapeStyle(.tertiary))
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        if reading { return }
        reading = true; defer { reading = false }
        if let i = await client.shielded({ await $0.inbox() }) { inbox = i; readAt = Date(); failed = nil } else { failed = PhoneFormat.why(client) }
        if !Self.actionDone, let n = UserDefaults.standard.string(forKey: "inboxOpen").flatMap(Int.init), let items = inbox?.items, n < items.count {   // -inboxOpen <n> (tests)
            Self.actionDone = true
            openEntry = items[n]
        }
    }
}

/// One inbox file as text, in a sheet: a Markdown file with its inline styling (bold, code, links) and the lines kept as
/// written; plain monospaced when it does not parse, or is not Markdown. Only the head of a long file is laid out — one Text
/// draws its whole string at once, and the Mac serves up to 512 KB — with a line saying the rest is on the Mac.
struct PhoneInboxFile: View {
    let entry: CompanionAPI.InboxEntry
    let accent: Color
    @ObservedObject private var client = CompanionClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var file: CompanionAPI.InboxFile?   // its text is what is shown: the head of the file, at most `limit` bytes
    @State private var fullSize: Int?                   // the file's size in bytes, when only its head is shown
    @State private var rendered: AttributedString?
    @State private var failed: String?
    static let limit = 64 * 1024

    /// The head of a text that the page lays out: at most `limit` bytes, ending at a line (a line longer than that is cut at a
    /// character instead). nil when the whole text fits.
    static func head(of text: String, limit: Int = PhoneInboxFile.limit) -> String? {
        let bytes = Array(text.utf8)
        guard bytes.count > limit + limit / 8 else { return nil }   // a file just over 64 KB shows whole, never "64 KB of 64 KB"
        var end = limit
        if let newline = bytes[..<limit].lastIndex(of: 10), newline > limit / 2 { end = bytes[newline - 1] == 13 ? newline - 1 : newline }   // a CRLF goes whole
        else { while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 } }   // not inside a character
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
    private static func kb(_ bytes: Int) -> String { "\((bytes + 512) / 1024) KB" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.name).font(.custom("Avenir Next", size: 22).weight(.bold)).fixedSize(horizontal: false, vertical: true)
                Text("\(entry.folder) · \(PhoneFormat.stamp(file?.modified ?? entry.modified))")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                if let rendered {
                    Text(rendered).font(.callout).textSelection(.enabled).tint(accent)
                } else if let file {
                    Text(file.text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                } else if let failed {
                    PhoneProblemCard(text: failed) { Task { await load() } }
                } else {
                    ProgressView()
                }
                if let file, let fullSize {
                    Divider()
                    Text("Showing the first \(Self.kb(file.text.utf8.count)) of \(Self.kb(fullSize)) — the rest is on the Mac, in ψ/inbox/\(entry.path)")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Inbox").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .task { await load() }
    }

    private func load() async {
        let path = entry.path
        guard let f = await client.shielded({ await $0.inboxFile(path: path) }) else { failed = PhoneFormat.why(client); return }
        let head = Self.head(of: f.text)
        let text = head ?? f.text   // what is laid out, as plain text and as Markdown alike
        fullSize = head == nil ? nil : f.text.utf8.count
        file = head == nil ? f : CompanionAPI.InboxFile(path: f.path, text: text, modified: f.modified)
        failed = nil
        guard ["md", "markdown", "mdx", ""].contains((entry.name as NSString).pathExtension.lowercased()) else { return }   // a csv or a log stays as written
        rendered = await Task.detached(priority: .userInitiated) {
            try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        }.value
    }
}

// MARK: - Memory: the search half of the Mac's Memory page, the Mac does the searching

struct PhoneMemoryView: View {
    @ObservedObject var store: OracleStore
    @ObservedObject private var client = CompanionClient.shared
    @State private var query = ""
    @State private var who = "all"                // all · you · oracle · notes · gh
    @State private var found: CompanionAPI.Search?
    @State private var status: CompanionAPI.MemoryStatus?
    @State private var statusRead: Date?          // when the status last read: a failing read keeps it and says since when
    @State private var statusFailed: String?
    @State private var searching = false
    @State private var failed: String?
    @State private var copied: String?
    @State private var asked = 0                  // the newest search wins; an older answer is dropped
    @FocusState private var focused: Bool
    @Environment(\.openURL) private var openURL
    private static var actionDone = false
    private var c: OracleConfig { store.config }

    var body: some View {
        Group {
            if client.isPaired { page } else {
                PhoneUnpaired(config: c, symbol: "brain",
                              gives: "Ask \(c.name)'s past by meaning — its sessions, ψ notes, issues and PRs. Your Mac runs the search; the answers come here.")
            }
        }
        .navigationTitle("Memory")
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PhoneHeader(eyebrow: "SEMANTIC MEMORY", title: "\(c.name)'s memory",
                            subtitle: "Every session, ψ note, issue and PR of \(c.repoSlug) — what you asked, what \(c.name) answered and wrote down, ready for meaning.",
                            accent: c.color)
                statusLine
                if let statusFailed, failed == nil { PhoneReadFailure(problem: statusFailed, since: statusRead) { Task { await readStatus() } } }
                searchField
                PhoneSegments(options: [("all", "All"), ("you", "You"), ("oracle", c.name), ("notes", "ψ notes"), ("gh", "Issues & PRs")],
                              selection: $who, accent: c.color)
                    .onChange(of: who) { if !query.trimmingCharacters(in: .whitespaces).isEmpty { Task { await search() } } }
                if let failed { PhoneProblemCard(text: failed) { Task { await search() } } }
                if let f = found {
                    Text("\(f.hits.count) \(f.hits.count == 1 ? "result" : "results") · \(String(format: "%.0f + %.1f ms", f.embedMs, f.rankMs)) · \(grouped(f.pool)) ranked — a session result copies the command that reopens it")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(found?.hits ?? []) { h in
                        PhoneHitCard(hit: h, oracleName: c.name, copied: copied == h.id) { open(h) }
                    }
                }
                if let f = found, f.hits.isEmpty, failed == nil, !searching {
                    Text(status?.items == 0 ? "nothing embedded yet — on the Mac: \(c.name) → Memory → Scan, then Run batch"
                                            : "nothing close to that — try other words")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await readStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .oraclePhoneReload)) { _ in Task { await readStatus() } }
        .onAppear { Task { await start() } }
        .onChange(of: client.pairing) { status = nil; statusRead = nil; statusFailed = nil; Task { await start() } }
        .onChange(of: client.reachable) { _, now in if now == true, statusFailed != nil { Task { await start() } } }
    }

    private func readStatus() async {
        if let s = await client.shielded({ await $0.status() }) { status = s; statusRead = Date(); statusFailed = nil }
        else { statusFailed = PhoneFormat.why(client) }
    }

    private func start() async {
        await readStatus()
        if !Self.actionDone, let q = UserDefaults.standard.string(forKey: "memoryQuery"), !q.isEmpty {   // -memoryQuery <text> (tests)
            Self.actionDone = true
            query = q; await search()
        }
    }

    /// What the Mac holds: items, sessions, when it was built.
    @ViewBuilder private var statusLine: some View {
        if let s = status {
            Text("\(grouped(s.items)) items · \(grouped(s.sessions)) sessions" + (s.built.map { " · built \(PhoneFormat.built($0))" } ?? ""))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField("Ask \(c.name)'s past — what did we decide about…", text: $query)
                .textFieldStyle(.plain).font(.custom("Avenir Next", size: 17)).focused($focused)
                .submitLabel(.search).textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { Task { await search() } }
            if searching { ProgressView().controlSize(.small) }
            else if !query.isEmpty {
                Button { query = ""; found = nil; failed = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? c.color : Color.primary.opacity(0.1), lineWidth: focused ? 1.5 : 1))
        .shadow(color: focused ? c.color.opacity(0.45) : .clear, radius: 14)
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { found = nil; return }
        asked += 1; let mine = asked
        searching = true; failed = nil
        let answer = await client.search(q, kind: who)   // "gh": issues and PRs in one query, as the Mac's Memory page asks
        guard mine == asked else { return }
        searching = false
        if let answer {
            found = answer
            if statusFailed != nil { await readStatus() }   // the Mac just answered: the status banner follows the latest evidence
        } else { failed = PhoneFormat.why(client) }
    }

    /// A session copies the command that reopens it; a note, issue or PR opens its link when it is a web link.
    private func open(_ h: CompanionAPI.SearchHit) {
        if h.kind == "history" { WorkFormat.copy(h.url); flash(h.id) }
        else if let u = URL(string: h.url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") { openURL(u) }
        else { WorkFormat.copy(URL(string: h.url)?.path ?? h.url); flash(h.id) }   // a note's file lives on the Mac: its path
    }
    private func flash(_ id: String) {
        copied = id
        Task { try? await Task.sleep(for: .seconds(1.8)); if copied == id { copied = nil } }
    }
}

/// One result, as the Mac's HitCard draws it: the match, what it is, when, the title, a glowing bar, the snippet.
struct PhoneHitCard: View {
    let hit: CompanionAPI.SearchHit
    let oracleName: String
    let copied: Bool
    let action: () -> Void
    private var label: String {
        hit.kind == "pr" ? "PR" : hit.kind == "note" ? "ψ note" : hit.kind == "history" ? (hit.state == "user" ? "you" : oracleName) : "issue"
    }
    private var meta: String {
        switch hit.kind {
        case "note": return "\(hit.repo) · ψ/\(hit.state)\(hit.number > 0 ? " · part \(hit.number + 1)" : "")"
        case "history": return copied ? "command copied ✓" : "session · \(String(hit.updated.dropFirst(11).prefix(5)))"
        default: return "\(hit.repo)#\(hit.number)"
        }
    }
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(String(format: "%.0f%%", max(0, Double(hit.score)) * 100)).font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(PhoneStyle.hit).frame(width: 40, alignment: .leading)
                    Text(label).font(.caption2.weight(.semibold)).lineLimit(1)
                        .padding(.horizontal, 6).padding(.vertical, 2).background(Capsule().fill(Color.primary.opacity(0.08)))
                    Text(hit.kind == "note" || hit.kind == "history" ? String(hit.updated.prefix(10)) : hit.state.lowercased())
                        .font(.caption2).foregroundStyle(hit.state == "OPEN" ? Color.green : Color.secondary).lineLimit(1)
                    Text(meta).font(.caption.monospaced()).foregroundStyle(copied ? PhoneStyle.hit : Color.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                Text(hit.title).font(.custom("Avenir Next", size: 15).weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                GeometryReader { g in   // the match, as a glowing bar
                    let w = g.size.width * CGFloat(max(0, min(1, (hit.score - 0.4) / 0.5)))
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule().fill(LinearGradient(colors: [PhoneStyle.hit.opacity(0.5), PhoneStyle.hit], startPoint: .leading, endPoint: .trailing))
                            .frame(width: w).shadow(color: PhoneStyle.hit.opacity(0.7), radius: 6)
                    }
                }
                .frame(height: 3)
                if !hit.snippet.isEmpty { Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading).phoneCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Trace: every query asked of the Mac's memory, newest first

struct PhoneTraceView: View {
    @ObservedObject var store: OracleStore
    @ObservedObject private var client = CompanionClient.shared
    @State private var trace: CompanionAPI.Trace?
    @State private var failed: String?
    @State private var readAt: Date?             // when a read last worked: a failing one keeps the list and says since when
    @State private var who = "all"               // all · mcp · page · companion
    @State private var open: UUID?
    @State private var reading = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var c: OracleConfig { store.config }
    private var narrow: Bool { sizeClass == .compact }

    var body: some View {
        Group {
            if client.isPaired { page } else {
                PhoneUnpaired(config: c, symbol: "list.bullet.rectangle",
                              gives: "Every query asked of \(c.name)'s memory — from its pages, over MCP and from phones — who asked, and what came back first.")
            }
        }
        .navigationTitle("Trace")
    }

    /// Who asked, as a row shows it: the caller the Mac measured, else "you" on a page.
    static func from(_ e: TraceLog.Entry) -> String { e.caller ?? (e.source == "mcp" ? "caller not recorded" : "you") }
    private func tint(_ e: TraceLog.Entry) -> Color { e.source == "mcp" ? .orange : e.source == "page" ? c.color : .cyan }

    private var page: some View {
        let all: [TraceLog.Entry] = (trace?.entries ?? []).reversed()
        let sources = ["page", "mcp", "companion"].filter { s in all.contains { $0.source == s } }
        let rows = who == "all" ? all : all.filter { $0.source == who }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                PhoneHeader(eyebrow: "TRACE", title: c.name.hasSuffix("s") ? "\(c.name)' trace" : "\(c.name)'s trace",
                            subtitle: "Every query asked of \(c.name)'s memory — from its pages, over MCP and from phones — who asked, and what came back first.",
                            accent: c.color)
                    .padding(.bottom, 6)
                if sources.count > 1 {
                    PhoneSegments(options: [("all", "All")] + sources.map { ($0, $0 == "mcp" ? "MCP" : $0.capitalized) }, selection: $who, accent: c.color)
                }
                Text("\(grouped(rows.count)) of \(all.count >= 200 ? "the newest " : "")\(grouped(all.count)) queries")   // client.trace reads 200
                    .font(.caption).foregroundStyle(.secondary)
                if let failed { PhoneReadFailure(problem: failed, since: readAt) { Task { await load() } } }
                if trace != nil && all.isEmpty && failed == nil {
                    Text("no query yet — search the Memory page, or ask over MCP").font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                }
                ForEach(rows) { e in row(e) }
            }
            .padding(.horizontal, narrow ? 18 : 28).padding(.vertical, 18)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay { if trace == nil && failed == nil { ProgressView() } }
        .refreshable { await load() }
        .onAppear { Task { await load() } }
        .onForeground { Task { await load() } }
        .onChange(of: client.pairing) { trace = nil; readAt = nil; Task { await load() } }
        .onChange(of: client.reachable) { _, now in if now == true, failed != nil { Task { await load() } } }
        .onReceive(NotificationCenter.default.publisher(for: .oraclePhoneReload)) { _ in Task { await load() } }
    }

    /// The same row as the Mac's TraceView: when, PAGE · MCP · COMPANION, the query, who asked, the best hit; a tap shows them all.
    private func row(_ e: TraceLog.Entry) -> some View {
        let cost = narrow ? String(format: "%.0f ms", e.embedMs + e.rankMs) : String(format: "%.0f + %.1f ms · %@ ranked", e.embedMs, e.rankMs, grouped(e.pool))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 10) {
                Text(PhoneFormat.when(e.at)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                Text(e.source.uppercased()).foregroundStyle(tint(e)).lineLimit(1).fixedSize()
                if !narrow { Text("\"\(e.query)\"").lineLimit(1).truncationMode(.tail) }
                Spacer(minLength: 0)
                Text(cost).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            }
            if narrow { Text("\"\(e.query)\"").lineLimit(open == e.id ? 4 : 2).truncationMode(.tail) }
            Text("   " + Self.from(e)).foregroundStyle(tint(e).opacity(0.9)).lineLimit(1)
            if open == e.id {
                Text("   \(e.filter) · \(grouped(e.pool)) ranked · \(e.via) · \(e.index)").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(Array(e.top.enumerated()), id: \.offset) { i, h in
                    Text(String(format: "   %d. %.0f%%  %@", i + 1, Double(h.score) * 100, h.title)).lineLimit(2)
                }
            } else if let top = e.top.first {
                Text(String(format: "   best %.0f%% · %@", Double(top.score) * 100, top.title)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.system(size: narrow ? 11 : 12, design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(open == e.id ? 0.08 : 0.03)))
        .contentShape(Rectangle())
        .onTapGesture { open = open == e.id ? nil : e.id }
    }

    private func load() async {
        if reading { return }
        reading = true; defer { reading = false }
        if let t = await client.shielded({ await $0.trace() }) { trace = t; readAt = Date(); failed = nil } else { failed = PhoneFormat.why(client) }
    }
}

// MARK: - Settings: the pairing, and the GitHub token for when no Mac is paired

struct PhoneSettingsView: View {
    @ObservedObject var store: OracleStore
    @State private var token = TokenStore.read() ?? ""
    @State private var saved = false
    var body: some View {
        Form {
            CompanionSettingsSection()
            SwiftUI.Section {
                SecureField("ghp_… or github_pat_…", text: $token).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit(save)
                Button(saved ? "Saved ✓" : "Save token", action: save).disabled(token == (TokenStore.read() ?? ""))
            } header: {
                Text("GitHub token (read-only is enough)")
            } footer: {
                Text("Kept in this \(PhoneStyle.device)'s Keychain. Used only to read PRs and issues when no Mac is paired.")
            }
            SwiftUI.Section("About") {
                LabeledContent("App", value: "\(store.config.name) Oracle")
                LabeledContent("Repo", value: store.config.repoSlug)
                LabeledContent("Build", value: AppVersion.calver)
            }
        }
        .navigationTitle("Settings")
    }

    private func save() {
        TokenStore.write(token); saved = true
        Task { await store.refresh(); try? await Task.sleep(for: .seconds(1.5)); saved = false }
    }
}

/// The toolbar gear: the same Settings page, in a sheet.
struct PhoneSettingsSheet: View {
    @ObservedObject var store: OracleStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            PhoneSettingsView(store: store)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - Map: the memory as one space — RealityKit on iOS 26, a flat scatter everywhere else

/// The Map as the Mac laid it out, unpacked. Positions are centred on the cloud and scaled so 80 % of the points lie within
/// 0.45 (MapFrame), then strays are pulled onto a shell at 0.8: the camera frames the body of the cloud, not three strays.
/// Picking and drawing use these.
struct PhoneMapModel: Sendable {
    /// Which map this is: copies of a model share it, a model made from a new answer of the Mac has its own. A scene built
    /// from one map compares it to know when the page holds another (its picks are rows of the map it was built from).
    let stamp = UUID()
    let ids: [String], kinds: [String], titles: [String]
    let xyz: [SIMD3<Float>]
    let knn: [Int32]
    let k: Int
    let labels: [Int]
    let groups: [CompanionAPI.MapGroup]
    /// The rows the Map draws, per kind. A row of any other kind is not here: the Mac sends kind "" (and the id as its title) for
    /// a point whose doc left the index since the layout was made — no colour, no legend key, nothing to say. It is never
    /// drawn, picked, or listed among a point's neighbours.
    let rowsOfKind: [String: [Int]]
    var count: Int { ids.count }
    /// How many rows are drawn: what the legend adds up to.
    let drawnCount: Int

    /// nil when the arrays disagree about how many points there are.
    init?(_ d: CompanionAPI.MapData) {
        let n = d.ids.count
        guard n > 0, d.kinds.count == n, d.titles.count == n, d.xyz.count == n * 12, d.k >= 0, d.k <= d.knn.count / (n * 4),
              d.knn.count == n * d.k * 4 else { return nil }
        ids = d.ids; kinds = d.kinds; titles = d.titles; k = d.k; groups = d.groups
        labels = d.labels.count == n ? d.labels : []
        let laid = d.xyz.withUnsafeBytes { raw in
            (0..<n).map { i in SIMD3<Float>(raw.loadUnaligned(fromByteOffset: i * 12, as: Float.self),
                                            raw.loadUnaligned(fromByteOffset: i * 12 + 4, as: Float.self),
                                            raw.loadUnaligned(fromByteOffset: i * 12 + 8, as: Float.self)) }
        }
        let frame = MapFrame.fit(laid, drawn: d.kinds.map { PhoneStyle.kinds.contains($0) })
        xyz = laid.map { p in
            let q = (p - frame.centre) * frame.scale, r = simd_length(q)
            return r > 0.8 ? q * (0.8 / r) : q
        }
        let kk = d.k
        knn = d.knn.withUnsafeBytes { raw in (0..<(n * kk)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Int32.self) } }
        var by: [String: [Int]] = [:]
        for (i, kind) in d.kinds.enumerated() where PhoneStyle.kinds.contains(kind) { by[kind, default: []].append(i) }
        rowsOfKind = by
        drawnCount = by.values.reduce(0) { $0 + $1.count }
    }

    /// A row that is on the map: in range, and of a kind the Map draws.
    func isDrawn(_ row: Int) -> Bool { row >= 0 && row < kinds.count && PhoneStyle.kinds.contains(kinds[row]) }

    /// The nearest neighbours of a row, closest first (the Mac's kNN graph).
    func neighbours(of row: Int) -> [Int] {
        guard k > 0, row >= 0, (row + 1) * k <= knn.count else { return [] }
        return knn[(row * k)..<(row * k + k)].compactMap { $0 >= 0 && isDrawn(Int($0)) ? Int($0) : nil }
    }
    func group(of row: Int) -> CompanionAPI.MapGroup? {
        guard row >= 0, row < labels.count else { return nil }
        return groups.first { $0.id == labels[row] }
    }
}

/// What the id of a doc says (IndexDoc.id): "owner/repo#12" is an issue or PR, "note:file:///…/ψ/inbox/a.md#1" a note's piece,
/// "hist:<hash>" a piece of a session. The Map carries no more than that, so this is all its panel can show.
enum PhoneMapDoc {
    static func issue(_ id: String) -> (repo: String, number: Int)? {
        guard let h = id.lastIndex(of: "#"), let n = Int(id[id.index(after: h)...]) else { return nil }
        return (String(id[..<h]), n)
    }
    static func url(kind: String, id: String) -> URL? {
        guard kind == "issue" || kind == "pr", let i = issue(id) else { return nil }
        return URL(string: "https://github.com/\(i.repo)/\(kind == "pr" ? "pull" : "issues")/\(i.number)")
    }
    /// "ψ/inbox/a.md" and its part, from a note's id.
    static func note(_ id: String) -> (path: String, part: Int?) {
        var s = id.hasPrefix("note:") ? String(id.dropFirst(5)) : id
        var part: Int?
        if let h = s.lastIndex(of: "#"), let n = Int(s[s.index(after: h)...]) { part = n; s = String(s[..<h]) }
        let path = URL(string: s)?.path ?? s
        if let r = path.range(of: "/ψ/") { return ("ψ/" + path[r.upperBound...], part) }
        return (path.split(separator: "/").suffix(2).joined(separator: "/"), part)
    }
    static func meta(kind: String, id: String) -> String {
        switch kind {
        case "issue", "pr": return "\(kind) \(id)"
        case "note": let n = note(id); return n.path + (n.part.map { " · part \($0 + 1)" } ?? "")
        default: return "a piece of a session"
        }
    }
}

/// The flat Map: every point at its (x, y). Pinch to zoom, drag to pan, tap for the nearest point.
struct PhoneMapCanvas: View {
    let model: PhoneMapModel
    let accent: Color
    let hidden: Set<String>
    @Binding var selected: Int?
    let resetTick: Int
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var pinching: CGFloat = 1
    @GestureState private var dragging: CGSize = .zero

    /// map space → screen: the map's [-0.8, 0.8] fits the short side at zoom 1.
    private struct Space {
        let cx: CGFloat, cy: CGFloat, scale: CGFloat
        func point(_ p: SIMD3<Float>) -> CGPoint { CGPoint(x: cx + CGFloat(p.x) * scale, y: cy - CGFloat(p.y) * scale) }
    }
    private func space(_ size: CGSize) -> Space {
        let z = max(0.4, min(80, zoom * pinching))
        return Space(cx: size.width / 2 + pan.width + dragging.width, cy: size.height / 2 + pan.height + dragging.height,
                     scale: min(size.width, size.height) / 1.7 * z)
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                let sp = space(size)
                let r = max(1.2, min(3.4, 1.0 + log2(Double(max(1, zoom * pinching))) * 0.5))   // a dot grows a little as you zoom in
                for kind in PhoneStyle.kinds where !hidden.contains(kind) {
                    var path = Path()
                    for i in model.rowsOfKind[kind] ?? [] {
                        let q = sp.point(model.xyz[i])
                        if q.x < -4 || q.y < -4 || q.x > size.width + 4 || q.y > size.height + 4 { continue }
                        path.addRect(CGRect(x: q.x - r, y: q.y - r, width: 2 * r, height: 2 * r))
                    }
                    ctx.fill(path, with: .color(Color(PhoneStyle.kindColor(kind, accent: accent)).opacity(0.85)))
                }
                if let s = selected, model.isDrawn(s) {
                    let from = sp.point(model.xyz[s])
                    let nbrs = model.neighbours(of: s)
                    var lines = Path()
                    for n in nbrs { lines.move(to: from); lines.addLine(to: sp.point(model.xyz[n])) }
                    ctx.stroke(lines, with: .color(accent.opacity(0.85)), lineWidth: 1)
                    for n in nbrs {
                        let q = sp.point(model.xyz[n])
                        ctx.fill(Path(ellipseIn: CGRect(x: q.x - 3.5, y: q.y - 3.5, width: 7, height: 7)), with: .color(accent))
                    }
                    ctx.fill(Path(ellipseIn: CGRect(x: from.x - 5, y: from.y - 5, width: 10, height: 10)), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: CGRect(x: from.x - 9, y: from.y - 9, width: 18, height: 18)), with: .color(.white.opacity(0.7)), lineWidth: 1.5)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { selected = nearest(to: $0, size: geo.size) }
            .gesture(DragGesture(minimumDistance: 6)
                .updating($dragging) { v, state, _ in state = v.translation }
                .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height })
            .simultaneousGesture(MagnifyGesture()
                .updating($pinching) { v, state, _ in state = v.magnification }
                .onEnded { v in zoom = max(0.4, min(80, zoom * v.magnification)) })
        }
        .onChange(of: resetTick) { zoom = 1; pan = .zero }
    }

    /// The nearest visible point within a fingertip of the tap; nil on empty space (which clears the selection).
    private func nearest(to p: CGPoint, size: CGSize) -> Int? {
        let sp = space(size)
        var best = -1, bd = CGFloat.infinity
        for kind in PhoneStyle.kinds where !hidden.contains(kind) {
            for i in model.rowsOfKind[kind] ?? [] {
                let q = sp.point(model.xyz[i])
                let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
                if d < bd { bd = d; best = i }
            }
        }
        return best >= 0 && bd < 26 * 26 ? best : nil
    }
}

/// The RealityKit side of the Map (iOS 26: instanced dots): one instanced mesh per kind and chunk, the selection drawn as a
/// larger point with its neighbours and lines to them, picking on the CPU by projecting every point (pixelCast never sees instances).
@available(iOS 26, *)
@MainActor
final class PhoneMapScene {
    private let root = Entity()
    private var chunks: [(kind: String, entity: ModelEntity, rows: [Int])] = []
    private var glow: [Entity] = []
    private var content: RealityViewCameraContent?
    private var model: PhoneMapModel?
    private var accent: Color = .blue
    private var selectedRow: Int?
    /// How far the camera stands from the middle of the map: at zoom 1 the body of the cloud fills a portrait iPhone's width.
    static let distance: Float = 4.6
    /// Instances per mesh. The iOS simulator drew none of an entity with 512 instances or more (32 KB of transforms) and
    /// all of one with 384, so a chunk is 256; -mapChunk <n> (tests) tries another.
    static let chunk = max(16, UserDefaults.standard.integer(forKey: "mapChunk") == 0 ? 256 : UserDefaults.standard.integer(forKey: "mapChunk"))
    static let scale: Float = 3.2

    /// The map this scene shows (nil until it is built).
    var stamp: UUID? { model?.stamp }

    /// false when RealityKit would not make the instanced dots here — the page then shows the flat map.
    func build(into content: inout RealityViewCameraContent, model: PhoneMapModel, accent: Color) -> Bool {
        root.scale = SIMD3(repeating: Self.scale)
        guard fill(model: model, accent: accent) else { return false }
        content.add(root)
        let camera = PerspectiveCamera()
        camera.position = [0, 0, Self.distance]
        content.add(camera)
        self.content = content
        return true
    }

    /// The dots of a map under `root`: one instanced mesh per kind and chunk. false when there is none.
    private func fill(model: PhoneMapModel, accent: Color) -> Bool {
        self.model = model; self.accent = accent
        let sphere = Self.dot(radius: 0.0046)
        var made = 0
        for kind in PhoneStyle.kinds {
            let mat = UnlitMaterial(color: PhoneStyle.kindColor(kind, accent: accent))   // the colour as it is, no lighting
            let rows = model.rowsOfKind[kind] ?? []
            for start in stride(from: 0, to: rows.count, by: Self.chunk) {
                let slice = Array(rows[start..<min(start + Self.chunk, rows.count)])
                if let e = Self.instanced(slice, xyz: model.xyz, mesh: sphere, material: mat) { chunks.append((kind, e, slice)); root.addChild(e); made += 1 }
            }
        }
        return made > 0
    }

    /// Another map in this same scene (the Mac laid the memory out again): the old dots and the selection go, the new dots
    /// come, the camera and the turn stay. Never a second RealityView beside this one, not even for the moment of the swap:
    /// two of them held two sets of render targets and the iPad simulator ran out of drawables ("nextDrawable returning nil
    /// because allocation failed"), after which every frame took a second and the render thread then crashed.
    /// false when RealityKit made no dots for it — the page then shows the flat map.
    func replace(model: PhoneMapModel, accent: Color) -> Bool {
        guard content != nil else { return true }   // build() has not run: it takes the model it is given
        glow.forEach { $0.removeFromParent() }; glow = []
        chunks.forEach { $0.entity.removeFromParent() }; chunks = []
        selectedRow = nil
        return fill(model: model, accent: accent)
    }

    /// The map as the fingers left it: turned, and scaled between a third and 6× (the camera never moves, so the cloud
    /// cannot be lost behind it — the orbit control's own pinch has no stop).
    func pose(turn: simd_quatf, zoom: Float) {
        root.orientation = turn
        root.scale = SIMD3(repeating: Self.scale * min(6, max(0.3, zoom)))
    }

    /// A point: a 20-triangle icosahedron. An instanced sphere costs hundreds of triangles a point and a point is a few
    /// pixels — a phone draws tens of thousands of them.
    static func dot(radius: Float) -> MeshResource {
        let t = (1 + Float(5).squareRoot()) / 2
        let corners: [SIMD3<Float>] = [[-1, t, 0], [1, t, 0], [-1, -t, 0], [1, -t, 0], [0, -1, t], [0, 1, t],
                                       [0, -1, -t], [0, 1, -t], [t, 0, -1], [t, 0, 1], [-t, 0, -1], [-t, 0, 1]].map { simd_normalize($0) }
        let faces: [UInt32] = [0, 11, 5, 0, 5, 1, 0, 1, 7, 0, 7, 10, 0, 10, 11, 1, 5, 9, 5, 11, 4, 11, 10, 2, 10, 7, 6, 7, 1, 8,
                               3, 9, 4, 3, 4, 2, 3, 2, 6, 3, 6, 8, 3, 8, 9, 4, 9, 5, 2, 4, 11, 6, 2, 10, 8, 6, 7, 9, 8, 1]
        var d = MeshDescriptor(name: "dot")
        d.positions = MeshBuffers.Positions(corners.map { $0 * radius })
        d.normals = MeshBuffers.Normals(corners)
        d.primitives = .triangles(faces)
        return (try? MeshResource.generate(from: [d])) ?? MeshResource.generateSphere(radius: radius)
    }

    static func instanced(_ rows: [Int], xyz: [SIMD3<Float>], mesh: MeshResource, material: RealityKit.Material) -> ModelEntity? {
        guard !rows.isEmpty, let data = try? LowLevelInstanceData(instanceCount: rows.count) else { return nil }
        data.replaceMutableTransforms { buf in for (i, r) in rows.enumerated() { buf[i] = Transform(translation: xyz[r]).matrix } }
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for r in rows { lo = min(lo, xyz[r]); hi = max(hi, xyz[r]) }
        guard let inst = try? MeshInstancesComponent(mesh: mesh, instances: data, bounds: BoundingBox(min: lo - 0.01, max: hi + 0.01)) else { return nil }
        let e = ModelEntity(mesh: mesh, materials: [material])
        e.components.set(inst)
        return e
    }

    /// A kind switched off in the legend: its chunks are disabled, nothing is rebuilt.
    func show(hidden: Set<String>) { for c in chunks { c.entity.isEnabled = !hidden.contains(c.kind) } }

    func select(_ row: Int?) {
        guard row != selectedRow else { return }
        selectedRow = row
        glow.forEach { $0.removeFromParent() }; glow = []
        guard let row, let model, model.isDrawn(row) else { return }
        let nbrs = model.neighbours(of: row)
        if let e = Self.instanced([row], xyz: model.xyz, mesh: Self.dot(radius: 0.0095), material: UnlitMaterial(color: .white)) { root.addChild(e); glow.append(e) }
        if let e = Self.instanced(nbrs, xyz: model.xyz, mesh: Self.dot(radius: 0.0064), material: UnlitMaterial(color: UIColor(accent))) { root.addChild(e); glow.append(e) }
        if let l = lines(from: row, to: nbrs) { root.addChild(l); glow.append(l) }
    }

    /// One line mesh from the selected point to each neighbour.
    private func lines(from row: Int, to nbrs: [Int]) -> ModelEntity? {
        guard let model, !nbrs.isEmpty else { return nil }
        var desc = LowLevelMesh.Descriptor()
        desc.vertexCapacity = nbrs.count * 2; desc.indexCapacity = nbrs.count * 2
        desc.vertexAttributes = [.init(semantic: .position, format: .float3, offset: 0)]
        desc.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<SIMD3<Float>>.stride)]
        guard let mesh = try? LowLevelMesh(descriptor: desc) else { return nil }
        let p0 = model.xyz[row]
        mesh.withUnsafeMutableBytes(bufferIndex: 0) { raw in
            let p = raw.bindMemory(to: SIMD3<Float>.self)
            for (i, n) in nbrs.enumerated() { p[2 * i] = p0; p[2 * i + 1] = model.xyz[n] }
        }
        mesh.withUnsafeMutableIndices { raw in let p = raw.bindMemory(to: UInt32.self); for i in 0..<(nbrs.count * 2) { p[i] = UInt32(i) } }
        mesh.parts.replaceAll([.init(indexCount: nbrs.count * 2, topology: .line, bounds: BoundingBox(min: p0 - 1, max: p0 + 1))])
        guard let res = try? MeshResource(from: mesh) else { return nil }
        var m = UnlitMaterial(color: UIColor(accent).withAlphaComponent(0.9)); m.blending = .transparent(opacity: 0.9)
        return ModelEntity(mesh: res, materials: [m])
    }

    /// The nearest visible point to a tap, by projecting every point onto the view; nil on empty space. Only the rows that are
    /// drawn (a legend kind that is switched on): a point that is not there on screen is not there to pick.
    func pick(at p: CGPoint, hidden: Set<String>) -> Int? {
        guard let content, let model else { return nil }
        var best = -1, bd = CGFloat.infinity
        for kind in PhoneStyle.kinds where !hidden.contains(kind) {
            for i in model.rowsOfKind[kind] ?? [] {
                guard let q = content.project(point: root.convert(position: model.xyz[i], to: nil), to: .local) else { continue }
                let d = (q.x - p.x) * (q.x - p.x) + (q.y - p.y) * (q.y - p.y)
                if d < bd { bd = d; best = i }
            }
        }
        return best >= 0 && bd < 28 * 28 ? best : nil
    }
}

/// The 3-D Map: drag to turn, pinch to zoom, tap a point for its panel. The turn and the zoom are made here, not by the
/// orbit control: its pinch moves the camera without limit, and one pinch too many leaves an empty screen.
@available(iOS 26, *)
struct PhoneMapReality: View {
    let model: PhoneMapModel
    let accent: Color
    let hidden: Set<String>
    @Binding var selected: Int?
    let resetTick: Int
    let failed: () -> Void
    @State private var scene = PhoneMapScene()
    @State private var turn = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))   // the turn so far
    @State private var zoom: Float = 1                                           // the zoom so far
    @GestureState private var dragging: CGSize = .zero
    @GestureState private var pinching: CGFloat = 1

    /// A drag of a point turns the map by 0.006 rad: right is about the vertical axis, down about the horizontal one.
    private func turned(by d: CGSize, from q: simd_quatf) -> simd_quatf {
        simd_normalize(simd_quatf(angle: Float(d.width) * 0.006, axis: [0, 1, 0]) * simd_quatf(angle: Float(d.height) * 0.006, axis: [1, 0, 0]) * q)
    }
    private func apply() { scene.pose(turn: turned(by: dragging, from: turn), zoom: zoom * Float(pinching)) }

    var body: some View {
        RealityView { content in
            if scene.build(into: &content, model: model, accent: accent) { scene.show(hidden: hidden); scene.select(selected); apply() }
            else { failed() }
        } update: { _ in
            // The page holds another map than the one this scene was built from: swap the dots, in this scene (see replace).
            if scene.stamp != model.stamp, !scene.replace(model: model, accent: accent) { DispatchQueue.main.async { failed() } }
            scene.show(hidden: hidden); scene.select(selected); apply()
        }
        .gesture(SpatialTapGesture().onEnded { selected = scene.pick(at: $0.location, hidden: hidden) })
        .gesture(DragGesture(minimumDistance: 6)
            .updating($dragging) { v, state, _ in state = v.translation }
            .onEnded { v in turn = turned(by: v.translation, from: turn) })
        .simultaneousGesture(MagnifyGesture()
            .updating($pinching) { v, state, _ in state = v.magnification }
            .onEnded { v in zoom = min(6, max(0.3, zoom * Float(v.magnification))) })
        .onChange(of: resetTick) { turn = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)); zoom = 1 }
    }
}

/// One point of the Map: what it is, its group, and what is closest to it in meaning (the Mac's panel, as a sheet).
struct PhoneMapPanel: View {
    let model: PhoneMapModel
    let row: Int
    let accent: Color
    let select: (Int) -> Void
    let close: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    /// A row picked from an older map can be past the end of this one (the Mac laid it out again), or not drawn: draw nothing, never trap.
    var body: some View {
        if model.isDrawn(row) { page }
    }

    @ViewBuilder private var page: some View {
        let kind = model.kinds[row]
        let g = model.group(of: row)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(Color(PhoneStyle.kindColor(kind, accent: accent))).frame(width: 9, height: 9).padding(.top, 6)
                    Text(model.titles[row]).font(.callout.weight(.semibold)).lineLimit(8).textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).accessibilityLabel("Close")
                }
                Text(PhoneMapDoc.meta(kind: kind, id: model.ids[row])).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                if let u = PhoneMapDoc.url(kind: kind, id: model.ids[row]) {
                    Button { openURL(u) } label: { Label("Open on GitHub", systemImage: "arrow.up.right.square") }
                        .buttonStyle(.borderedProminent).tint(accent).controlSize(.small)
                } else if kind == "note" {
                    Button { WorkFormat.copy(PhoneMapDoc.note(model.ids[row]).path); copied = true } label: {
                        Label(copied ? "path copied" : "Copy its path on the Mac", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                } else {
                    Text("A piece of a session. Search it on the Memory page to copy the command that reopens it.").font(.caption).foregroundStyle(.secondary)
                }
                if let g {
                    Divider()
                    Text("GROUP").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(accent)
                    Text(g.title ?? g.keywords.prefix(5).joined(separator: " · ")).font(.callout.weight(.medium))
                    if g.title != nil { Text(g.keywords.prefix(5).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                    Text("\(grouped(g.count)) memories").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                Text("CLOSEST IN MEANING").font(.caption2.weight(.bold)).tracking(1.5).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.neighbours(of: row).prefix(15), id: \.self) { r in
                        Button { select(r); copied = false } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(Color(PhoneStyle.kindColor(model.kinds[r], accent: accent))).frame(width: 7, height: 7)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(model.titles[r]).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                                    Text(PhoneMapDoc.meta(kind: model.kinds[r], id: model.ids[r])).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5).padding(.horizontal, 4).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
    }
}

extension Notification.Name {
    /// The toolbar's refresh: every page that does not poll reads again.
    static let oraclePhoneReload = Notification.Name("oraclePhoneReload")
}

struct PhoneMapView: View {
    @ObservedObject var store: OracleStore
    @ObservedObject private var client = CompanionClient.shared
    @State private var model: PhoneMapModel?
    @State private var mapData: CompanionAPI.MapData?   // what `model` was unpacked from: the same map read again changes nothing on screen
    @State private var failed: String?
    @State private var readAt: Date?                // when the map last read: a failing read keeps the map and says since when
    @State private var loading = false
    @State private var reading = false
    @State private var hidden: Set<String> = []     // kinds switched off in the legend
    @State private var flat = UserDefaults.standard.bool(forKey: "mapFlat")   // 2-D by choice; -mapFlat YES (tests)
    @State private var realityFailed = false        // RealityKit would not draw it here: the flat map takes over
    @State private var selected: Int?
    @State private var resetTick = 0
    @Environment(\.horizontalSizeClass) private var sizeClass
    private static var actionDone = false
    private var c: OracleConfig { store.config }
    private static var realityAvailable: Bool { if #available(iOS 26, *) { return true } else { return false } }

    var body: some View {
        Group {
            if client.isPaired { page } else {
                PhoneUnpaired(config: c, symbol: "point.3.filled.connected.trianglepath.dotted",
                              gives: "\(c.name)'s memory as one space: every session, ψ note, issue and PR a point, close means related. Drag to turn it, pinch to zoom, tap a point for what is next to it.")
            }
        }
        .navigationTitle("Map")
    }

    private var page: some View {
        VStack(alignment: .leading, spacing: 0) {
            // taller than its half of the page (large text sizes, a short screen): the header scrolls and the map keeps the rest
            ViewThatFits(in: .vertical) {
                header
                ScrollView { header }
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            mapArea
        }
        .onReceive(NotificationCenter.default.publisher(for: .oraclePhoneReload)) { _ in Task { await load() } }
        .onAppear { Task { await load() } }
        .onChange(of: client.pairing) { model = nil; mapData = nil; selected = nil; readAt = nil; Task { await load() } }
        .onChange(of: client.reachable) { _, now in if now == true, failed != nil { Task { await load() } } }
        .sheet(isPresented: Binding(get: { shownRow != nil && sizeClass == .compact }, set: { if !$0 { selected = nil } })) {
            if let m = model, let r = shownRow {
                PhoneMapPanel(model: m, row: r, accent: c.color, select: { selected = $0 }, close: { selected = nil })
                    .presentationDetents([.fraction(0.34), .medium, .large]).presentationBackgroundInteraction(.enabled(upThrough: .medium))
                    .presentationBackground(Color(uiColor: .systemBackground))
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            PhoneHeader(eyebrow: "MAP", title: "\(c.name)'s map",
                        subtitle: model.map { "\(grouped($0.drawnCount)) memories in one space — close means related. " + (use3D ? "Drag to turn, pinch to zoom, tap a point." : "Drag to move, pinch to zoom, tap a point.") }
                            ?? "close means related", accent: c.color)
            if let m = model { legend(m) }
            if let failed, model != nil { PhoneReadFailure(problem: failed, since: readAt) }   // with no map yet the card below says it
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var use3D: Bool { Self.realityAvailable && !flat && !realityFailed }

    /// The selected row while it is a row of the map on screen. One from another map shows nothing (and the sheet stays shut)
    /// rather than another point's panel — or a trap: the sheet and the iPad's card both ask this, not `selected`.
    private var shownRow: Int? {
        guard let m = model, let r = selected, m.isDrawn(r) else { return nil }
        return r
    }

    private var mapArea: some View {
        ZStack(alignment: .bottomLeading) {
            if let m = model {
                if use3D { reality(m) } else { PhoneMapCanvas(model: m, accent: c.color, hidden: hidden, selected: $selected, resetTick: resetTick) }
                controls
                if let r = shownRow, sizeClass != .compact {
                    PhoneMapPanel(model: m, row: r, accent: c.color, select: { selected = $0 }, close: { selected = nil })
                        .environment(\.colorScheme, .dark)
                        .frame(width: 340).frame(maxHeight: 460)
                        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(c.color.opacity(0.45)))
                        .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            } else if loading {
                VStack(spacing: 8) { ProgressView(); Text("reading the map from the Mac…").font(.callout).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failed {
                PhoneProblemCard(text: failed) { Task { await load() } }.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PhoneStyle.mapBG)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .padding(.horizontal, 16).padding(.bottom, 14)
        .animation(.easeOut(duration: 0.18), value: selected)
    }

    @ViewBuilder private func reality(_ m: PhoneMapModel) -> some View {
        if #available(iOS 26, *) {
            PhoneMapReality(model: m, accent: c.color, hidden: hidden, selected: $selected, resetTick: resetTick, failed: { realityFailed = true })
        }
    }

    /// 3-D / flat, and back to the start view.
    private var controls: some View {
        HStack(spacing: 10) {
            if Self.realityAvailable && !realityFailed {
                Picker("", selection: $flat) { Text("3D").tag(false); Text("2D").tag(true) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 100)
            }
            Button { resetTick += 1 } label: { Image(systemName: "arrow.counterclockwise") }.buttonStyle(.bordered).controlSize(.small)
                .accessibilityLabel("Reset the view")
            if realityFailed { Text("3-D did not start here — flat map").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(8).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .environment(\.colorScheme, .dark)
        .padding(12)
    }

    /// The colour key, with counts; a tap hides or shows a kind.
    private func legend(_ m: PhoneMapModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(PhoneStyle.kinds, id: \.self) { kind in
                    if let n = m.rowsOfKind[kind]?.count, n > 0 {
                        Button { if hidden.contains(kind) { hidden.remove(kind) } else { hidden.insert(kind) } } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Color(PhoneStyle.kindColor(kind, accent: c.color))).frame(width: 8, height: 8)
                                Text("\(grouped(n)) \(PhoneStyle.kindLabel(kind))").font(.caption).foregroundStyle(.secondary)
                            }
                            .opacity(hidden.contains(kind) ? 0.35 : 1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func load() async {
        if reading { return }
        reading = true; loading = model == nil
        defer { reading = false; loading = false }
        guard let d = await client.shielded({ await $0.map() }) else { failed = PhoneFormat.why(client); return }
        if model != nil, d == mapData { readAt = Date(); failed = nil; realityFailed = false; return }   // the same map again: cloud, turn and selection stay
        let m = await Task.detached(priority: .userInitiated) { PhoneMapModel(d) }.value
        if let m {
            // A different map: every row number the page holds (the selection, the 3-D scene's picks) meant another point in the old one.
            model = m; mapData = d; selected = nil; readAt = Date()
            failed = nil; realityFailed = false
        }
        else { failed = "the Mac's map does not add up (its arrays differ in length) — update the \(c.name) app on the Mac and on this \(PhoneStyle.device) to the same version" }
        if !Self.actionDone, let r = UserDefaults.standard.string(forKey: "mapSelect").flatMap(Int.init), let m, m.isDrawn(r) {   // -mapSelect <row> (tests)
            Self.actionDone = true
            selected = r
        }
    }
}

#endif
