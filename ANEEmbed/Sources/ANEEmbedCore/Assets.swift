import Foundation

/// The files export_assets.py writes, read once. The big arrays are memory-mapped, so
/// the 384 MB token table costs page cache, not a copy.
public struct Manifest: Decodable {
    public let model_tag: String
    public let vector_space_identity: String
    public let hf_revision: String
    public let vocab: Int
    public let hidden: Int
    /// v1 only: pooled @ dense1 @ dense2 on the CPU. A "pooled" package (EmbeddingGemma 2) has none.
    public let dense1: [Int]?
    public let dense2: [Int]?
    /// "pooled": the package outputs `pooled` [batch, output_dim], already mean-pooled and projected;
    /// absent (v1): it outputs `hidden` and the CPU pools and projects.
    public let format: String?
    public let output_dim: Int?
    /// Buckets loaded on the CPU instead of the Neural Engine (v2: 2,048 loses precision on the ANE).
    public let cpu_buckets: [Int]?
    public let slots_per_call: Int
    public let max_tokens: Int
    public let buckets: [Int]
    public let packages: [String: String]
}

public final class Assets {
    public let root: URL
    public let manifest: Manifest
    let embedScaled: Data      // vocab x hidden, float16
    let dense1: Data           // hidden x d1, float32 row-major (empty for a pooled package)
    let dense2: Data           // d1 x hidden, float32 row-major (empty for a pooled package)

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ANEEmbed/embeddinggemma-w16")
    }

    public init(root: URL = Assets.defaultRoot) throws {
        self.root = root
        manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        embedScaled = try Data(contentsOf: root.appendingPathComponent("embed_scaled.f16"), options: .alwaysMapped)
        let m = manifest
        guard embedScaled.count == m.vocab * m.hidden * 2 else { throw EmbedError.assets("token table size does not match manifest.json") }
        if m.format == "pooled" {
            guard m.output_dim != nil else { throw EmbedError.assets("a pooled manifest needs output_dim") }
            dense1 = Data(); dense2 = Data()
            return
        }
        dense1 = try Data(contentsOf: root.appendingPathComponent("dense1.f32"), options: .alwaysMapped)
        dense2 = try Data(contentsOf: root.appendingPathComponent("dense2.f32"), options: .alwaysMapped)
        guard let d1 = m.dense1, let d2 = m.dense2,
              dense1.count == d1.reduce(1, *) * 4, dense2.count == d2.reduce(1, *) * 4,
              d1 == [m.hidden, d1[1]], d2 == [d1[1], m.hidden]
        else { throw EmbedError.assets("array sizes do not match manifest.json") }
    }

    public var isPooled: Bool { manifest.format == "pooled" }

    /// <Application Support>/ANEEmbed/<name>, e.g. "embeddinggemma2-w16".
    public static func root(named name: String) -> URL {
        defaultRoot.deletingLastPathComponent().appendingPathComponent(name)
    }

    public var tokenizerFolder: URL { root.appendingPathComponent("tokenizer") }

    public func packageURL(bucket: Int) throws -> URL {
        guard let rel = manifest.packages[String(bucket)] else { throw EmbedError.assets("no package for bucket \(bucket)") }
        return root.appendingPathComponent(rel)
    }
}

public enum EmbedError: Error, CustomStringConvertible {
    case assets(String), input(String), runtime(String)
    public var description: String {
        switch self {
        case .assets(let s): return "assets: \(s)"
        case .input(let s): return "input: \(s)"
        case .runtime(let s): return "runtime: \(s)"
        }
    }
}
