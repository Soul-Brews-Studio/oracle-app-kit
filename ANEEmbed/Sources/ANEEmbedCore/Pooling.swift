import Accelerate
import CoreML

/// ane_runtime.project_hidden then normalize_vectors: mean over each row's real tokens
/// (float32), pooled @ dense1 @ dense2, then L2 normalize. `hidden` is the model's
/// [batch, 768, 1, bucket] float16 output; strides are read, not assumed.
func projectHidden(_ hidden: MLMultiArray, job: Job, tokenIds: [[Int]], assets: Assets) -> [[Float]] {
    let width = assets.manifest.hidden
    let inner = assets.manifest.dense1![1]
    let rows = job.rows.count
    let strides = hidden.strides.map(\.intValue)
    var pooled = [Float](repeating: 0, count: rows * width)
    hidden.withUnsafeBytes { raw in
        let h = raw.bindMemory(to: Float16.self)
        for (b, row) in job.rows.enumerated() {
            let length = tokenIds[row].count
            for k in 0..<width {
                var sum: Float = 0
                let base = b * strides[0] + k * strides[1]
                for t in 0..<length { sum += Float(h[base + t * strides[3]]) }
                pooled[b * width + k] = sum / Float(length)
            }
        }
    }
    var mid = [Float](repeating: 0, count: rows * inner)
    var out = [Float](repeating: 0, count: rows * width)
    assets.dense1.withUnsafeBytes { d1 in
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(rows), Int32(inner), Int32(width),
                    1, pooled, Int32(width), d1.bindMemory(to: Float.self).baseAddress!, Int32(inner), 0, &mid, Int32(inner))
    }
    assets.dense2.withUnsafeBytes { d2 in
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, Int32(rows), Int32(width), Int32(inner),
                    1, mid, Int32(inner), d2.bindMemory(to: Float.self).baseAddress!, Int32(width), 0, &out, Int32(width))
    }
    return (0..<rows).map { r in
        let v = Array(out[r * width..<(r + 1) * width])
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / norm }
    }
}

/// A pooled package (EmbeddingGemma 2) already mean-pooled and projected on the ANE:
/// `pooled` is [batch, dim] float16; only the L2 normalisation is left, in float32.
func normalizePooled(_ pooled: MLMultiArray, job: Job) -> [[Float]] {
    let strides = pooled.strides.map(\.intValue)
    let dim = pooled.shape[1].intValue
    var out: [[Float]] = []
    pooled.withUnsafeBytes { raw in
        let p = raw.bindMemory(to: Float16.self)
        for b in 0..<job.rows.count {
            var v = (0..<dim).map { Float(p[b * strides[0] + $0 * strides[1]]) }
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            if norm > 0 { v = v.map { $0 / norm } }
            out.append(v)
        }
    }
    return out
}
