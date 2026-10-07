import CoreML
import Foundation

/// One worker: its own MLModel per bucket, run on its own serial queue. Several workers
/// keep the ANE fed while another worker stages inputs or pools outputs on the CPU —
/// the same reason the Python service runs two worker processes.
final class Worker {
    let models: [Int: MLModel]
    let queue: DispatchQueue
    let index: Int
    let count: Int

    /// Loads every bucket, small first (the first answers come soonest), with the async Core ML API so a first-launch
    /// compile — the Neural Engine compiles each bucket once per app, ~30 s each — never blocks a thread.
    /// `loaded(bucket, device, seconds)` after each one, awaited, so a caller sees them in order.
    init(index: Int, of count: Int, compiled: [Int: URL], cpuBuckets: Set<Int> = [],
         loaded: ((Int, String, Double) async -> Void)? = nil) async throws {
        self.index = index
        self.count = count
        var models: [Int: MLModel] = [:]
        for (bucket, url) in compiled.sorted(by: { $0.key < $1.key }) {
            let config = MLModelConfiguration()
            let cpu = cpuBuckets.contains(bucket)
            config.computeUnits = cpu ? .cpuOnly : .cpuAndNeuralEngine
            if #available(macOS 14.4, *) { config.modelDisplayName = "embed-\(bucket)-w\(index + 1)" }   // names the load in Instruments and os_log
            let t0 = DispatchTime.now().uptimeNanoseconds
            models[bucket] = try await MLModel.load(contentsOf: url, configuration: config)
            await loaded?(bucket, cpu ? "CPU" : "ANE", Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e9)
        }
        self.models = models
        queue = DispatchQueue(label: "ane-embed.worker.\(index)", qos: .userInitiated)
    }

    func run(_ job: Job, tokenIds: [[Int]], assets: Assets, stats: Stats) async throws -> [[Float]] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                stats.setBusy(worker: self.index, of: self.count, true)
                defer { stats.setBusy(worker: self.index, of: self.count, false) }
                do {
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let (embeds, mask) = try stageInputs(job: job, tokenIds: tokenIds, assets: assets)
                    let input = try MLDictionaryFeatureProvider(dictionary: ["embeds": embeds, "mask": mask])
                    let t1 = DispatchTime.now().uptimeNanoseconds
                    let output = assets.isPooled ? "pooled" : "hidden"
                    guard let model = self.models[job.bucket],
                          let array = try model.prediction(from: input).featureValue(for: output)?.multiArrayValue
                    else { throw EmbedError.runtime("no \(output) output for bucket \(job.bucket)") }
                    let t2 = DispatchTime.now().uptimeNanoseconds
                    let vectors = assets.isPooled ? normalizePooled(array, job: job)
                                                  : projectHidden(array, job: job, tokenIds: tokenIds, assets: assets)
                    let t3 = DispatchTime.now().uptimeNanoseconds
                    stats.recordCall(stage: Double(t1 - t0) / 1e9, predict: Double(t2 - t1) / 1e9, pool: Double(t3 - t2) / 1e9)
                    continuation.resume(returning: vectors)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// One model part loaded: which worker and bucket, on what, and how long it took. The first load of a bucket in an
/// app makes the Neural Engine compile it (~30 s); after that the system cache answers in well under a second.
public struct LoadStep: Sendable {
    public let done: Int, total: Int
    public let worker: Int, bucket: Int
    public let device: String          // "ANE" or "CPU"
    public let seconds: Double
}

public final class Engine {
    public let assets: Assets
    public let stats = Stats()
    /// HF tokenizers (Rust): encodes a whole batch in parallel internally.
    let tokenizer: TextTokenizer
    let workers: [Worker]
    var next = 0
    public var tokenizeSeconds = 0.0
    let lock = NSLock()

    /// Compiles each bucket's mlpackage once into <assets>/compiled, then loads `workers` copies of every bucket on
    /// CPU + Neural Engine. `progress` after each model part (buckets × workers), so a caller can show the first
    /// launch's compile — minutes in all — and see the later, cached launches take seconds.
    public init(assets: Assets, workers count: Int = 2, progress: ((LoadStep) async -> Void)? = nil) async throws {
        self.assets = assets
        tokenizer = try TextTokenizer(folder: assets.tokenizerFolder, maxTokens: assets.manifest.max_tokens)
        var compiled: [Int: URL] = [:]
        let cacheDir = assets.root.appendingPathComponent("compiled")
        for bucket in assets.manifest.buckets {
            let target = cacheDir.appendingPathComponent("\(bucket).mlmodelc")
            if !FileManager.default.fileExists(atPath: target.path) {   // compile it once, from the exported package
                guard let package = try? assets.packageURL(bucket: bucket),
                      FileManager.default.fileExists(atPath: package.path) else {
                    throw EmbedError.assets("\(target.path) is missing, and so is the package to compile it from")
                }
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                let temp = try await MLModel.compileModel(at: package)
                try FileManager.default.moveItem(at: temp, to: target)
            }
            compiled[bucket] = target
        }
        let cpu = Set(assets.manifest.cpu_buckets ?? [])
        let n = max(1, count)
        let total = compiled.count * n
        var done = 0
        var loaded: [Worker] = []
        for w in 0..<n {
            loaded.append(try await Worker(index: w, of: n, compiled: compiled, cpuBuckets: cpu) { bucket, device, seconds in
                done += 1
                await progress?(LoadStep(done: done, total: total, worker: w, bucket: bucket, device: device, seconds: seconds))
            })
        }
        workers = loaded
        let t0 = Date()
        _ = try await embed(["warmup"])
        warmupSeconds = Date().timeIntervalSince(t0)
        stats.reset()
    }

    /// The first call after loading (one short text), in seconds.
    public private(set) var warmupSeconds = 0.0

    public var workerCount: Int { workers.count }

    func encode(_ texts: [String]) throws -> [[Int]] { try tokenizer.encode(texts) }

    /// Ordered unit vectors for `texts`. Jobs go round-robin across workers.
    public func embed(_ texts: [String]) async throws -> [[Float]] { try await embedCounting(texts).vectors }

    /// `embed`, plus how many tokens the texts came to — for a caller's speed log.
    public func embedCounting(_ texts: [String]) async throws -> (vectors: [[Float]], tokens: Int) {
        guard !texts.isEmpty else { return ([], 0) }
        stats.begin()
        defer { stats.end() }
        let started = Date()
        let tokenIds = try encode(texts)
        lock.withLock { tokenizeSeconds += Date().timeIntervalSince(started) }
        let jobs = try assignJobs(lengths: tokenIds.map(\.count), buckets: assets.manifest.buckets,
                                  slots: assets.manifest.slots_per_call)
        let picked: [Worker] = lock.withLock {
            defer { next += jobs.count }
            return jobs.indices.map { workers[(next + $0) % workers.count] }
        }
        var out = [[Float]](repeating: [], count: texts.count)
        try await withThrowingTaskGroup(of: (Job, [[Float]]).self) { group in
            for (job, worker) in zip(jobs, picked) {
                group.addTask { (job, try await worker.run(job, tokenIds: tokenIds, assets: self.assets, stats: self.stats)) }
            }
            for try await (job, vectors) in group {
                for (row, vector) in zip(job.rows, vectors) { out[row] = vector }
            }
        }
        let tokens = tokenIds.reduce(0) { $0 + $1.count }
        stats.record(texts: texts.count, tokens: tokens,
                     slots: jobs.reduce(0) { $0 + max(1, assets.manifest.slots_per_call / $1.bucket) * $1.bucket },
                     seconds: Date().timeIntervalSince(started))
        return (out, tokens)
    }
}
