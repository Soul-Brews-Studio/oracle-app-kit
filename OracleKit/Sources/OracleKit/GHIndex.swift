import Foundation
import CryptoKit

/// Search every oracle's GitHub issues and PRs by meaning, embedded on the Apple Neural Engine.
///
/// The ANE service is Chippy (ane-oracle, Swift CoreML, `127.0.0.1:11435`, Ollama-style `POST /api/embed`) running
/// EmbeddingGemma 2 (`embeddinggemma2:ane-w16`). Start simple (Nat, 2026-10-07): issues + PRs first, the ψ vault later.
/// Stored as one JSON file — a few thousand 768-d vectors fit in memory and a brute-force cosine is instant.
/// Only new or changed items are embedded again (a hash of the text that was embedded).
public struct IndexDoc: Codable, Identifiable, Hashable, Sendable {
    public var id: String { "\(repo)#\(number)" }
    public let repo: String          // owner/name
    public let kind: String          // issue · pr
    public let number: Int
    public let title: String
    public let state: String         // OPEN · CLOSED · MERGED
    public let url: String
    public let updated: String
    public let snippet: String       // the first lines of the body, for the result card
    public let hash: String          // of the embedded text: unchanged → no re-embed
    public var vec: [Float]          // L2-normalised
}

public struct IndexHit: Identifiable, Hashable, Sendable {
    public var id: String { doc.id }
    public let doc: IndexDoc
    public let score: Float
}

@MainActor
public final class GHIndex: ObservableObject {
    public static let model = "embeddinggemma2:ane-w16"
    public static let service = URL(string: "http://127.0.0.1:11435")!

    @Published public private(set) var docs: [IndexDoc] = []
    @Published public private(set) var built: Date?
    @Published public private(set) var running = false
    @Published public private(set) var progress = ""        // "embedding 120/840 · 96 texts/s"
    @Published public private(set) var problem: String?     // last error, with the command that fixes it
    @Published public private(set) var hits: [IndexHit] = []
    @Published public private(set) var searching = false
    @Published public private(set) var repos: [String] = []
    @Published public private(set) var engine: Engine?
    @Published public private(set) var pending = 0            // known items still without a vector
    @Published public private(set) var lastRun: (embedded: Int, reused: Int, seconds: Double)?

    /// What the ANE service says about itself (GET /health) — the "Vector engine" card.
    public struct Engine: Sendable {
        public let ok: Bool, kind: String, workers: Int, models: [String], space: String
    }
    public func checkEngine() async {
        var req = URLRequest(url: Self.service.appendingPathComponent("health")); req.timeoutInterval = 4
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { engine = Engine(ok: false, kind: "", workers: 0, models: [], space: ""); return }
        let all = [o] + ((o["also"] as? [[String: Any]]) ?? [])
        let mine = all.first { ($0["model"] as? String) == Self.model }
        engine = Engine(ok: (o["status"] as? String) == "ok", kind: o["engine"] as? String ?? "CoreML / ANE",
                        workers: mine?["workers"] as? Int ?? o["workers"] as? Int ?? 0,
                        models: all.compactMap { $0["model"] as? String },
                        space: (mine?["identity"] as? String) ?? (mine?["vector_space_identity"] as? String) ?? "")
    }

