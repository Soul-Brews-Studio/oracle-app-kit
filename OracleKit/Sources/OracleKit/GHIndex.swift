import Foundation
import CryptoKit
import Accelerate

/// Search every oracle's GitHub issues and PRs by meaning, embedded on the Apple Neural Engine.
///
/// The ANE service is Chippy (Swift CoreML, `127.0.0.1:11435`, Ollama-style `POST /api/embed`) running
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
    public var text: String? = nil   // the embedded text, so Re-embed all needs no GitHub calls (nil in older indexes)
}

/// Loading the bundled model: every part (worker × bucket) with how long it took, since when, and the outcome —
/// shown on the engine card and in the debug log. The first launch compiles each bucket for the Neural Engine
/// (~30 s each); the second worker and every later launch load from the system cache in well under a second.
@MainActor
public final class ModelLoad: ObservableObject {
    public static let shared = ModelLoad()
    public struct Step: Sendable {
        public let worker: Int, bucket: Int
        public let device: String
        public let seconds: Double
    }
    @Published public private(set) var done = 0
    @Published public private(set) var total = 0
    @Published public private(set) var steps: [Step] = []
    @Published public private(set) var started: Date?
    @Published public private(set) var finished: Date?
    @Published public private(set) var failed: String?
    /// This build carries no model (a clone without the export): not a failure — the HTTP service embeds instead.
    @Published public private(set) var absent = false
    /// Loads the bundled model again (the app sets it); the Retry button after a failed load.
    public var retry: (() -> Void)?
    /// Loads it again on other devices — "ane", "gpu" or "both" (the engine picker). The running engine keeps
    /// answering until the new one is ready.
    public var reload: ((String) -> Void)?
    public private(set) var buckets: [Int] = []
    public private(set) var workers = 0
    public private(set) var lastStepAt: Date?
    public var loading: Bool { started != nil && finished == nil && failed == nil }

    public func begin(buckets: [Int], workers: Int) {
        self.buckets = buckets.sorted(); self.workers = workers
        total = buckets.count * workers; done = 0; steps = []
        started = Date(); finished = nil; failed = nil; lastStepAt = started
    }
    public func record(done: Int, total: Int, worker: Int, bucket: Int, device: String, seconds: Double) {
        guard done > self.done else { return }
        self.done = done; self.total = total; lastStepAt = Date()
        steps.append(Step(worker: worker, bucket: bucket, device: device, seconds: seconds))
        HubLog.shared.add(.load, String(format: "part %d/%d · worker %d · bucket %d on %@ · %@ in %.2f s", done, total, worker + 1, bucket,
                                        device, seconds < 2 ? "from cache" : "compiled", seconds))
    }
    public func finish() { finished = Date() }
    public func fail(_ why: String) { failed = why }
    public func markAbsent() { absent = true }

    /// What loads now: the part after the last one done.
    public var next: (worker: Int, bucket: Int)? {
        guard loading, !buckets.isEmpty, done < total else { return nil }
        return (done / buckets.count, buckets[done % buckets.count])
    }
    /// Seconds left, once a part has been compiled: the average compile so far × the first worker's parts still to
    /// come. The second worker loads from the cache the first one filled, so it adds seconds, not minutes.
    public var eta: Double? {
        let compiled = steps.filter { $0.seconds >= 2 }
        guard loading, !compiled.isEmpty, !buckets.isEmpty else { return nil }
        let avg = compiled.reduce(0) { $0 + $1.seconds } / Double(compiled.count)
        let left = max(0, buckets.count - steps.filter { $0.worker == 0 }.count)
        return avg * Double(left) + 3
    }
}

public struct IndexHit: Identifiable, Hashable, Sendable {
    public var id: String { doc.id }
    public let doc: IndexDoc
    public let score: Float
}

