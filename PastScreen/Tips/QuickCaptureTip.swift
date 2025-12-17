#if canImport(TipKit)
import TipKit
import SwiftUI

@available(macOS 14.0, *)
struct QuickCaptureTip: Tip {
    var title: Text {
        Text("PastScreen Tip")
    }

    var message: Text? {
        Text("Use your hotkey or Apple Shortcuts for instant capture.")
    }

    var image: Image? {
        Image(systemName: "command.circle")
    }
}
#endif
