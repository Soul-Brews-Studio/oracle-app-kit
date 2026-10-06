import SwiftUI
#if os(macOS)
import AppKit
#endif

enum Section: Hashable { case status, inbox, prs, issues, extra(String) }

public struct OracleRootView: View {
    @StateObject private var store: OracleStore
    @State private var section: Section? = .status
    @State private var dropTargeted = false
    #if os(iOS)
    @State private var showSettings = false
    #endif

    public init(config: OracleConfig) { _store = StateObject(wrappedValue: OracleStore(config: config)) }

    private var c: OracleConfig { store.config }

    public var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                IdentityCard(config: c, working: store.panes.filter { $0.status == "working" }.count)
                    .listRowSeparator(.hidden)
                Label("Live status (\(store.panes.count) panes)", systemImage: "dot.radiowaves.left.and.right").tag(Section.status)
                #if os(macOS)
                Label("Inbox (\(store.inbox.count))", systemImage: "tray.full").tag(Section.inbox)
                #endif
                Label("Pull requests (\(store.prs.count))", systemImage: "arrow.triangle.pull").tag(Section.prs)
                Label("Issues (\(store.issues.count))", systemImage: "exclamationmark.circle").tag(Section.issues)
                ForEach(c.extras.sections) { x in Label(x.title, systemImage: x.symbol).tag(Section.extra(x.id)) }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 260)
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
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 12).stroke(c.color, lineWidth: 3).padding(4) } }
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
        case .status: StatusList(rows: store.tree, config: c)
        case .inbox: InboxList(items: store.inbox)
        case .prs: GHList(title: "Open pull requests", items: store.prs, empty: "No open pull requests")
        case .issues: GHList(title: "Open issues", items: store.issues, empty: "No open issues")
        case .extra(let id): c.extras.sections.first { $0.id == id }.map { $0.view() } ?? AnyView(EmptyView())
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
    let config: OracleConfig; let working: Int
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(config.color.gradient).frame(width: 48, height: 48)
                Image(systemName: config.symbol).font(.title2.weight(.semibold)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(config.name).font(.title2.bold())
                Text(config.tagline).font(.callout).foregroundStyle(.secondary)
                Text(config.repoSlug).font(.caption.monospaced()).foregroundStyle(.secondary)
                Text(working > 0 ? "\(working) working" : "idle").font(.caption.bold())
                    .foregroundStyle(working > 0 ? config.color : .secondary)
            }
        }.padding(.vertical, 8)
    }
}

struct StatusList: View {
    let rows: [StatusRow]; let config: OracleConfig
    var body: some View {
        List(rows) { r in
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(r.glyph).font(.body.monospaced()).foregroundStyle(.secondary)
                Image(systemName: r.live ? "circle.fill" : "circle").font(.caption2)
                    .foregroundStyle(r.live ? config.color : r.status == "cold" ? Color.secondary.opacity(0.5) : .secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(r.title).font(r.depth == 0 ? .body.bold() : .body)
                    Text(r.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(r.depth) * 22)
            .opacity(r.status == "cold" ? 0.6 : 1)
        }
        .overlay {
            if rows.isEmpty {
                #if os(macOS)
                Text("Nothing from maw herdr ls for \(config.localPath)").foregroundStyle(.secondary)
                #else
                Text("Live status is read from herdr on the Mac.").foregroundStyle(.secondary)
                #endif
            }
        }
        .navigationTitle("Live status")
    }
}

struct InboxList: View {
    let items: [InboxItem]
    var body: some View {
        List(items) { i in
            Button {
                #if os(macOS)
                NSWorkspace.shared.open(URL(fileURLWithPath: i.path))
                #endif
            } label: {
                VStack(alignment: .leading) {
                    Text(i.name).font(.body)
                    Text("\(i.folder) · \(i.modified.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain)
        }
        .overlay { if items.isEmpty { Text("Inbox is empty. Drop files on the app icon or this window.").foregroundStyle(.secondary) } }
        .navigationTitle("Inbox")
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

public extension Notification.Name { static let oracleFilesDropped = Notification.Name("oracleFilesDropped") }

#if os(macOS)
/// Receives files dropped on the Dock icon (needs CFBundleDocumentTypes in the app's Info.plist).
public final class OracleAppDelegate: NSObject, NSApplicationDelegate {
    private var pending: [URL] = []
    private var ready = false
    public func application(_ application: NSApplication, open urls: [URL]) {
        if ready { deliver(urls) } else { pending += urls }
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
