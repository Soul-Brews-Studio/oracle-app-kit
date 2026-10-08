import WidgetKit
import SwiftUI
import OracleKit

@main
struct TranscriberWidgets: WidgetBundle {
    var body: some Widget { TranscriberStatusWidget() }
}

/// The configuration lives HERE, in the extension, with literal names (like homelab's working widget).
/// Built inside the OracleKit package it crashed at load: WidgetKit asserts on configurations made in a package.
/// NEVER change `kind`: widgets already on a desktop are bound to it. Renaming it (2026-10-07) left every
/// placed widget on a grey placeholder — chronod kept reloading the old kind and failed (CHSErrorDomain 1050).
struct TranscriberStatusWidget: Widget {
    let kind = "oracle.status.transcriber"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: OracleProvider(config: .transcriber)) { OracleWidgetView(entry: $0) }
            .configurationDisplayName("Transcriber Oracle")
            .description("Transcriber Oracle: working panes, open PRs, issues and inbox.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
