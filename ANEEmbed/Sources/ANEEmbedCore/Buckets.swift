/// One Core ML call: a bucket length and the request rows it carries (at most
/// slots / bucket of them). Same grouping as ane_runtime.assign_jobs: rows go to the
/// smallest bucket that holds them, in request order, chunked by the bucket's batch.
public struct Job: Equatable, Sendable {
    public let bucket: Int
    public let rows: [Int]
}

public func assignJobs(lengths: [Int], buckets: [Int], slots: Int = 2048) throws -> [Job] {
    let sorted = buckets.sorted()
    guard let top = sorted.last, top == slots, sorted.allSatisfy({ $0 > 0 }) else {
        throw EmbedError.input("buckets must be positive and end at \(slots)")
    }
    var grouped: [Int: [Int]] = [:]
    for (row, length) in lengths.enumerated() {
        guard length > 0, length <= top else { throw EmbedError.input("row \(row) has \(length) tokens") }
        grouped[sorted.first { $0 >= length }!, default: []].append(row)
    }
    var jobs: [Job] = []
    for bucket in sorted {
        let rows = grouped[bucket] ?? []
        let batch = max(1, slots / bucket)
        for start in stride(from: 0, to: rows.count, by: batch) {
            jobs.append(Job(bucket: bucket, rows: Array(rows[start..<min(start + batch, rows.count)])))
        }
    }
    return jobs
}
