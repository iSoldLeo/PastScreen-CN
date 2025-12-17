#if canImport(AppIntents)
import Foundation
import AppIntents

@available(macOS 13.0, *)
struct CaptureAreaIntent: AppIntent {
    static var title: LocalizedStringResource = "选区截图"
    static var description = IntentDescription("使用 PastScreen-CN 截取自定义区域并复制图片。")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        try await ScreenshotIntentBridge.shared.triggerAreaCapture()
        return .result()
    }
}

@available(macOS 13.0, *)
struct CaptureFullScreenIntent: AppIntent {
    static var title: LocalizedStringResource = "全屏截图"
    static var description = IntentDescription("使用 PastScreen-CN 截取全屏并复制结果。")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        try await ScreenshotIntentBridge.shared.triggerFullScreenCapture()
        return .result()
    }
}

@available(macOS 13.0, *)
struct PastScreenShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: CaptureAreaIntent(),
                phrases: [
                    "用 \(.applicationName) 选区截图",
                    "使用 \(.applicationName) 截取选区"
                ],
                shortTitle: "选区截图",
                systemImageName: "selection.pin.in.out"
            ),
            AppShortcut(
                intent: CaptureFullScreenIntent(),
                phrases: [
                    "用 \(.applicationName) 全屏截图",
                    "使用 \(.applicationName) 截取全屏"
                ],
                shortTitle: "全屏截图",
                systemImageName: "rectangle.inset.filled"
            )
        ]
    }
}
#endif
