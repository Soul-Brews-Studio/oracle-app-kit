import WidgetKit
import SwiftUI
import OracleKit

@main
struct NexusWidgets: WidgetBundle {
    var body: some Widget { NexusStatusWidget() }
}

struct NexusStatusWidget: Widget {
    var body: some WidgetConfiguration { OracleWidgetKit.configuration(.nexus) }
}
