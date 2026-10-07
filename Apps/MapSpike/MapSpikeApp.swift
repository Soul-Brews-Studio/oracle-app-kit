import SwiftUI

/// Issue #32. Launch: MapSpike -mapData <dir with neo.xyz, neo.kind, neo.titles.json> [-edges 500] [-orbit 20]
@main
struct MapSpikeApp: App {
    var body: some Scene {
        WindowGroup { MapSpikeView().frame(minWidth: 900, minHeight: 700) }
    }
}
