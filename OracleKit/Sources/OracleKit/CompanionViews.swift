#if os(iOS)
import SwiftUI
import UIKit

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

extension Notification.Name {
    /// The toolbar's refresh: every page that does not poll reads again.
    static let oraclePhoneReload = Notification.Name("oraclePhoneReload")
}

#endif
