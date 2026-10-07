// swift-tools-version:5.9
import PackageDescription

// The ANE embedder of Soul Brews Studio's embedding service (Chippy), copied in so the ARRA Oracles hub can
// embed in-process with no server: CoreML on the Neural Engine + HF `tokenizers` (Rust) behind a C ABI.
// Build the tokenizer first (the hub's build does it):  cargo build --release --manifest-path tokenizer-ffi/Cargo.toml
let ffiLib = Context.packageDirectory + "/tokenizer-ffi/target/release"

let package = Package(
    name: "ANEEmbed",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ANEEmbedCore", targets: ["ANEEmbedCore"])],
    targets: [
        .systemLibrary(name: "CTokenizerFFI", path: "tokenizer-ffi/include"),
        .target(name: "ANEEmbedCore", dependencies: ["CTokenizerFFI"],
                linkerSettings: [.unsafeFlags(["-L", ffiLib])]),
    ]
)
