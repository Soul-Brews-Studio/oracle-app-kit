import WidgetKit
import SwiftUI
import OracleKit

@main
struct MaeonWidgets: WidgetBundle {
    var body: some Widget { MaeonStatusWidget() }
}

/// The configuration lives HERE, in the extension, with literal names (like homelab's working widget).
/// Built inside the OracleKit package it crashed at load: WidgetKit asserts on configurations made in a package.
/// NEVER change `kind`: widgets already on a desktop are bound to it. Renaming it (2026-10-07) left every
/// placed widget on a grey placeholder — chronod kept reloading the old kind and failed (CHSErrorDomain 1050).
struct MaeonStatusWidget: Widget {
    let kind = "oracle.status.maeon"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OracleProvider(config: .maeon)) { OracleWidgetView(entry: $0) }
            .configurationDisplayName("Maeon Oracle")
            .description("Maeon Oracle: working panes, open PRs, issues and inbox.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
