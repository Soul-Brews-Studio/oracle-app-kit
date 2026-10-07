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
        public let source: String       // page · mcp (a page query is the person at the app)
        public let index: String        // gh-index · history/laris-co__pulse
        public let query: String
        public let filter: String
        public let embedMs: Double, rankMs: Double
        public let pool: Int
        public let via: String
        public let top: [Hit]
        /// who asked: over MCP the calling oracle and system ("Neo · claude-code 2.1.4 · laris-co w22:pA"); nil on a page
        public var caller: String? = nil
    }

    @Published public private(set) var entries: [Entry] = []
    /// Queries of earlier launches, read once from the query log — the tag cloud spans every launch.
    @Published public private(set) var past: [Entry] = []
    private let keep = 500
    private var pastLoad: Task<Void, Never>?

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

    /// Reads the query log of earlier launches once (the last 5,000 queries).
    /// Every caller returns once `past` is read: a second one that arrives during the read waits for the same read
    /// (a phone's /v1/trace and the Trace page at once), instead of answering without the history.
    public func loadPast() async {
        if let pastLoad { await pastLoad.value; return }
        let url = Self.file
        let read = Task { @MainActor in
            let old = await Task.detached(priority: .utility) { () -> [Entry] in
                guard let d = try? Data(contentsOf: url) else { return [] }
                let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
                return d.split(separator: 0x0A).suffix(5_000).compactMap { try? dec.decode(Entry.self, from: Data($0)) }
            }.value
            let now = Set(self.entries.map(\.id))
            self.past = old.filter { !now.contains($0.id) }
        }
        pastLoad = read
        await read.value
    }

    public func add(_ e: Entry) {
        entries.append(e)
        if entries.count > keep { entries.removeFirst(entries.count - keep) }
        if let h = handle, let d = try? encoder.encode(e) {   // the throwing API: a full disk drops the line, never crashes
            _ = try? h.seekToEnd(); try? h.write(contentsOf: d + Data("\n".utf8))
        }
    }
}
