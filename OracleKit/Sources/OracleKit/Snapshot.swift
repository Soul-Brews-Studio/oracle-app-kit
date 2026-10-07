import Foundation
import os

/// What a widget shows. The app writes it after every refresh; the (sandboxed) widget only reads it.
/// v2 fields are optional so an older snapshot still decodes.
public struct OracleSnapshot: Codable, Sendable, Equatable {
    public var name: String
    public var colorHex: String
    public var symbol: String
    public var working: Int
    public var panes: Int
    public var prs: Int
    public var issues: Int
    public var inbox: Int
    public var topPR: String?
    public var updated: Date
    // v2
    public var needsYou: Int?            // panes blocked or done (waiting on a human)
    public var activity: [Activity]?     // most urgent first: blocked, done, working, idle
    public var prTitles: [String]?       // "#113 lab: FIDO2 labs", newest first
    public var inboxNew: Int?            // inbox files changed in the last 24 h
    public var latestHandoff: String?    // newest ψ/inbox/handoff file, prettified
    public var inboxUnread: Int?         // arrived since the baseline and not opened in the app
    public var unreadTitles: [String]?   // newest unread first, prettified

    public struct Activity: Codable, Sendable, Equatable, Hashable {
        public var title: String         // pane's current task (terminal title) or its space/tab
        public var status: String        // working · blocked · done · idle
        public var place: String         // "laris-co:w22:p1"
        public var since: Date?          // when the app first saw it in this status
        public var cwd: String?          // the pane's own folder: maps it to its worktree
        public var session: String?      // agent session id: two panes on one id write one transcript
        public init(title: String, status: String, place: String, since: Date? = nil, cwd: String? = nil, session: String? = nil) {
            self.title = title; self.status = status; self.place = place; self.since = since; self.cwd = cwd; self.session = session
        }
    }

    /// The single word the widget leads with.
    public var state: String {
        if (activity ?? []).contains(where: { $0.status == "blocked" }) { return "Blocked" }
        if (needsYou ?? 0) > 0 { return "Needs you" }
        if working > 0 { return "Working" }
        return panes > 0 ? "Idle" : "Offline"
    }

    public static func placeholder(_ c: OracleConfig) -> OracleSnapshot {
        OracleSnapshot(name: c.name, colorHex: c.colorHex, symbol: c.symbol, working: 1, panes: 3,
                       prs: 2, issues: 3, inbox: 12, topPR: "#113 lab: FIDO2 labs", updated: Date(),
                       needsYou: 0,
                       activity: [Activity(title: "Building the oracle widgets", status: "working", place: "w22:p1",
                                           since: Date().addingTimeInterval(-720)),
                                  Activity(title: "Reviewing PR #115", status: "idle", place: "w22:p2",
                                           since: Date().addingTimeInterval(-3600))],
                       prTitles: ["#113 lab: FIDO2 labs", "#115 carry: herdr book"], inboxNew: 2,
                       latestHandoff: "fido key blocked on hardware",
                       inboxUnread: 2, unreadTitles: ["ios fido app to neo", "github.com Lumen Labs brainapi2"])
    }
}

let widgetLog = Logger(subsystem: "co.laris.oracle.kit", category: "widget")

/// Where the snapshot lives. Measured on m5 (neo ψ/lab/02-herdr-widget, 2026-09-16): a sandboxed widget
/// can read its OWN container; outside paths are denied. So the unsandboxed app writes into
/// ~/Library/Containers/<widget id>/Data/Library/Application Support/OracleKit/ — and also the App Group.
public enum SnapshotStore {
    static let fileName = "snapshot.json"

