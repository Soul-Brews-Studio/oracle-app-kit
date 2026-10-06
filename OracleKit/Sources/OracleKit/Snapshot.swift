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
        public init(title: String, status: String, place: String, since: Date? = nil) {
            self.title = title; self.status = status; self.place = place; self.since = since
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

    public static func write(_ s: OracleSnapshot, config: OracleConfig) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(s) else { return }
        var targets: [URL] = []
        if let g = groupURL(config.widgetGroup) { targets.append(g) }
        #if os(macOS)
        targets.append(widgetContainerURL(config.widgetBundleId))
        #endif
        for u in targets {
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try data.write(to: u, options: .atomic) }
            catch { widgetLog.error("app write failed \(u.path, privacy: .public): \(error.localizedDescription, privacy: .public)") }
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
