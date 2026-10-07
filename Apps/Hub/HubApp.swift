import SwiftUI
import OracleKit
import ANEEmbedCore

/// ARRA Oracles — the landing app: every herdr session, every space, every oracle; a click opens the oracle's app.
@main
struct HubApp: App {
    @StateObject private var store = HubStore()
    @AppStorage("hub.menuBar") private var menuBar = true
    init() {
        let mode = UserDefaults.standard.string(forKey: "hub.engineMode") ?? "ane"   // ANE / GPU / Both, the engine card's picker
        Task { await BundledANE.load(mode: mode) }   // the bundled model loads in the background and installs itself
        ModelLoad.shared.reload = { mode in Task { await BundledANE.load(mode: mode) } }
        MapLayoutEngine.install()   // Map page: UMAP in-process (Apple's Rust crate)
        ModelLoad.shared.retry = { Task { await BundledANE.load(mode: UserDefaults.standard.string(forKey: "hub.engineMode") ?? "ane") } }
        MCPServer.serve(name: "arra-oracles", port: 4790) { GHIndex.shared }   // agents search the fleet's issues, PRs and notes
        if let ane = ANEMonitor() { ANEMeter.shared.reader = { ane.read().map { ($0.utilizationPercent, $0.bandwidthGBs) } } }
    }
    var body: some Scene { HubScene(store: store, menuBar: $menuBar) }
}
