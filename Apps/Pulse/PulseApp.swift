import SwiftUI
import OracleKit

@main
struct PulseApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(OracleAppDelegate.self) var delegate
    #endif
    @StateObject private var store = OracleStore(config: .pulse.with(extras: PulseExtras.extras))
    init() {
        #if os(macOS)
        BundledANE.installLazily()   // Memory page: EmbeddingGemma 2 in-process, loaded when the page first opens
        MCPServer.serve(name: "pulse-memory", port: 4792) { GHIndex.history(OracleConfig.pulse.repoSlug) }   // agents search Pulse's memory
        #endif
    }
    @AppStorage("oracle.menuBar") private var menuBar = false      // the oracle's tray: off until switched on
    var body: some Scene { OracleScene(store: store, menuBar: $menuBar) }
}
