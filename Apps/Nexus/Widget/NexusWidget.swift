import WidgetKit
import SwiftUI
import OracleKit

@main
struct NexusWidgets: WidgetBundle {
    var body: some Widget { NexusStatusWidget() }
}

/// The configuration lives HERE, in the extension, with literal names (like homelab's working widget).
/// Built inside the OracleKit package it crashed at load: WidgetKit asserts on configurations made in a package.
struct NexusStatusWidget: Widget {
    let kind = "NexusStatus"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OracleProvider(config: .nexus)) { OracleWidgetView(entry: $0) }
            .configurationDisplayName("Nexus status")
            .description("Nexus: working panes, open PRs, issues and inbox.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
