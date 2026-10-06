import WidgetKit
import SwiftUI
import OracleKit

@main
struct PulseWidgets: WidgetBundle {
    var body: some Widget { PulseStatusWidget() }
}

/// The configuration lives HERE, in the extension, with literal names (like homelab's working widget).
/// Built inside the OracleKit package it crashed at load: WidgetKit asserts on configurations made in a package.
struct PulseStatusWidget: Widget {
    let kind = "PulseStatus"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OracleProvider(config: .pulse)) { OracleWidgetView(entry: $0) }
            .configurationDisplayName("Pulse status")
            .description("Pulse: working panes, open PRs, issues and inbox.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
