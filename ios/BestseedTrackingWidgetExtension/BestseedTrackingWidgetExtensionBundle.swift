import WidgetKit
import SwiftUI

/// Entry point for the Widget Extension. Only ships the Live Activity —
/// no home-screen widget, no Control Center widget. The other two files in
/// this directory (regular widget + control widget) are kept as stubs so
/// the Xcode project references stay valid, but they are intentionally NOT
/// listed here.
@main
struct BestseedTrackingWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.1, *) {
            BestseedTrackingWidgetExtensionLiveActivity()
        }
    }
}