    private struct File: Codable { var model: String; var built: Date?; var docs: [IndexDoc] }
    private let path: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARRA Oracles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gh-index.json")
    }()

    public init() { load() }

    private func load() {
        guard let d = try? Data(contentsOf: path), let f = try? JSONDecoder().decode(File.self, from: d), f.model == Self.model else { return }
        docs = f.docs; built = f.built
        repos = Array(Set(f.docs.map(\.repo))).sorted()
    }
    private func save() {
        let f = File(model: Self.model, built: built, docs: docs)
        if let d = try? JSONEncoder().encode(f) { try? d.write(to: path, options: .atomic) }
    }

    /// owner/name from a checkout path like /opt/Code/github.com/laris-co/neo-oracle
    public nonisolated static func slug(fromCheckout path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "github.com"), parts.count > i + 2 else { return nil }
        return "\(parts[i + 1])/\(parts[i + 2])"
    }

    /// The text EmbeddingGemma expects for a document, and for a query.
    nonisolated static func docText(title: String, body: String) -> String { "title: \(title) | text: \(String(body.prefix(1600)))" }
    nonisolated static func queryText(_ q: String) -> String { "task: search result | query: \(q)" }

    // MARK: index

    /// Pull issues + PRs of every repo, embed what is new or changed on the ANE, save.
    public func index(repos slugs: [String]) async {
        guard !running else { return }
        running = true; problem = nil; defer { running = false }
        guard await alive() else {
            problem = "the ANE embed service is not answering on 127.0.0.1:11435 — start the ANEEmbed app (ane-oracle), then:  curl -s 127.0.0.1:11435/health"
            progress = ""; return
        }
        var fresh: [IndexDoc] = []
        var textOf: [String: String] = [:]   // the full text to embed (title + body prefix); only a snippet is kept
        for (i, repo) in slugs.enumerated() {
            progress = "reading \(repo) (\(i + 1)/\(slugs.count))"
            for kind in ["issue", "pr"] {
                let fields = "number,title,body,state,url,updatedAt"
                guard let out = await Shell.run("gh", [kind, "list", "-R", repo, "--state", "all", "-L", "300", "--json", fields], timeout: 40),
                      let rows = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]] else { continue }
                for r in rows {
                    let title = r["title"] as? String ?? "", body = r["body"] as? String ?? ""
                    let text = Self.docText(title: title, body: body)
                    let hash = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                    let snippet = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(2).joined(separator: " · ")
                    let doc = IndexDoc(repo: repo, kind: kind, number: r["number"] as? Int ?? 0, title: title,
                                       state: r["state"] as? String ?? "", url: r["url"] as? String ?? "",
                                       updated: r["updatedAt"] as? String ?? "", snippet: String(snippet.prefix(220)), hash: hash, vec: [])
                    fresh.append(doc); textOf[doc.id] = text
                }
            }
        }
        // reuse the vector of anything whose embedded text did not change
        let old = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for i in fresh.indices { if let o = old[fresh[i].id], o.hash == fresh[i].hash, !o.vec.isEmpty { fresh[i].vec = o.vec } }
        let todo = fresh.indices.filter { fresh[$0].vec.isEmpty }
        let t0 = Date()
        var done = 0
        for chunk in stride(from: 0, to: todo.count, by: 32).map({ Array(todo[$0..<min($0 + 32, todo.count)]) }) {
            let inputs = chunk.map { textOf[fresh[$0].id] ?? fresh[$0].title }
            guard let vecs = await embed(inputs) else {
                problem = "embedding stopped after \(done)/\(todo.count) — the ANE service went away?  curl -s 127.0.0.1:11435/health"
                break
            }
            for (k, idx) in chunk.enumerated() where k < vecs.count { fresh[idx].vec = vecs[k] }
            done += chunk.count
            let rate = Double(done) / max(0.001, Date().timeIntervalSince(t0))
            progress = "embedding on the ANE \(done)/\(todo.count) · \(Int(rate)) texts/s"
        }
        docs = fresh.filter { !$0.vec.isEmpty }
        pending = fresh.count - docs.count
        lastRun = (done, fresh.count - todo.count, Date().timeIntervalSince(t0))
        repos = slugs
        built = Date()
        save()
        let secs = Date().timeIntervalSince(t0)
        progress = todo.isEmpty ? "up to date — nothing new to embed" : "embedded \(done) new or changed in \(String(format: "%.1f", secs)) s (\(Int(Double(done) / max(secs, 0.001))) texts/s), \(fresh.count - todo.count) reused"
    }

    // MARK: search

    public func search(_ q: String, kind: String? = nil, openOnly: Bool = false) async {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { hits = []; return }
        searching = true; defer { searching = false }
        guard let v = await embed([Self.queryText(q)])?.first else {
            problem = "the ANE embed service is not answering — curl -s 127.0.0.1:11435/health"; return
        }
        let pool = docs.filter { (kind == nil || $0.kind == kind) && (!openOnly || $0.state == "OPEN") }
        hits = pool.map { d in IndexHit(doc: d, score: zip(d.vec, v).reduce(0) { $0 + $1.0 * $1.1 }) }
            .sorted { $0.score > $1.score }.prefix(25).map { $0 }
    }

    // MARK: the ANE service

    func alive() async -> Bool {
        var req = URLRequest(url: Self.service.appendingPathComponent("health")); req.timeoutInterval = 4
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(decoding: d, as: UTF8.self).contains("\"ok\"")
    }

    func embed(_ texts: [String]) async -> [[Float]]? {
        var req = URLRequest(url: Self.service.appendingPathComponent("api/embed"))
        req.httpMethod = "POST"; req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": Self.model, "input": texts])
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let rows = obj["embeddings"] as? [[Double]], rows.count == texts.count else { return nil }
        return rows.map { row in
            let f = row.map(Float.init); let n = sqrt(f.reduce(0) { $0 + $1 * $1 })
            return n > 0 ? f.map { $0 / n } : f
        }
    }
}
