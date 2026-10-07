#if os(macOS)
import Foundation
import OracleKit
import ANEEmbedCore

/// The EmbeddingGemma 2 model, run in-process on Core ML (Neural Engine and/or GPU). Nothing to install, no server
/// (Nat: "bundle it in the app, self contained"). The hub carries it in Resources/ANEModel and stages it into
/// Application Support; the oracle apps (Neo, Pulse, Nexus — shared source, Apps/Shared) carry no copy and load
/// that staged one, or the export it came from.
final class BundledANE: LocalEmbedding, @unchecked Sendable {
    let label: String, modelTag: String, space: String
    private let engine: Engine
    var workers: Int { engine.workerCount }
    private init(engine: Engine, assets: Assets) {
        self.engine = engine
        modelTag = assets.manifest.model_tag
        space = assets.manifest.vector_space_identity
        let d = engine.devices.map(\.rawValue)
        label = "bundled CoreML · in-process · " + Device.allCases.compactMap { dev in
            let n = d.filter { $0 == dev.rawValue }.count
            return n == 0 ? nil : n == 1 ? dev.rawValue : "\(dev.rawValue) × \(n)"
        }.joined(separator: " + ")
    }

    /// Loads the model the app carries and installs it as `GHIndex.loaded` (before publishing "finished", so whoever
    /// reacts to "finished" finds it). A build without the model is not an error: the HTTP service embeds instead.
    /// Where the workers run: "ane" (both on the Neural Engine), "gpu" (both on the GPU), "both" (one each).
    /// Any GPU use means two GPU workers (Nat): GPU = GPU × 2, Both = GPU × 2 + one ANE worker.
    static func devicesFor(_ mode: String) -> [Device] { mode == "gpu" ? [.gpu, .gpu] : mode == "both" ? [.gpu, .gpu, .ane] : [.ane, .ane] }
    /// Only the newest load installs itself, when the engine picker changes again while one is loading.
    @MainActor private static var generation = 0

    /// Sets the loaders without loading — an oracle app loads the model when its Memory page first asks for it.
    @MainActor static func installLazily() {
        UserDefaults.standard.register(defaults: ["hub.engineMode": "gpu"])   // GPU x2: ~9 s first load, no 4-min ANE compile
        ModelLoad.shared.reload = { mode in Task { await BundledANE.load(mode: mode) } }
        ModelLoad.shared.retry = { Task { await BundledANE.load(mode: UserDefaults.standard.string(forKey: "hub.engineMode") ?? "gpu") } }
    }

    /// Where the model is: in this app's bundle (the hub; staged before loading), the copy the hub staged, or the
    /// export in ~/Library/Application Support/ANEEmbed. Each must be complete: a manifest and every compiled bucket.
    static func modelRoot() -> (url: URL, bundled: Bool)? {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        func complete(_ u: URL) -> Bool {
            guard let a = try? Assets(root: u) else { return false }
            return a.manifest.buckets.allSatisfy { fm.fileExists(atPath: u.appendingPathComponent("compiled/\($0).mlmodelc").path) }
        }
        if let b = Bundle.main.resourceURL?.appendingPathComponent("ANEModel/embeddinggemma2-w16"), complete(b) { return (b, true) }
        let staged = support.appendingPathComponent("ARRA Oracles/ANEModel")
        for d in ((try? fm.contentsOfDirectory(at: staged, includingPropertiesForKeys: nil)) ?? []) where !d.lastPathComponent.hasPrefix(".") {
            if complete(d) { return (d, false) }
        }
        let export = support.appendingPathComponent("ANEEmbed/embeddinggemma2-w16")
        return complete(export) ? (export, false) : nil
    }