/// An embedder that runs inside the app — no server. The ARRA Oracles hub installs one: the EmbeddingGemma 2 model it
/// carries in its bundle, on CoreML + the Neural Engine (ANEEmbed, copied from the Chippy service).
public protocol LocalEmbedding: AnyObject {
    var label: String { get }       // "bundled CoreML/ANE · in-process · 2 workers"
    var modelTag: String { get }    // must equal GHIndex.model, or vectors would land in another space
    var space: String { get }       // vector_space_identity
    var workers: Int { get }
    /// Unit vectors for `texts`, and how many tokens the texts came to (for the speed log).
    func embed(_ texts: [String]) async throws -> (vectors: [[Float]], tokens: Int)
    /// Live counters for the speed readout: rates, busy workers, the last calls.
    func activity() -> EmbedActivity
}

@MainActor
public final class GHIndex: ObservableObject {
    public static let model = "embeddinggemma2:ane-w16"
    public static let service = URL(string: "http://127.0.0.1:11435")!
    /// The bundled model once it has loaded (the app sets it). Until then — the first launch compiles it for the ANE,
    /// minutes — the index uses the HTTP service if one is running, so search answers at once.
    public static var loaded: (any LocalEmbedding)?
    private func bundled() -> (any LocalEmbedding)? {
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
    @Published public private(set) var space: String?
    /// The space the HTTP service embeds our model in, from its GET /health.
    private var serviceSpace: String?
    /// Set by Stop; every loop checks it between steps (reading: the gh calls in flight are terminated).
    private var stopRequested = false
    /// Stop was pressed and the run is ending: the button reads "Stopping…" and takes no click.
    @Published public private(set) var stopping = false
    /// A moment after a stopped run, so a second click on Stop does not land on Run batch.
    @Published public private(set) var cooldown = false
    public func stop() {
        guard running, !stopRequested else { return }
        stopRequested = true; stopping = true
        HubLog.shared.add(.info, "stop requested — finishing the current step")
        progress = "stopping…"
    }
    /// Every run ends here.
    private func endRun() {
        let stopped = stopRequested
        running = false; stopRequested = false; stopping = false
        if stopped {
            cooldown = true
            Task { try? await Task.sleep(for: .seconds(1.5)); cooldown = false }
        }
    }

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
    // live telemetry for the page: what phase, how far, how fast (one point per batch)
    @Published public private(set) var phase = "idle"          // idle · reading · embedding
    @Published public private(set) var repoDone = 0
    @Published public private(set) var repoTotal = 0
    @Published public private(set) var textDone = 0
    @Published public private(set) var textTotal = 0
    @Published public private(set) var rateHistory: [Double] = []
    @Published public private(set) var currentRepo = ""

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

    private struct File: Codable { var model: String; var built: Date?; var docs: [IndexDoc]; var space: String? }
    private let path: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARRA Oracles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("gh-index.json")
    }()

    /// One index per app: a window closed and opened again does not decode the 50 MB file again.
    public static let shared = GHIndex()
    public init() { load() }

    /// Why the index should refresh without anyone asking — nil when it is fresh. The one rule behind both automatic
    /// starts (launch, and opening the search page): empty, or older than 6 h. The Run batch button does not ask it.
    public var staleReason: String? {
        if docs.isEmpty { return "the index is empty" }
        guard let b = built else { return "the index has no build date" }
        let age = Date().timeIntervalSince(b)
        return age > 6 * 3600 ? "the index is \(Int(age / 3600)) h old" : nil
    }

