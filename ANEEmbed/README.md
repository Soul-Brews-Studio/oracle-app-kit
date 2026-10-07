# ANEEmbed — the in-process ANE embedder

EmbeddingGemma on the Apple Neural Engine, as a library: copied from Chippy, Soul Brews Studio's menu-bar
embedding service, so the ARRA Oracles hub needs no embedding server.

- `ANEEmbedCore`: `Assets(root:)` → `Engine(assets:workers:progress:)` → `embed([String]) -> [[Float]]` (unit vectors).
  `embedCounting` also returns the token count; `stats.snapshot()` gives texts/s, tokens/s, busy workers, last calls.
- Loading: every bucket loads with the async Core ML API, and `progress` gets a `LoadStep` per part (worker, bucket,
  ANE or CPU, seconds). An app's first launch makes the Neural Engine compile each bucket once (~30 s each on an M5,
  ~5 min in all); macOS caches the result per app, so later launches load in seconds.
- `ANEMonitor`: the Neural Engine's utilization % and memory bandwidth for the whole Mac, from IOReport (a private
  library loaded with `dlopen`; no root, no entitlement). `nil` on a Mac without the ANE channels.
- Changed from Chippy's copy: the async loading and `LoadStep`, `embedCounting`, tokens/s in `Stats`.
- `tokenizer-ffi/.cargo/config.toml` pins `MACOSX_DEPLOYMENT_TARGET = 14.0`, so the C parts of the tokenizer are not
  built for a newer macOS than the app supports.
- `tokenizer-ffi`: Hugging Face `tokenizers` 0.23.2 (Rust) behind a C ABI. Built by the hub's build step:
  `cargo build --release --manifest-path ANEEmbed/tokenizer-ffi/Cargo.toml`
- Model files are not in git. The hub's build copies an exported model folder (manifest.json, embed_scaled.f16,
  tokenizer/, compiled/*.mlmodelc) from `~/Library/Application Support/ANEEmbed/embeddinggemma2-w16` into the app.
