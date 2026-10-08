import Foundation

/// Search every oracle's GitHub issues and PRs by meaning, embedded on the Apple Neural Engine.
///
/// The ANE service is Chippy (Swift CoreML, `127.0.0.1:11435`, Ollama-style `POST /api/embed`) running
/// EmbeddingGemma 2 (`embeddinggemma2:ane-w16`). Start simple (Nat, 2026-10-07): issues + PRs first, the ψ vault later.
/// Stored as one JSON file — a few thousand 768-d vectors fit in memory and a brute-force cosine is instant.
/// Only new or changed items are embedded again (a hash of the text that was embedded).
public struct IndexDoc: Codable, Identifiable, Hashable, Sendable {
    public var id: String {
        kind == "note" ? (number == 0 ? "note:\(url)" : "note:\(url)#\(number)") : kind == "history" ? "hist:\(hash)" : "\(repo)#\(number)"
    }
    public let repo: String          // owner/name
    public let kind: String          // issue · pr · note (ψ vault: url file://, state its folder) · history (a session:
                                     // state user|assistant, url the resume command, number the piece of a long message)
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
    /// Where the model was loaded from (the app sets it).
    @Published public var root = ""
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
