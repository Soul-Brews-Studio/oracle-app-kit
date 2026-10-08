import SwiftUI
#if os(macOS)
import AppKit
#endif

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
                Button("Cancel", role: .cancel) { onDone() }.keyboardShortcut(.cancelAction).handCursor()
                Button(sending ? "Creating…" : "Create issue") {
                    sending = true
                    Task {
                        let url = await store.createIssue(title: title, body: text)
                        #if os(macOS)
                        if let url, let u = URL(string: url) { NSWorkspace.shared.open(u) }   // Nat: "when issue created, open the gh issue link"
                        #endif
                        onDone()
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).handCursor()
                .disabled(sending || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
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
            .buttonStyle(.plain).handCursor()
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

public extension Notification.Name {
    static let oracleFilesDropped = Notification.Name("oracleFilesDropped")
    static let oracleOpenSection = Notification.Name("oracleOpenSection")
    static let oracleServiceIssue = Notification.Name("oracleServiceIssue")
    static let oracleServiceMessage = Notification.Name("oracleServiceMessage")
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
        for u in own {
            // oracle-<name>://issue|inbox|message?url=&title=&text= — the Chrome "Send to oracle" menu (browser/chrome)
            switch u.host {
            case "issue", "inbox", "message": deliverLink(u)
            case "fit":     // the double-click, by link (checks): oracle-<name>://fit — fit, and again: back
                if let w = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) { Drawer.toggleFit(page: 760, window: w) }
            case "front":   // the hub's app card: this window on that display (oracle-<name>://front?display=<id>)
                let id = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "display" }?.value.flatMap(UInt32.init)
                Self.bringFront(display: id)
            default:
                NSApp.activate(ignoringOtherApps: true)
                NotificationCenter.default.post(name: .oracleOpenSection, object: u.host ?? "open")
            }
        }
        guard !drops.isEmpty else { return }
        if ready { deliver(drops) } else { pending += drops }
    }
    /// This app's window on the given display (the hub sends the main display's id), centred in its visible frame
    /// and no bigger than it, then in front. Already there: just in front. An app moves its own window, so this
    /// needs no Accessibility; macOS puts it in that display's current Space, where Nat is looking.
    @MainActor static func bringFront(display id: UInt32?) {
        NSApp.activate(ignoringOtherApps: true)
        guard let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) ?? NSApp.windows.first(where: { $0.canBecomeMain })
        else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        let number = { (s: NSScreen) in (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        if let target = NSScreen.screens.first(where: { number($0) == id }) ?? NSScreen.screens.first,
           w.screen.flatMap(number) != number(target) {
            w.setFrame(Self.centred(w.frame.size, in: target.visibleFrame), display: true)
        }
        w.makeKeyAndOrderFront(nil)
    }

    /// A window of this size, centred in a visible frame and shrunk to fit it.
    static func centred(_ size: NSSize, in v: NSRect) -> NSRect {
        let w = min(size.width, v.width), h = min(size.height, v.height)
        return NSRect(x: (v.midX - w / 2).rounded(), y: (v.midY - h / 2).rounded(), width: w, height: h)
    }

    /// Copy ONCE here, then tell every window to refresh (each window copying would duplicate files).
    private func deliver(_ urls: [URL]) {
        let n = OracleStore.copyIntoInbox(urls, config: OracleConfig.current)
        NotificationCenter.default.post(name: .oracleFilesDropped, object: n)
    }
    public func applicationDidFinishLaunching(_ notification: Notification) {
        ready = true
        NSApp.servicesProvider = self          // right-click → Services → New <Name> Oracle issue / Send to … inbox
        NSUpdateDynamicServices()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            if !pending.isEmpty { deliver(pending); pending = [] }
        }
    }
    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Services menu — NSServices in each app's Info.plist (app.yml) names these two messages.

    /// "New <Name> Oracle issue": the selection (text, links or files) becomes an issue draft in the app;
    /// Nat edits it and presses Create — nothing posts by itself.
    @MainActor @objc public func newIssue(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let (urls, text) = Self.read(pboard)
        ServiceInbox.pendingIssue = Self.issueDraft(urls: urls, text: text, oracle: OracleConfig.current.name)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .oracleServiceIssue, object: nil)
    }

    /// "Send to <Name> Oracle inbox": files are copied, links become notes, selected text becomes a note —
    /// the same landing as a Dock drop.
    @MainActor @objc public func sendToInbox(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        var (urls, text) = Self.read(pboard)
        if urls.isEmpty, let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            let note = FileManager.default.temporaryDirectory.appendingPathComponent("selection.md")
            if (try? t.write(to: note, atomically: true, encoding: .utf8)) != nil { urls = [note] }
            text = nil
        }
        if !urls.isEmpty { deliver(urls) }
    }

    /// "Message <Name> Oracle": the selection goes into the app's message box (maw herdr hey); Nat checks the
    /// target pane and sends with ⌘↩ — nothing is sent by the right-click itself.
    @MainActor @objc public func messageOracle(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let (urls, text) = Self.read(pboard)
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let links = urls.map { $0.isFileURL ? $0.path : $0.absoluteString }.filter { $0 != t }
        ServiceInbox.pendingMessage = ([t] + links).filter { !$0.isEmpty }.joined(separator: "\n")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: .oracleServiceMessage, object: nil)
    }

    /// The browser's version of the three Services: same draft sheet, inbox landing and message box.
    @MainActor private func deliverLink(_ u: URL) {
        // older extension builds wrote spaces as "+" (URLSearchParams); a real plus always arrives as %2B
        let q = URLComponents(url: u, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        func item(_ k: String) -> String {
            let raw = (q.first { $0.name == k }?.value ?? "").replacingOccurrences(of: "+", with: "%20")
            return (raw.removingPercentEncoding ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let link = URL(string: item("url")).flatMap { $0.scheme == nil ? nil : $0 }
        let title = item("title"), text = item("text")
        switch u.host {
        case "inbox":
            var urls = link.map { [$0] } ?? []
            if !text.isEmpty {
                let note = FileManager.default.temporaryDirectory.appendingPathComponent("selection.md")
                if (try? text.write(to: note, atomically: true, encoding: .utf8)) != nil { urls.append(note) }
            }
            if !urls.isEmpty { deliver(urls) }
            return
        case "message":
            ServiceInbox.pendingMessage = [text, link?.absoluteString ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
            NotificationCenter.default.post(name: .oracleServiceMessage, object: nil)
        default:
            var d = Self.issueDraft(urls: link.map { [$0] } ?? [], text: text, oracle: OracleConfig.current.name)
            // a whole Facebook thread is too big for a URL: the extension left it at ~/.oracle-fb/threads/<id>.md
            // (browser/bridge/server.ts) and sent only the id. Ids are [a-z0-9] — never a path.
            let tid = item("thread")
            if !tid.isEmpty, tid.allSatisfy({ $0.isLetter || $0.isNumber }),
               let md = try? String(contentsOfFile: NSHomeDirectory() + "/.oracle-fb/threads/\(tid).md", encoding: .utf8) {
                d = IssueDraft(title: d.title, text: d.text + "\n\n---\n\n" + md)
            }
            if !title.isEmpty { d = IssueDraft(title: String(title.prefix(100)), text: d.text) }
            ServiceInbox.pendingIssue = d
            NotificationCenter.default.post(name: .oracleServiceIssue, object: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    static func read(_ pb: NSPasteboard) -> (urls: [URL], text: String?) {
        ((pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? [], pb.string(forType: .string))
    }

    static func issueDraft(urls: [URL], text: String?, oracle: String) -> IssueDraft {
        let t = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !urls.isEmpty {
            let d = OracleStore.issueDraft(urls, oracle: oracle)
            return IssueDraft(title: d.title, text: (t.isEmpty || urls.contains { $0.absoluteString == t } ? "" : t + "\n\n") + d.body)
        }
        let first = t.split(separator: "\n").first.map(String.init) ?? ""
        return IssueDraft(title: String(first.prefix(100)), text: t + "\n\n_Sent to the \(oracle) app from the right-click menu._")
    }
}

/// A right-click issue that arrives before (or while) the window shows: the root view picks it up.
@MainActor enum ServiceInbox { static var pendingIssue: IssueDraft?; static var pendingMessage: String? }
#endif
