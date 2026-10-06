import WidgetKit
import SwiftUI
import OracleKit

@main
struct NeoWidgets: WidgetBundle {
    var body: some Widget { NeoStatusWidget() }
}

struct NeoStatusWidget: Widget {
    var body: some WidgetConfiguration { OracleWidgetKit.configuration(.neo) }
}
