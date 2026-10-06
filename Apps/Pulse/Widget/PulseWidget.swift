import WidgetKit
import SwiftUI
import OracleKit

@main
struct PulseWidgets: WidgetBundle {
    var body: some Widget { PulseStatusWidget() }
}

struct PulseStatusWidget: Widget {
    var body: some WidgetConfiguration { OracleWidgetKit.configuration(.pulse) }
}