    private func load() {
        guard let d = try? Data(contentsOf: path), let f = try? JSONDecoder().decode(File.self, from: d), f.model == Self.model else { return }
        docs = f.docs; built = f.built; space = f.space
        repos = Array(Set(f.docs.map(\.repo))).sorted()
    }
    private func save() {
        let f = File(model: Self.model, built: built, docs: docs, space: space)
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

    /// Why nothing can embed: which state the bundled model is in, and the command that helps.
    private func noEmbedderProblem() -> String {
        if let f = ModelLoad.shared.failed {
            return "no embedder: the bundled model did not load (\(f)) and nothing answers on 127.0.0.1:11435 — press Retry on the engine card, or check the service:  curl -s 127.0.0.1:11435/health"
        }
        if ModelLoad.shared.absent {
            return "no embedder: this build carries no model and nothing answers on 127.0.0.1:11435 — start an embedding service there, then:  curl -s 127.0.0.1:11435/health"
        }
        return "no embedder answered:  curl -s 127.0.0.1:11435/health"
    }

    /// Pull issues + PRs of every repo, embed what is new or changed on the ANE, save.
    /// `why` goes to the debug log. `reembed` embeds every item again, not only new or changed ones.
    /// Stop ends it between steps: while reading nothing changes; while embedding what is done is kept.
    public func index(repos slugs: [String], why: String, reembed: Bool = false) async {
        guard !running else { HubLog.shared.add(.info, "a batch is already running — \(why) skipped"); return }
        running = true; stopRequested = false; problem = nil
        defer { endRun() }
        HubLog.shared.add(.info, "batch: \(slugs.count) repos — \(why)" + (built.map { " · index built \(Int(Date().timeIntervalSince($0) / 60)) min ago" } ?? " · no index yet")
                          + (reembed ? " · embed everything again" : ""))
        guard await alive() else {
            problem = noEmbedderProblem(); HubLog.shared.add(.error, problem ?? ""); progress = ""; return
        }
        phase = "reading"; repoTotal = slugs.count; repoDone = 0; textDone = 0; textTotal = 0; rateHistory = []
        defer { phase = "idle"; currentRepo = "" }
        let tRead = Date()
        // gh is network-bound (~2 s a repo): read 6 repos at a time, log each as it lands, keep the input order.
        var byRepo: [Int: [IndexDoc]] = [:]
        var finished = 0
        let stopped = await withTaskGroup(of: (Int, String, RepoRead).self) { group -> Bool in
            var next = 0
            func start() { let i = next, repo = slugs[i]; next += 1; group.addTask { (i, repo, await Self.read(repo)) } }
            while next < min(6, slugs.count) { start() }
            while let item = await group.next() {
                let (i, repo, r) = item
                byRepo[i] = r.docs; finished += 1
                r.errors.forEach { HubLog.shared.add(.error, $0) }
                HubLog.shared.add(.read, "\(repo): \(r.issues) issues · \(r.prs) PRs · \(r.ms) ms")
                repoDone = finished; currentRepo = repo
                progress = "reading \(repo) (\(finished)/\(slugs.count))"
                if stopRequested { group.cancelAll(); return true }
                if next < slugs.count { start() }
            }
            return false
        }
        if stopped {
            progress = "stopped while reading (\(finished)/\(slugs.count) repos) — the index is unchanged"
            HubLog.shared.add(.info, progress); return
        }
        var fresh = slugs.indices.flatMap { byRepo[$0] ?? [] }
        // The space this run's vectors land in. Another space than the stored one makes every old vector useless.
        let runSpace = bundled()?.space ?? serviceSpace
        let moved = space != nil && runSpace != nil && space != runSpace && !docs.isEmpty
        if moved { HubLog.shared.add(.info, "the embedder's vector space is not the index's (\(space?.prefix(36) ?? "")… → \(runSpace?.prefix(36) ?? "")…): embedding everything again") }
        let everything = reembed || moved
        // reuse the vector of anything whose embedded text did not change
        let old = Dictionary(docs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if !everything {
            for i in fresh.indices { if let o = old[fresh[i].id], o.hash == fresh[i].hash, !o.vec.isEmpty { fresh[i].vec = o.vec } }
        }
        let todo = fresh.indices.filter { fresh[$0].vec.isEmpty }
        HubLog.shared.add(.info, String(format: "read %@ items from %d repos in %.1f s · %@ unchanged · %@ to embed",
                                        grouped(fresh.count), slugs.count, Date().timeIntervalSince(tRead), grouped(fresh.count - todo.count), grouped(todo.count)))
        repoDone = slugs.count; phase = "embedding"; textTotal = todo.count
        let t0 = Date()
        let target = everything || space == nil ? runSpace : space
        let done = await embedChunks(&fresh, todo, want: target)
        let complete = done == todo.count
        if !complete && !moved {   // stopped or failed midway: what was not reached keeps its old entry, so the next run embeds it
            for i in fresh.indices where fresh[i].vec.isEmpty { if let o = old[fresh[i].id], !o.vec.isEmpty { fresh[i] = o } }
        }
        docs = fresh.filter { !$0.vec.isEmpty }
        pending = fresh.count - docs.count
        lastRun = (done, fresh.count - todo.count, Date().timeIntervalSince(t0))
        repos = slugs
        if let target { space = target }
        if complete { built = Date() }   // a partial run does not count as fresh: the 6 h refresh still comes
        save()
        let secs = Date().timeIntervalSince(t0)
        if complete {
            progress = todo.isEmpty ? "up to date — nothing new to embed" : "embedded \(done) in \(String(format: "%.1f", secs)) s (\(Int(Double(done) / max(secs, 0.001))) texts/s, \(via)), \(fresh.count - todo.count) reused"
        } else {
            progress = "\(stopRequested ? "stopped" : "stopped early") after \(done)/\(todo.count) — " + (moved ? "\(pending) items wait for the next run" : "the rest keep their old vectors")
        }
        HubLog.shared.add(.info, "batch done — " + progress)
    }

    /// One repo's issues and PRs as index entries (no vector yet).
    struct RepoRead: Sendable { var docs: [IndexDoc] = []; var issues = 0, prs = 0, ms = 0; var errors: [String] = [] }
    nonisolated private static func read(_ repo: String) async -> RepoRead {
        let t0 = Date()
        var r = RepoRead()
        for kind in ["issue", "pr"] {
            let fields = "number,title,body,state,url,updatedAt"
            guard let out = await Shell.run("gh", [kind, "list", "-R", repo, "--state", "all", "-L", "300", "--json", fields], timeout: 40),
                  let rows = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [[String: Any]] else {
                r.errors.append("\(repo): gh \(kind) list gave nothing (no access, or \(kind == "issue" ? "issues are off" : "no PRs")):  gh \(kind) list -R \(repo) -L 1")
                continue
            }
            if kind == "issue" { r.issues = rows.count } else { r.prs = rows.count }
            for row in rows {
                let title = row["title"] as? String ?? "", body = row["body"] as? String ?? ""
                let text = docText(title: title, body: body)
                let hash = SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                let snippet = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(2).joined(separator: " · ")
                r.docs.append(IndexDoc(repo: repo, kind: kind, number: row["number"] as? Int ?? 0, title: title,
                                       state: row["state"] as? String ?? "", url: row["url"] as? String ?? "",
                                       updated: row["updatedAt"] as? String ?? "", snippet: String(snippet.prefix(220)), hash: hash, vec: [], text: text))
            }
        }
        r.ms = Int(Date().timeIntervalSince(t0) * 1000)
        return r
    }

    /// Embed every item again, on this Mac's ANE once the bundled model has loaded — the way to rebuild every vector,
    /// and to watch the Neural Engine work. No GitHub calls when the index carries the embedded text (batches since
    /// 2026-10-07 store it); an older index reads the repos first.
    public func reembedAll(repos slugs: [String]) async {
        guard !docs.isEmpty, docs.allSatisfy({ $0.text != nil }) else {
            await index(repos: slugs, why: "Re-embed all (the index has no stored text yet, so read the repos first)", reembed: true)
            return
        }
        guard !running else { HubLog.shared.add(.info, "a batch is already running — Re-embed all skipped"); return }
        running = true; stopRequested = false; problem = nil
        defer { endRun() }
        HubLog.shared.add(.info, "re-embed all: \(grouped(docs.count)) stored items, no GitHub calls")
        guard await alive() else {
            problem = noEmbedderProblem(); HubLog.shared.add(.error, problem ?? ""); progress = ""; return
        }
        phase = "embedding"; repoTotal = 0; repoDone = 0; textDone = 0; textTotal = docs.count; rateHistory = []
        defer { phase = "idle" }
        let runSpace = bundled()?.space ?? serviceSpace
        let moved = space != nil && runSpace != nil && space != runSpace
        var fresh = docs
        let t0 = Date()
        let done = await embedChunks(&fresh, Array(fresh.indices), want: runSpace)
        let complete = done == fresh.count
        if !complete && moved { fresh = Array(fresh.prefix(done)) }   // never keep vectors of two spaces side by side
        pending = docs.count - fresh.count
        docs = fresh
        if let runSpace, complete || moved { space = runSpace }
        if complete { built = Date() }
        save()
        let secs = Date().timeIntervalSince(t0)
        progress = complete ? "re-embedded \(grouped(done)) in \(String(format: "%.1f", secs)) s (\(Int(Double(done) / max(secs, 0.001))) texts/s, \(via))"
                            : "\(stopRequested ? "stopped" : "stopped early") after \(grouped(done))/\(grouped(fresh.count + pending)) re-embedded"
        HubLog.shared.add(.info, "re-embed done — " + progress)
    }

    /// Embeds the docs at `todo`, 32 per call, one log line per call, every vector in the space `want` (when known);
    /// stops at Stop. Returns how many got a vector — the first `done` of `todo`, in order.
    private func embedChunks(_ fresh: inout [IndexDoc], _ todo: [Int], want: String?) async -> Int {
        let t0 = Date()
        let before = bundled()?.activity()
        defer { logSplit(from: before) }
        var done = 0
        let chunks = stride(from: 0, to: todo.count, by: 32).map { Array(todo[$0..<min($0 + 32, todo.count)]) }
        for (n, chunk) in chunks.enumerated() {
            if stopRequested { break }
            let inputs = chunk.map { fresh[$0].text ?? fresh[$0].title }
            guard let vecs = await embed(inputs, log: "call \(n + 1)/\(chunks.count)", want: want), vecs.count == chunk.count else {
                problem = refusal ?? "embedding stopped after \(done)/\(todo.count) — " + noEmbedderProblem()
                break
            }
            for (k, idx) in chunk.enumerated() { fresh[idx].vec = vecs[k] }
            done += chunk.count
            let rate = Double(done) / max(0.001, Date().timeIntervalSince(t0))
            textDone = done; rateHistory.append(rate); if rateHistory.count > 60 { rateHistory.removeFirst() }
            progress = "embedding \(via.hasPrefix("in-process") ? via : "via 127.0.0.1:11435") \(done)/\(todo.count) · \(Int(rate)) texts/s"
        }
        return done
    }

    /// Where the in-process time of a run went, summed over the workers: the Neural Engine's predict calls versus the
    /// CPU work around them (staging the inputs, pooling the outputs) — says whether the ANE or the CPU is the limit.
    private func logSplit(from before: EmbedActivity?) {
        guard let before, let after = bundled()?.activity(), after.calls > before.calls else { return }
        let predict = after.predictSeconds - before.predictSeconds, stage = after.stageSeconds - before.stageSeconds
        let pool = after.poolSeconds - before.poolSeconds, total = max(predict + stage + pool, 0.001)
        HubLog.shared.add(.info, String(format: "time split over %d calls: predict %.1f s (%.0f%%) · CPU staging %.1f s (%.0f%%) · pooling %.1f s (%.0f%%) · %.0f ms predict per call",
                                        after.calls - before.calls, predict, predict / total * 100, stage, stage / total * 100,
                                        pool, pool / total * 100, predict / Double(after.calls - before.calls) * 1000))
    }

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

    public func search(_ q: String, kind: String? = nil, openOnly: Bool = false) async {
        let q = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { hits = []; return }
        searching = true; defer { searching = false }
        let t0 = Date()
        guard let v = await embed([Self.queryText(q)], want: docs.isEmpty ? nil : space)?.first else {
            problem = refusal ?? noEmbedderProblem(); return
        }
        let t1 = Date()
        let pool = docs.filter { (kind == nil || $0.kind == kind) && (!openOnly || $0.state == "OPEN") }
        hits = pool.map { d in IndexHit(doc: d, score: d.vec.count == v.count ? vDSP.dot(d.vec, v) : -1) }   // unit vectors: dot = cosine
            .sorted { $0.score > $1.score }.prefix(25).map { $0 }
        if !running { problem = nil }
        HubLog.shared.add(.search, String(format: "\"%@\" · query embedded in %.0f ms (%@) · ranked %@ in %.1f ms · best %.0f%%",
                                          q, t1.timeIntervalSince(t0) * 1000, via, grouped(pool.count),
                                          Date().timeIntervalSince(t1) * 1000, Double(hits.first?.score ?? 0) * 100))
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
    private var refusal: String?

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
