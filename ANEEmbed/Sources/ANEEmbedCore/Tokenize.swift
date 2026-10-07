import CTokenizerFFI
import Foundation

/// HF `tokenizers` 0.23.2 (Rust) through tokenizer-ffi: the same library and version the
/// Python service encodes with, so ids match by construction. It replaced swift-transformers,
/// whose pure-Swift BPE was 5-14x slower on real session text (2026-10-01). Batches are
/// encoded in parallel inside the library. Truncation keeps maxTokens including specials.
public final class TextTokenizer: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(folder: URL, maxTokens: Int) throws {
        let path = folder.appendingPathComponent("tokenizer.json").path
        guard let handle = tok_new(path, maxTokens) else { throw EmbedError.assets("cannot load \(path)") }
        self.handle = handle
    }

    deinit { tok_free(handle) }

    public func encode(_ texts: [String]) throws -> [[Int]] {
        guard !texts.isEmpty else { return [] }
        var cStrings = texts.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var lens = [Int](repeating: 0, count: texts.count)
        var ids: UnsafeMutablePointer<UInt32>?
        let status = cStrings.withUnsafeMutableBufferPointer { ptrs in
            ptrs.withMemoryRebound(to: UnsafePointer<CChar>?.self) { constPtrs in
                tok_encode_batch(handle, constPtrs.baseAddress, texts.count, &ids, &lens)
            }
        }
        guard status == 0, let ids else { throw EmbedError.input("tokenizer failed (invalid UTF-8?)") }
        let total = lens.reduce(0, +)
        defer { tok_free_ids(ids, total) }
        var out: [[Int]] = []
        out.reserveCapacity(texts.count)
        var offset = 0
        for len in lens {
            out.append((offset..<offset + len).map { Int(ids[$0]) })
            offset += len
        }
        return out
    }

    public func encode(_ text: String) -> [Int] { (try? encode([text]))?.first ?? [] }
}
