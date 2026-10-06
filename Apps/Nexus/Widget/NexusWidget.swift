import WidgetKit
import SwiftUI
import OracleKit

@main
struct NexusWidgets: WidgetBundle {
    var body: some Widget { NexusStatusWidget() }
}

/// The configuration lives HERE, in the extension, with literal names (like homelab's working widget).
/// Built inside the OracleKit package it crashed at load: WidgetKit asserts on configurations made in a package.
/// NEVER change `kind`: widgets already on a desktop are bound to it. Renaming it (2026-10-07) left every
/// placed widget on a grey placeholder — chronod kept reloading the old kind and failed (CHSErrorDomain 1050).
struct NexusStatusWidget: Widget {
    let kind = "oracle.status.nexus"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OracleProvider(config: .nexus)) { OracleWidgetView(entry: $0) }
            .configurationDisplayName("Nexus Oracle")
            .description("Nexus Oracle: working panes, open PRs, issues and inbox.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
