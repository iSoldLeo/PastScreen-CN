#if canImport(AppIntents)
import Foundation
import AppIntents

@available(macOS 13.0, *)
enum CaptureShortcutReturnType: String, AppEnum {
    case filePath
    case text

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "返回类型"

    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .filePath: "文件路径",
        .text: "文本"
    ]
}

@available(macOS 13.0, *)
struct CaptureAreaIntent: AppIntent {
    static var title: LocalizedStringResource = "选区截图"
    static var description = IntentDescription("使用 PastScreen-CN 截取自定义区域，并返回文件路径（或文本）。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "返回类型", default: .filePath)
    var returnType: CaptureShortcutReturnType

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let value = try await ScreenshotIntentBridge.shared.captureArea(returnType: mapReturnType())
        return .result(value: value)
    }

    private func mapReturnType() -> ScreenshotIntentBridge.AutomationReturnType {
        ScreenshotIntentBridge.AutomationReturnType(rawValue: returnType.rawValue) ?? .filePath
    }
}

@available(macOS 13.0, *)
struct CaptureFullScreenIntent: AppIntent {
    static var title: LocalizedStringResource = "全屏截图"
    static var description = IntentDescription("使用 PastScreen-CN 截取全屏，并返回文件路径（或文本）。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "返回类型", default: .filePath)
    var returnType: CaptureShortcutReturnType

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let value = try await ScreenshotIntentBridge.shared.captureFullScreen(returnType: mapReturnType())
        return .result(value: value)
    }

    private func mapReturnType() -> ScreenshotIntentBridge.AutomationReturnType {
        ScreenshotIntentBridge.AutomationReturnType(rawValue: returnType.rawValue) ?? .filePath
    }
}

@available(macOS 13.0, *)
struct CaptureAdvancedAreaIntent: AppIntent {
    static var title: LocalizedStringResource = "高级截图"
    static var description = IntentDescription("使用 PastScreen-CN 打开编辑器进行高级截图，并返回文件路径（或文本）。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "返回类型", default: .filePath)
    var returnType: CaptureShortcutReturnType

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let value = try await ScreenshotIntentBridge.shared.captureAdvancedArea(returnType: mapReturnType())
        return .result(value: value)
    }

    private func mapReturnType() -> ScreenshotIntentBridge.AutomationReturnType {
        ScreenshotIntentBridge.AutomationReturnType(rawValue: returnType.rawValue) ?? .filePath
    }
}

@available(macOS 13.0, *)
struct CaptureOCRIntent: AppIntent {
    static var title: LocalizedStringResource = "OCR 截图"
    static var description = IntentDescription("使用 PastScreen-CN 截取 OCR 选区，可返回识别文本或图片文件路径。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "返回类型", default: .text)
    var returnType: CaptureShortcutReturnType

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let value = try await ScreenshotIntentBridge.shared.captureOCR(returnType: mapReturnType())
        return .result(value: value)
    }

    private func mapReturnType() -> ScreenshotIntentBridge.AutomationReturnType {
        ScreenshotIntentBridge.AutomationReturnType(rawValue: returnType.rawValue) ?? .text
    }
}

@available(macOS 13.0, *)
struct CaptureWindowIntent: AppIntent {
    static var title: LocalizedStringResource = "窗口截图"
    static var description = IntentDescription("使用 PastScreen-CN 截取鼠标下的窗口，并返回文件路径（或文本）。")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "返回类型", default: .filePath)
    var returnType: CaptureShortcutReturnType

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let value = try await ScreenshotIntentBridge.shared.captureWindow(returnType: mapReturnType())
        return .result(value: value)
    }

    private func mapReturnType() -> ScreenshotIntentBridge.AutomationReturnType {
        ScreenshotIntentBridge.AutomationReturnType(rawValue: returnType.rawValue) ?? .filePath
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
                intent: CaptureAdvancedAreaIntent(),
                phrases: [
                    "用 \(.applicationName) 高级截图",
                    "使用 \(.applicationName) 高级截图"
                ],
                shortTitle: "高级截图",
                systemImageName: "slider.horizontal.3"
            ),
            AppShortcut(
                intent: CaptureOCRIntent(),
                phrases: [
                    "用 \(.applicationName) OCR 截图",
                    "使用 \(.applicationName) OCR 截图"
                ],
                shortTitle: "OCR 截图",
                systemImageName: "text.viewfinder"
            ),
            AppShortcut(
                intent: CaptureWindowIntent(),
                phrases: [
                    "用 \(.applicationName) 窗口截图",
                    "使用 \(.applicationName) 截取窗口"
                ],
                shortTitle: "窗口截图",
                systemImageName: "macwindow"
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