    static func groupURL(_ group: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent(fileName)
    }
    /// Inside the widget's sandbox this resolves to its container; called by the widget itself.
    static func ownURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OracleKit").appendingPathComponent(fileName)
    }
    /// The same file seen from the (unsandboxed) app.
    static func widgetContainerURL(_ widgetId: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Containers/\(widgetId)/Data/Library/Application Support/OracleKit/\(fileName)")
    }

    /// Written off the main thread; `then` runs on the main thread once the files are on disk, so a widget
    /// reload reads the new snapshot. A write into another app's container can block for a minute: a dev
    /// build that macOS kept out of the widget's container held the main thread ~72 s on every refresh,
    /// and the companion server with it (#46).
    public static func write(_ s: OracleSnapshot, config: OracleConfig, then done: (@MainActor @Sendable () -> Void)? = nil) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(s) else { return }
        let group = config.widgetGroup, widget = config.widgetBundleId
        SnapshotWriter.shared.submit(data, then: done) {
            var targets: [URL] = []
            if let g = groupURL(group) { targets.append(g) }
            #if os(macOS)
            targets.append(widgetContainerURL(widget))
            #endif
            return targets
        }
    }

    /// Widget side: own container first, then the App Group. Leaves a read receipt (the lab's tripwire)
    /// in its own Caches: ~/Library/Containers/<widget id>/Data/Library/Caches/oracle-last-read.json
    public static func read(config: OracleConfig, stage: String) -> OracleSnapshot? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var tried: [[String: String]] = []
        var found: OracleSnapshot?
        for (label, url) in [("own", ownURL()), ("group", groupURL(config.widgetGroup))] {
            guard let url else { tried.append(["source": label, "result": "no url"]); continue }
            do {
                let d = try Data(contentsOf: url)
                let s = try dec.decode(OracleSnapshot.self, from: d)
                tried.append(["source": label, "result": "ok \(d.count) B", "path": url.path])
                found = s; break
            } catch {
                tried.append(["source": label, "result": "\(error)".prefix(160).description, "path": url.path])
            }
        }
        let receipt: [String: Any] = ["at": ISO8601DateFormatter().string(from: Date()), "stage": stage,
                                      "found": found != nil, "tried": tried]
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
           let d = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted]) {
            try? d.write(to: caches.appendingPathComponent("oracle-last-read.json"))
        }
        widgetLog.notice("widget \(stage, privacy: .public) found=\(found != nil, privacy: .public) tried=\(String(describing: tried), privacy: .public)")
        return found
    }
}

/// The app's snapshot writes: one at a time, on their own queue. A snapshot that arrives while one is
/// being written replaces any still waiting, so a slow write never builds a backlog. A target that fails
/// is skipped for a while (1 min, doubling to 30 min, reset by a success): a dev build that macOS keeps
/// out of the widget's container fails the same way on every refresh.
final class SnapshotWriter: @unchecked Sendable {
    static let shared = SnapshotWriter()
    private let queue = DispatchQueue(label: "co.laris.oracle.kit.snapshot", qos: .utility)
    private let lock = NSLock()
    private var waiting: (data: Data, targets: () -> [URL], done: (@MainActor @Sendable () -> Void)?)?
    private var busy = false
    /// Failures in a row and when to try again, per target. Only the queue touches it.
    private(set) var failing: [URL: (count: Int, retry: Date)] = [:]

    func submit(_ data: Data, then done: (@MainActor @Sendable () -> Void)?, targets: @escaping () -> [URL]) {
        lock.lock()
        waiting = (data, targets, done)
        let start = !busy
        busy = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let job = waiting else { busy = false; lock.unlock(); return }
            waiting = nil
            lock.unlock()
            for u in job.targets() where (failing[u]?.retry ?? .distantPast) <= Date() {
                let started = Date()
                guard let why = Self.write(job.data, to: u) else { failing[u] = nil; continue }
                let n = (failing[u]?.count ?? 0) + 1, wait = Self.backoff(n)
                failing[u] = (n, Date().addingTimeInterval(wait))
                widgetLog.error("app write failed \(u.path, privacy: .public): \(why, privacy: .public) after \(String(format: "%.1f", Date().timeIntervalSince(started)), privacy: .public) s; next try in \(Int(wait)) s\(Self.hint, privacy: .public)")
            }
            if let done = job.done { Task { @MainActor in done() } }
        }
    }

    static func backoff(_ failures: Int) -> TimeInterval { min(1800, 60 * pow(2, Double(max(0, failures - 1)))) }

    /// Nil when written; otherwise the error's domain and code. Not error.localizedDescription: it looks
    /// up the folder's display name, and inside a protected container that lookup blocked for over a minute.
    static func write(_ data: Data, to u: URL) -> String? {
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: u, options: .atomic); return nil }
        catch {
            let ns = error as NSError
            let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            return "\(ns.domain) \(ns.code)" + (under.map { " (\($0.domain) \($0.code))" } ?? "")
        }
    }

    #if os(macOS)
    /// The usual cause: this build is not signed by the team that signs the widget.
    static let hint = ". Same team as the widget? codesign -dv --verbose=2 \"\(Bundle.main.bundlePath)\" 2>&1 | grep -E 'TeamIdentifier|Authority'"
    #else
    static let hint = ""
    #endif
}
