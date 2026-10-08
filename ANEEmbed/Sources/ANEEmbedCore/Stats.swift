import Foundation

/// Counters the menu bar and /health read: totals, a texts/s window, what is running
/// right now (requests in flight, workers busy) and the last few requests.
/// Shared by every worker: all its state is behind `lock`.
public final class Stats: @unchecked Sendable {
    public struct RequestLog: Codable, Identifiable {
        public var id: Int
        public var at: Date
        public var texts: Int, tokens: Int
        public var milliseconds: Double
    }

    public struct Snapshot: Codable {
        public var requests = 0, texts = 0, tokens = 0, slots = 0, errors = 0
        public var seconds = 0.0
        /// Summed over workers: CPU staging, Core ML predict, CPU pooling + projection.
        public var stageSeconds = 0.0, predictSeconds = 0.0, poolSeconds = 0.0, calls = 0
        public var textsPerSecond = 0.0, tokensPerSecond = 0.0
        public var inFlight = 0
        public var busyWorkers: [Bool] = []
        public var lastRequests: [RequestLog] = []
        public init() {}
    }

    private var totals = Snapshot()
    private var window: [(at: Date, texts: Int, tokens: Int)] = []
    private var log: [RequestLog] = []
    private let lock = NSLock()

    func begin() { lock.withLock { totals.inFlight += 1 } }

    func end() { lock.withLock { totals.inFlight -= 1 } }

    func setBusy(worker: Int, of count: Int, _ busy: Bool) {
        lock.withLock {
            if totals.busyWorkers.count != count { totals.busyWorkers = Array(repeating: false, count: count) }
            totals.busyWorkers[worker] = busy
        }
    }

    func record(texts: Int, tokens: Int, slots: Int, seconds: Double) {
        lock.withLock {
            totals.requests += 1; totals.texts += texts; totals.tokens += tokens
            totals.slots += slots; totals.seconds += seconds
            window.append((Date(), texts, tokens))
            log.append(RequestLog(id: totals.requests, at: Date(), texts: texts, tokens: tokens, milliseconds: seconds * 1000))
            if log.count > 8 { log.removeFirst(log.count - 8) }
        }
    }

    func recordCall(stage: Double, predict: Double, pool: Double) {
        lock.withLock {
            totals.stageSeconds += stage; totals.predictSeconds += predict
            totals.poolSeconds += pool; totals.calls += 1
        }
    }

    public func recordError() { lock.withLock { totals.errors += 1 } }

    public func resetForBench() { reset() }

    func reset() {
        lock.withLock {
            let busy = totals.busyWorkers
            totals = Snapshot(); totals.busyWorkers = busy
            window = []; log = []
        }
    }

    public func snapshot(window seconds: TimeInterval = 10) -> Snapshot {
        lock.withLock {
            let cutoff = Date().addingTimeInterval(-seconds)
            window.removeAll { $0.at < cutoff }
            var s = totals
            s.textsPerSecond = Double(window.reduce(0) { $0 + $1.texts }) / seconds
            s.tokensPerSecond = Double(window.reduce(0) { $0 + $1.tokens }) / seconds
            s.lastRequests = log.reversed()
            return s
        }
    }
}
