import Foundation
import CryptoKit
import Accelerate

@MainActor
public final class GHIndex: ObservableObject {
    public nonisolated static let model = "embeddinggemma2:ane-w16"
    public static let service = URL(string: "http://127.0.0.1:11435")!
    /// The bundled model once it has loaded (the app sets it). Until then — the first launch compiles it for the ANE,
    /// minutes — the index uses the HTTP service if one is running, so search answers at once.
    public static var loaded: (any LocalEmbedding)?
    func bundled() -> (any LocalEmbedding)? {
        guard let l = Self.loaded, l.modelTag == Self.model else { return nil }
        return l
    }
    /// The bundled model, waiting while it loads — used when nothing else can embed, so a search or a batch in the
    /// first minutes of a first launch waits for it instead of failing. nil when it did not load, or on cancel.
    private func waitForBundled() async -> (any LocalEmbedding)? {
        if ModelLoad.shared.loading {
            HubLog.shared.add(.info, "nothing answers on 127.0.0.1:11435 — waiting for the bundled model to finish loading")
            progress = "waiting for the bundled model to finish loading…"
        }
        while ModelLoad.shared.loading {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return nil }
        }
        return bundled()
    }

    /// The vector space the stored vectors are in (vector_space_identity); nil for an index saved before 2026-10-07.
    @Published public internal(set) var space: String?
    /// The space the HTTP service embeds our model in, from its GET /health.
    var serviceSpace: String?
    /// Set by Stop; every loop checks it between steps (reading: the gh calls in flight are terminated).
    var stopRequested = false
    /// Stop was pressed and the run is ending: the button reads "Stopping…" and takes no click.
    @Published public private(set) var stopping = false
    /// A moment after a stopped run, so a second click on Stop does not land on Run batch.
    @Published public private(set) var cooldown = false
    /// The Stop a history scan sees from its own thread.
    var stopFlag = StopFlag()
    public func stop() {
        guard running, !stopRequested else { return }
        stopRequested = true; stopping = true; stopFlag.set()
        HubLog.shared.add(.info, "stop requested — finishing the current step")
        progress = "stopping…"
    }
    /// Every run ends here.
    func endRun() {
        let stopped = stopRequested
        running = false; stopRequested = false; stopping = false
        if stopped {
            cooldown = true
            Task { try? await Task.sleep(for: .seconds(1.5)); cooldown = false }
        }
    }

    @Published public internal(set) var docs: [IndexDoc] = []
    @Published public internal(set) var built: Date?
    @Published public internal(set) var running = false
    @Published public internal(set) var progress = ""        // "embedding 120/840 · 96 texts/s"
    @Published public internal(set) var problem: String?     // last error, with the command that fixes it
    @Published public private(set) var hits: [IndexHit] = []
    @Published public private(set) var searching = false
    @Published public internal(set) var repos: [String] = []
    @Published public private(set) var engine: Engine?
    @Published public internal(set) var pending = 0            // known items still without a vector
    @Published public internal(set) var lastRun: (embedded: Int, reused: Int, seconds: Double)?
    // live telemetry for the page: what phase, how far, how fast (one point per batch)
    @Published public internal(set) var phase = "idle"          // idle · reading · embedding
    @Published public internal(set) var repoDone = 0
    @Published public internal(set) var repoTotal = 0
    @Published public internal(set) var textDone = 0
    @Published public internal(set) var textTotal = 0
    @Published public internal(set) var rateHistory: [Double] = []
    @Published public internal(set) var currentRepo = ""

    /// What the ANE service says about itself (GET /health) — the "Vector engine" card.
    public struct Engine: Sendable {
        public let ok: Bool, kind: String, workers: Int, models: [String], space: String
    }
    public func checkEngine() async {
        if let l = bundled() {   // in-process: no server to ask
            engine = Engine(ok: true, kind: l.label, workers: l.workers, models: [l.modelTag], space: l.space)
        } else {
            engine = await health() ?? Engine(ok: false, kind: "", workers: 0, models: [], space: "")
        }
        if engine?.ok == true, !running { problem = nil }   // an embedder answers now: an old "no embedder" is stale
    }

    /// GET /health of the HTTP service, which also tells which vector space it serves our model in.
    private func health() async -> Engine? {
        var req = URLRequest(url: Self.service.appendingPathComponent("health")); req.timeoutInterval = 4
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        let all = [o] + ((o["also"] as? [[String: Any]]) ?? [])
        let mine = all.first { ($0["model"] as? String) == Self.model }
        let space = (mine?["identity"] as? String) ?? (mine?["vector_space_identity"] as? String) ?? ""
        if !space.isEmpty { serviceSpace = space }
        return Engine(ok: (o["status"] as? String) == "ok", kind: o["engine"] as? String ?? "CoreML / ANE",
                      workers: mine?["workers"] as? Int ?? o["workers"] as? Int ?? 0,
                      models: all.compactMap { $0["model"] as? String }, space: space)
    }

    /// The index on disk: docs (text, no vectors) as JSON, and every vector, in doc order, as raw Float32 in
    /// gh-index.vectors — 30k notes × 768 floats as JSON would be ~300 MB. An older file keeps vectors inline.
    private struct File: Codable {
        var model: String; var built: Date?; var docs: [IndexDoc]; var space: String?; var dim: Int?
        var ledger: [String: SessionHistory.Mark]?   // a history index: how far each transcript has been read
    }
    private var vectorsPath: URL { path.deletingPathExtension().appendingPathExtension("vectors") }
    private var saving: Task<Void, Never>?
    /// ~/Library/Application Support/ARRA Oracles/<name>.json — "gh-index" for the hub, "history/<org>__<repo>" for an
    /// oracle's own sessions, so the hub can later search every oracle's history too.
    private let path: URL
    /// "gh-index", "history/laris-co__pulse" — what the trace and Settings call this index.
    public let name: String
    public var filePath: String { path.path }
    public var vectorsFilePath: String { vectorsPath.path }

    /// One oracle's session history, one index per oracle and per app process.
    public static func history(_ repo: String) -> GHIndex {
        if let i = histories[repo] { return i }
        let i = GHIndex(name: "history/" + repo.replacingOccurrences(of: "/", with: "__"))
        histories[repo] = i
        return i
    }
    private static var histories: [String: GHIndex] = [:]
    /// What the last history scan found (nil before one has run).
    @Published public internal(set) var scanned: SessionHistory.Counts?
    @Published public internal(set) var scannedSources: [SessionHistory.Source] = []
    var ledger: [String: SessionHistory.Mark] = [:]

    /// One index per app: a window closed and opened again does not decode the 50 MB file again.
    public static let shared = GHIndex()
    /// The index the page on screen shows — the parity check after a model load compares against it.
    public static weak var active: GHIndex?
    public init(name: String = "gh-index") {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARRA Oracles", isDirectory: true)
        self.name = name
        path = dir.appendingPathComponent(name + ".json")
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        load()
    }

    /// Why the index should refresh without anyone asking — nil when it is fresh. The one rule behind both automatic
    /// starts (launch, and opening the search page): empty, or older than 6 h. The Run batch button does not ask it.
    public var staleReason: String? {
        if docs.isEmpty { return "the index is empty" }
        guard let b = built else { return "the index has no build date" }
        let age = Date().timeIntervalSince(b)
        return age > 6 * 3600 ? "the index is \(Int(age / 3600)) h old" : nil
    }

    private func load() {
        guard let f = Self.read(path: path, vectorsPath: vectorsPath) else { return }
        docs = f.docs.filter { !$0.vec.isEmpty }; built = f.built; space = f.space; ledger = f.ledger ?? [:]
        seedCache()
        repos = Array(Set(docs.filter { $0.kind != "note" }.map(\.repo))).sorted()
    }
    /// An index file with its vectors (nil when missing, of another model, or when the vectors file does not hold
    /// exactly one vector per doc — a save caught between its two files reads as nothing, never as empty docs).
    private nonisolated static func read(path: URL, vectorsPath: URL) -> File? {
        guard let d = try? Data(contentsOf: path), var f = try? JSONDecoder().decode(File.self, from: d), f.model == model else { return nil }
        if let dim = f.dim, dim > 0, !f.docs.isEmpty {
            guard let raw = try? Data(contentsOf: vectorsPath), raw.count == f.docs.count * dim * 4 else { return nil }
            raw.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
                let all = buf.bindMemory(to: Float.self)
                for i in f.docs.indices { f.docs[i].vec = Array(all[(i * dim)..<((i + 1) * dim)]) }
            }
        }
        return f
    }

    /// Another index's docs, read off the main actor without opening it (the fleet map reads every oracle's history
    /// this way, #37): the docs that have vectors, without their embedded texts (the map never needs them).
    /// The owning app may be saving it right now (vectors first, then the JSON): a read that sees the two files change
    /// under it, or not match, is tried again, three times at most.
    public nonisolated static func readDocs(name: String) -> (docs: [IndexDoc], built: Date?, space: String?)? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ARRA Oracles", isDirectory: true)
        let path = dir.appendingPathComponent(name + ".json"), vectors = path.deletingPathExtension().appendingPathExtension("vectors")
        func stamp() -> [Date?] { [path, vectors].map { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date } }
        for attempt in 0..<3 {
            let before = stamp()
            if let f = read(path: path, vectorsPath: vectors), stamp() == before {
                return (f.docs.filter { !$0.vec.isEmpty }.map { var d = $0; d.text = nil; return d }, f.built, f.space)
            }
            guard FileManager.default.fileExists(atPath: path.path), attempt < 2 else { break }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return nil
    }

    /// The fleet map's union (#37): docs gathered from other indexes. In memory only — this index is never saved.
    func adopt(_ docs: [IndexDoc], space: String?, built: Date?) {
        memoryOnly = true
        self.docs = docs; self.space = space; self.built = built
        repos = Array(Set(docs.filter { $0.kind != "note" }.map(\.repo))).sorted()
    }
    private var memoryOnly = false

    /// Writes off the main actor, one save after another (a later save waits for the earlier one).
    func save() {
        guard !memoryOnly else { return }
        layout.reconcile(docs: docs)   // positions follow the docs: gone ones dropped, new ones placed among their neighbours
        let snapshot = docs, built = built, space = space, path = path, vectorsPath = vectorsPath, previous = saving, model = Self.model
        let ledger = ledger.isEmpty ? nil : ledger
        saving = Task.detached(priority: .utility) {
            await previous?.value
            let dim = snapshot.first?.vec.count ?? 0
            var raw = Data(capacity: snapshot.count * dim * 4)
            for d in snapshot { d.vec.withUnsafeBufferPointer { raw.append(Data(buffer: $0)) } }
            let f = File(model: model, built: built, docs: snapshot.map { var d = $0; d.vec = []; return d }, space: space, dim: dim, ledger: ledger)
            guard let json = try? JSONEncoder().encode(f) else { return }
            try? raw.write(to: vectorsPath, options: .atomic)
            try? json.write(to: path, options: .atomic)
        }
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

    /// The last scan's own notes, issues, PRs, and how many of them need embedding.
    @Published public internal(set) var sideScan: (notes: Int, issues: Int, prs: Int, new: Int)?
    /// What the last scan read and has not been embedded yet: its new pieces and how far it read — a batch right after
    /// starts there instead of reading everything again.
    var pendingScan: (docs: [IndexDoc], ledger: [String: SessionHistory.Mark])?
    /// The last plan: pieces to place, and how many of them the vector cache already had.
    @Published public internal(set) var plan: (need: Int, hits: Int)?

    /// Puts this index's vectors into the shared cache once per build — vectors computed before the cache existed, or
    /// by another app — off the main actor.
    private func seedCache() {
        guard let space else { return }
        let key = "vectorCache.seeded." + path.path, stamp = built?.timeIntervalSince1970 ?? 0
        guard UserDefaults.standard.double(forKey: key) != stamp else { return }
        let items = docs.compactMap { d -> (text: String, vec: [Float])? in
            guard let t = d.text, !d.vec.isEmpty else { return nil }
            return (t, d.vec)
        }
        Task.detached(priority: .background) { VectorCache.shared.put(space, items); UserDefaults.standard.set(stamp, forKey: key) }
    }

    /// A verbose scan's line, from the scan's own thread to the debug log.
    nonisolated static func logRead(_ line: String) {
        Task { @MainActor in HubLog.shared.add(.read, line) }
    }
    /// texts/s to estimate a scan's embedding time before any run here (GPU x2 on issue text, measured 2026-10-07).
    var lastRateEstimate = 100.0
    static func duration(_ s: Double) -> String { s < 90 ? "\(Int(s.rounded())) s" : s < 5400 ? "\(Int((s / 60).rounded())) min" : String(format: "%.1f h", s / 3600) }

    /// Do the bundled engine's vectors still match the index? Embeds 32 stored items again and compares them with
    /// their stored vectors (cosine). ANE and GPU round fp16 differently, so a switch of device must stay ~1.0.
    public func checkParity() async {
        guard let l = bundled() else { return }
        let sample = docs.filter { $0.text != nil && !$0.vec.isEmpty }.shuffled().prefix(32)
        guard !sample.isEmpty, let r = try? await l.embed(sample.map { $0.text ?? "" }), r.vectors.count == sample.count else { return }
        let cos = zip(sample, r.vectors).map { d, f -> Float in
            let n = sqrt(f.reduce(0) { $0 + $1 * $1 })
            return d.vec.count == f.count && n > 0 ? vDSP.dot(d.vec, f) / n : 0
        }.sorted()
        let median = cos[cos.count / 2], low = cos.first ?? 0
        HubLog.shared.add(median >= 0.995 && low >= 0.98 ? .info : .error,
                          String(format: "parity with the index (%d items, %@): median cosine %.5f, lowest %.5f%@", cos.count, l.label, median, low,
                                 median >= 0.995 && low >= 0.98 ? "" : " — these vectors differ from the index: press Re-embed all"))
    }

    // MARK: search

    public func search(_ q: String, kind: String? = nil, openOnly: Bool = false, state: String? = nil, kinds: Set<String>? = nil) async {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { hits = []; return }
        searching = true; defer { searching = false }
        guard let found = await query(q, kind: kind, kinds: kinds, state: state, openOnly: openOnly, limit: 25, source: "page") else { return }
        hits = found
        if !running { problem = nil }
    }

    /// Embeds `q` and ranks this index — for the page or for MCP. Every query is traced: the debug log, and
    /// TraceLog (Settings → Trace, and <App>-queries.jsonl). An oracle app loads its model on first need.
    public func query(_ q: String, kind: String? = nil, kinds: Set<String>? = nil, state: String? = nil, openOnly: Bool = false,
                      limit: Int = 25, source: String = "page", caller: String? = nil) async -> [IndexHit]? {
        if bundled() == nil, !ModelLoad.shared.loading, ModelLoad.shared.failed == nil, !ModelLoad.shared.absent, let reload = ModelLoad.shared.reload {
            reload(UserDefaults.standard.string(forKey: "hub.engineMode") ?? "gpu")
        }
        let t0 = Date()
        guard let v = await embed([Self.queryText(q)], want: docs.isEmpty ? nil : space)?.first else {
            problem = refusal ?? noEmbedderProblem(); return nil
        }
        let t1 = Date()
        // Ranked off the main actor: on Neo's 48,950 docs this took 30–370 ms, and the main actor also runs the UI, the MCP
        // server and the companion's listener. `docs` is read once here; the copy is shared, not duplicated.
        let snapshot = docs
        let (found, poolCount) = await Task.detached(priority: .userInitiated) { () -> ([IndexHit], Int) in
            let pool = snapshot.filter { (kind == nil || $0.kind == kind) && (kinds == nil || kinds!.contains($0.kind))
                && (!openOnly || $0.state == "OPEN") && (state == nil || $0.state == state) }
            let hits = pool.map { d in IndexHit(doc: d, score: d.vec.count == v.count ? vDSP.dot(d.vec, v) : -1) }   // unit vectors: dot = cosine
            return (Array(hits.sorted { $0.score > $1.score }.prefix(limit)), pool.count)
        }.value
        let embedMs = t1.timeIntervalSince(t0) * 1000, rankMs = Date().timeIntervalSince(t1) * 1000
        let filter = [kind.map { "kind=\($0)" }, kinds.map { "kinds=\($0.sorted().joined(separator: ","))" }, state.map { "who=\($0)" },
                      openOnly ? "open" : nil].compactMap { $0 }.joined(separator: " ")
        HubLog.shared.add(.search, String(format: "%@%@ \"%@\" · query embedded in %.0f ms (%@) · ranked %@ in %.1f ms · best %.0f%%",
                                          source, caller.map { " (\($0))" } ?? "", q, embedMs, via, grouped(poolCount), rankMs,
                                          Double(found.first?.score ?? 0) * 100))
        let entry = TraceLog.Entry(at: Date(), source: source, index: name, query: q, filter: filter.isEmpty ? "all" : filter,
                                   embedMs: embedMs, rankMs: rankMs, pool: poolCount, via: via,
                                   top: found.prefix(5).map { .init(id: $0.doc.id, title: $0.doc.title, score: $0.score) }, caller: caller)
        TraceLog.shared.add(entry)
        if !memoryOnly { QueryBroadcast.post(index: name, source: source, trace: entry.id) }   // #37: the fleet map fires (it reads the entry)
        return found
    }

    // MARK: embedders

    /// Something can embed now: the bundled model, the HTTP service — or, on a first launch with no service, the
    /// bundled model once it finishes loading (waits for it).
    func alive() async -> Bool {
        if bundled() != nil { return true }
        if let h = await health(), h.ok { return true }
        return await waitForBundled() != nil
    }

    /// Where the last embed call ran: "in-process ANE" or "HTTP 127.0.0.1:11435".
    @Published public private(set) var via = ""
    /// The last embed call, for the telemetry line: texts, tokens (0 when the HTTP service does not say), milliseconds.
    @Published public private(set) var lastCall: (texts: Int, tokens: Int, ms: Double)?
    /// Why the last embed was refused: an embedder in another vector space than the index (never mixed).
    var refusal: String?

    /// Unit vectors for `texts` in the space `want` (nil: any): in-process on the bundled model once it has loaded,
    /// else through the HTTP service, else — first launch, no service — after the bundled model finishes loading.
    /// With `log`, one debug-log line per call: texts, tokens, milliseconds, texts/s, tokens/s, and where it ran.
    func embed(_ texts: [String], log what: String? = nil, want: String? = nil) async -> [[Float]]? {
        refusal = nil
        if let rows = await embedInProcess(texts, log: what, want: want) { return rows }
        if let rows = await embedHTTP(texts, log: what, want: want) { return rows }
        if ModelLoad.shared.loading, await waitForBundled() != nil, let rows = await embedInProcess(texts, log: what, want: want) { return rows }
        if refusal == nil { HubLog.shared.add(.error, "no embedder answered for \(texts.count) texts:  curl -s 127.0.0.1:11435/health") }
        return nil
    }

    private func refuse(_ who: String, _ have: String, _ want: String) {
        refusal = "\(who) embeds in \(have.prefix(40))…, the index is in \(want.prefix(40))… — not mixing two spaces: press Re-embed all to move the index"
        HubLog.shared.add(.error, refusal ?? "")
    }

    private func embedInProcess(_ texts: [String], log what: String?, want: String?) async -> [[Float]]? {
        guard let l = bundled() else { return nil }
        if let want, l.space != want { refuse("the bundled model", l.space, want); return nil }
        let t0 = Date()
        do {
            let (rows, tokens) = try await l.embed(texts)
            guard rows.count == texts.count else {
                HubLog.shared.add(.error, "bundled model returned \(rows.count) vectors for \(texts.count) texts — trying 127.0.0.1:11435"); return nil
            }
            let ms = Date().timeIntervalSince(t0) * 1000
            let devs = l.activity().devices
            via = "in-process " + (devs.isEmpty ? "ANE" : Array(NSOrderedSet(array: devs)).compactMap { $0 as? String }.joined(separator: "+"))
            lastCall = (texts.count, tokens, ms)
            if let what {
                HubLog.shared.add(.embed, "\(what): \(texts.count) texts · \(grouped(tokens)) tok · \(Int(ms)) ms · " +
                                  "\(short(Double(texts.count) * 1000 / max(ms, 1))) texts/s · \(short(Double(tokens) * 1000 / max(ms, 1))) tok/s · \(via)")
            }
            return rows.map { f in let n = sqrt(f.reduce(0) { $0 + $1 * $1 }); return n > 0 ? f.map { $0 / n } : f }
        } catch {
            HubLog.shared.add(.error, "bundled model failed: \(error) — trying 127.0.0.1:11435"); return nil
        }
    }

    private func embedHTTP(_ texts: [String], log what: String?, want: String?) async -> [[Float]]? {
        if let want, let have = serviceSpace, have != want { refuse("127.0.0.1:11435", have, want); return nil }
        let t0 = Date()
        var req = URLRequest(url: Self.service.appendingPathComponent("api/embed"))
        req.httpMethod = "POST"; req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": Self.model, "input": texts])
        guard let (d, r) = try? await URLSession.shared.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let rows = obj["embeddings"] as? [[Double]], rows.count == texts.count else { return nil }
        let ms = Date().timeIntervalSince(t0) * 1000
        via = "HTTP 127.0.0.1:11435"; lastCall = (texts.count, 0, ms)
        if let what {
            let chars = texts.reduce(0) { $0 + $1.count }
            HubLog.shared.add(.embed, "\(what): \(texts.count) texts · \(grouped(chars)) chars · \(Int(ms)) ms · " +
                              "\(short(Double(texts.count) * 1000 / max(ms, 1))) texts/s · via 127.0.0.1:11435")
        }
        return rows.map { row in
            let f = row.map(Float.init); let n = sqrt(f.reduce(0) { $0 + $1 * $1 })
            return n > 0 ? f.map { $0 / n } : f
        }
    }
}
