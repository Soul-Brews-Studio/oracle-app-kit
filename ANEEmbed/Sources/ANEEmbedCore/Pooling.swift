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
    // mid = pooled · dense1, out = mid · dense2: row-major products with vDSP (cblas_sgemm is deprecated since macOS 13.3)
    assets.dense1.withUnsafeBytes { d1 in
        vDSP_mmul(pooled, 1, d1.bindMemory(to: Float.self).baseAddress!, 1, &mid, 1,
                  vDSP_Length(rows), vDSP_Length(inner), vDSP_Length(width))
    }
    assets.dense2.withUnsafeBytes { d2 in
        vDSP_mmul(mid, 1, d2.bindMemory(to: Float.self).baseAddress!, 1, &out, 1,
                  vDSP_Length(rows), vDSP_Length(width), vDSP_Length(inner))
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
