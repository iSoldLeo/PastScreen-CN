#if canImport(TipKit)
import Foundation
import TipKit
import SwiftUI

@available(macOS 14.0, *)
struct QuickCaptureTip: Tip {
    var title: Text {
        Text(NSLocalizedString("tip.quick_capture.title", comment: ""))
    }

    var message: Text? {
        Text(NSLocalizedString("tip.quick_capture.message", comment: ""))
    }

    var image: Image? {
        Image(systemName: "command.circle")
    }
}
#endif
