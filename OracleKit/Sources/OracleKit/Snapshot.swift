import Foundation

/// What a widget shows. The app writes it after every refresh; the (sandboxed) widget only reads it.
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

    public static func placeholder(_ c: OracleConfig) -> OracleSnapshot {
        OracleSnapshot(name: c.name, colorHex: c.colorHex, symbol: c.symbol, working: 1, panes: 3,
                       prs: 2, issues: 3, inbox: 12, topPR: "#113 FIDO2 labs", updated: Date())
    }
}

/// Snapshot file in the oracle's App Group container (shared by the app and its widget).
public enum SnapshotStore {
    static func url(_ group: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("snapshot.json")
    }
    public static func write(_ s: OracleSnapshot, group: String) {
        guard let u = url(group) else { return }
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        try? e.encode(s).write(to: u, options: .atomic)
    }
    public static func read(group: String) -> OracleSnapshot? {
        guard let u = url(group), let d = try? Data(contentsOf: u) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(OracleSnapshot.self, from: d)
    }
}
