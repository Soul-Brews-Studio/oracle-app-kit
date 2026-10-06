import WidgetKit
import SwiftUI
import OracleKit

@main
struct NeoWidgets: WidgetBundle {
    var body: some Widget { NeoStatusWidget() }
}

/// The configuration lives HERE, in the extension, with literal names (like homelab's working widget).
/// Built inside the OracleKit package it crashed at load: WidgetKit asserts on configurations made in a package.
struct NeoStatusWidget: Widget {
    let kind = "NeoStatus"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OracleProvider(config: .neo)) { OracleWidgetView(entry: $0) }
            .configurationDisplayName("Neo status")
            .description("Neo: working panes, open PRs, issues and inbox.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}
