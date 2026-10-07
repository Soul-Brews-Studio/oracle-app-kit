import Foundation
import CryptoKit
import SQLite3

/// Every vector this Mac has computed, by what was embedded: (vector space, SHA-256 of the exact text) → its floats.
/// The past does not change (Nat: "the past is never changed"), so a text embedded once is never embedded again — by
/// any app: the hub, Neo, Pulse and Nexus share one file, ~/Library/Application Support/ARRA Oracles/vector-cache.sqlite
/// (SQLite, WAL, so several apps read and write it at once). A different model is a different space: two spaces
/// never meet. Re-embed all bypasses it on purpose, and writes what it computes.
public final class VectorCache: @unchecked Sendable {
    public static let shared = VectorCache()
    public let path: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "arra.vector-cache")
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARRA Oracles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        path = dir.appendingPathComponent("vector-cache.sqlite")
        guard sqlite3_open_v2(path.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { db = nil; return }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;")
        exec("CREATE TABLE IF NOT EXISTS v (space TEXT NOT NULL, hash BLOB NOT NULL, vec BLOB NOT NULL, PRIMARY KEY (space, hash)) WITHOUT ROWID;")
    }

    private func exec(_ sql: String) { if let db { sqlite3_exec(db, sql, nil, nil, nil) } }
    static func key(_ text: String) -> Data { Data(SHA256.hash(data: Data(text.utf8))) }

    /// The vectors already computed for these texts in `space`, by text.
    public func get(_ space: String, _ texts: [String]) -> [String: [Float]] {
        queue.sync {
            guard let db, !texts.isEmpty else { return [:] }
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT vec FROM v WHERE space = ?1 AND hash = ?2", -1, &st, nil) == SQLITE_OK else { return [:] }
            defer { sqlite3_finalize(st) }
            var out: [String: [Float]] = [:]
            for t in Set(texts) {
                let k = Self.key(t)
                sqlite3_reset(st); sqlite3_clear_bindings(st)
                sqlite3_bind_text(st, 1, space, -1, Self.transient)
                _ = k.withUnsafeBytes { sqlite3_bind_blob(st, 2, $0.baseAddress, Int32(k.count), Self.transient) }
                guard sqlite3_step(st) == SQLITE_ROW, let p = sqlite3_column_blob(st, 0) else { continue }
                let n = Int(sqlite3_column_bytes(st, 0)) / MemoryLayout<Float>.size
                var v = [Float](repeating: 0, count: n)
                _ = v.withUnsafeMutableBytes { memcpy($0.baseAddress, p, n * MemoryLayout<Float>.size) }   // a blob is not guaranteed aligned
                out[t] = v
            }
            return out
        }
    }

    /// Keeps these vectors (an existing one is left as it is: the same text in the same space is the same vector).
    public func put(_ space: String, _ items: [(text: String, vec: [Float])]) {
        queue.sync {
            guard let db, !items.isEmpty else { return }
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO v (space, hash, vec) VALUES (?1, ?2, ?3)", -1, &st, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(st) }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            for (text, vec) in items where !vec.isEmpty {
                let k = Self.key(text)
                sqlite3_reset(st); sqlite3_clear_bindings(st)
                sqlite3_bind_text(st, 1, space, -1, Self.transient)
                _ = k.withUnsafeBytes { sqlite3_bind_blob(st, 2, $0.baseAddress, Int32(k.count), Self.transient) }
                _ = vec.withUnsafeBytes { sqlite3_bind_blob(st, 3, $0.baseAddress, Int32($0.count), Self.transient) }
                sqlite3_step(st)
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    /// How many vectors are kept, all spaces together.
    public var count: Int {
        queue.sync {
            guard let db else { return 0 }
            var st: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT count(*) FROM v", -1, &st, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(st) }
            return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
        }
    }
}
