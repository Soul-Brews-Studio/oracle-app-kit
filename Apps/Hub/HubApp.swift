import SwiftUI
import OracleKit
import ANEEmbedCore

/// ARRA Oracles — the landing app: every herdr session, every space, every oracle; a click opens the oracle's app.
@main
struct HubApp: App {
    @StateObject private var store = HubStore()
    @AppStorage("hub.menuBar") private var menuBar = true
    init() {
        Task { await BundledANE.load() }   // the bundled ANE model loads in the background and installs itself
        ModelLoad.shared.retry = { Task { await BundledANE.load() } }
        if let ane = ANEMonitor() { ANEMeter.shared.reader = { ane.read().map { ($0.utilizationPercent, $0.bandwidthGBs) } } }
    }
    var body: some Scene { HubScene(store: store, menuBar: $menuBar) }
}
