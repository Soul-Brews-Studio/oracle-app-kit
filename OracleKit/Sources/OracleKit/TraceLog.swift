import Foundation

/// Every query asked of an index — from the search page or from MCP — with how long it took and what came back.
/// Kept in memory for the Settings page and appended to ~/Library/Logs/ARRA Oracles/<App>-queries.jsonl.
@MainActor
public final class TraceLog: ObservableObject {
    public static let shared = TraceLog()

    public struct Hit: Codable, Sendable { public let id: String; public let title: String; public let score: Float }
    public struct Entry: Codable, Identifiable, Sendable {
        public var id = UUID()
        public let at: Date
        public let source: String       // page · mcp
        public let index: String        // gh-index · history/laris-co__pulse
        public let query: String
        public let filter: String
        public let embedMs: Double, rankMs: Double
        public let pool: Int
        public let via: String
        public let top: [Hit]
    }

    @Published public private(set) var entries: [Entry] = []
    private let keep = 500

    public static let file: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/ARRA Oracles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "app"
        return dir.appendingPathComponent("\(app)-queries.jsonl")
    }()
    private lazy var handle: FileHandle? = {
        if !FileManager.default.fileExists(atPath: Self.file.path) { FileManager.default.createFile(atPath: Self.file.path, contents: nil) }
        return try? FileHandle(forWritingTo: Self.file)
    }()
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()

    public func add(_ e: Entry) {
        entries.append(e)
        if entries.count > keep { entries.removeFirst(entries.count - keep) }
        if let h = handle, let d = try? encoder.encode(e) {   // the throwing API: a full disk drops the line, never crashes
            _ = try? h.seekToEnd(); try? h.write(contentsOf: d + Data("\n".utf8))
        }
    }
}
