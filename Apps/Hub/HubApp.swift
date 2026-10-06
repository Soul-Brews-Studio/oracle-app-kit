import SwiftUI
import OracleKit

/// ARRA Oracles — the landing app: every herdr session, every space, every oracle; a click opens the oracle's app.
@main
struct HubApp: App {
    @StateObject private var store = HubStore()
    @AppStorage("hub.menuBar") private var menuBar = true
    var body: some Scene { HubScene(store: store, menuBar: $menuBar) }
}