    static func load(mode: String = "ane") async {
        let mine = await MainActor.run { generation += 1; return generation }
        guard let found = modelRoot() else {
            await MainActor.run {
                ModelLoad.shared.markAbsent()
                HubLog.shared.add(.info, "no EmbeddingGemma 2 model on this Mac (the ARRA Oracles hub stages one) — embedding goes through 127.0.0.1:11435")
            }
            return
        }
        let root = found.url
        let t0 = Date()
        do {
            let assets = try Assets(root: found.bundled ? staged(root, identity: try Assets(root: root).manifest.vector_space_identity) : root)
            let devices = devicesFor(mode)
            await MainActor.run {
                ModelLoad.shared.begin(buckets: assets.manifest.buckets, workers: devices.count)
                HubLog.shared.add(.load, "loading \(assets.manifest.model_tag) on \(devices.map(\.rawValue).joined(separator: " + ")): \(assets.manifest.buckets.count) buckets per worker, CPU for \(assets.manifest.cpu_buckets ?? [])")
            }
            let engine = try await Engine(assets: assets, devices: devices) { step in
                await MainActor.run {
                    ModelLoad.shared.record(done: step.done, total: step.total, worker: step.worker, bucket: step.bucket,
                                            device: step.device, seconds: step.seconds)
                }
            }
            let secs = Date().timeIntervalSince(t0)
            let ane = BundledANE(engine: engine, assets: assets)
            let current = await MainActor.run { () -> Bool in
                guard mine == generation else { return false }   // the picker moved on: a newer load installs itself
                GHIndex.loaded = ane
                ModelLoad.shared.finish()
                HubLog.shared.add(.load, String(format: "ready in %.1f s · warm-up call %.0f ms · searches and batches now run in-process: %@",
                                                secs, engine.warmupSeconds * 1000, ane.label))
                return true
            }
            if current { await GHIndex.active?.checkParity() }
        } catch {
            NSLog("ARRA Oracles: bundled ANE model did not load: \(error)")
            await MainActor.run {
                ModelLoad.shared.fail("\(error)")
                HubLog.shared.add(.error, "bundled model did not load: \(error) — Retry on the engine card, or relaunch:  open -a \"ARRA Oracles\"")
            }
        }
    }

    /// The bundled model, staged once into ~/Library/Application Support/ARRA Oracles/ANEModel/<identity> and loaded
    /// from there. The Neural Engine's compile cache is tied to each model file's identity (inode): files re-created by
    /// a reinstall, a Finder copy or an update would pay the whole first-launch compile again (~4 min), while a staged
    /// copy keeps its files, so later launches load in seconds. On APFS the copy is a clone: no extra disk.
    /// Copies staged for another model are removed. Falls back to the bundle itself if staging fails.
    private static func staged(_ bundled: URL, identity: String) -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ARRA Oracles/ANEModel", isDirectory: true)
        let dir = base.appendingPathComponent(identity.replacingOccurrences(of: ":", with: "_"), isDirectory: true)
        let log = { (kind: HubLog.Kind, text: String) in Task { @MainActor in HubLog.shared.add(kind, text) } }
        if let a = try? Assets(root: dir), a.manifest.vector_space_identity == identity,
           a.manifest.buckets.allSatisfy({ fm.fileExists(atPath: dir.appendingPathComponent("compiled/\($0).mlmodelc").path) }) {
            return dir
        }
        do {
            try fm.createDirectory(at: base, withIntermediateDirectories: true)
            for old in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent != dir.lastPathComponent {
                try? fm.removeItem(at: old)
                log(.load, "removed a model staged for another vector space: \(old.lastPathComponent)")
            }
            let tmp = base.appendingPathComponent(".staging-\(ProcessInfo.processInfo.processIdentifier)")
            try? fm.removeItem(at: tmp)
            let t0 = Date()
            try fm.copyItem(at: bundled, to: tmp)   // APFS: clonefile
            try? fm.removeItem(at: dir)
            try fm.moveItem(at: tmp, to: dir)
            log(.load, String(format: "staged the model into Application Support in %.1f s (an APFS clone) — the Neural Engine compiles it once more for its new home", Date().timeIntervalSince(t0)))
            return dir
        } catch {
            log(.error, "could not stage the model (\(error)) — loading it from the app bundle")
            return bundled
        }
    }

    func embed(_ texts: [String]) async throws -> (vectors: [[Float]], tokens: Int) { try await engine.embedCounting(texts) }

    func activity() -> EmbedActivity {
        let s = engine.stats.snapshot()
        var a = EmbedActivity()
        a.texts = s.texts; a.tokens = s.tokens; a.requests = s.requests; a.calls = s.calls
        a.textsPerSecond = s.textsPerSecond; a.tokensPerSecond = s.tokensPerSecond
        a.busy = s.busyWorkers
        a.devices = engine.devices.map(\.rawValue)
        a.stageSeconds = s.stageSeconds; a.predictSeconds = s.predictSeconds; a.poolSeconds = s.poolSeconds
        a.last = s.lastRequests.map { EmbedActivity.Call(id: $0.id, at: $0.at, texts: $0.texts, tokens: $0.tokens, ms: $0.milliseconds) }
        return a
    }
}
#endif
