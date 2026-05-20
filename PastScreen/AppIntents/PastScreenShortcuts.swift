#if canImport(AppIntents)
import AppIntents

@available(macOS 13.0, *)
struct CaptureAreaIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture area"
    static var description = IntentDescription("Capture a custom area with PastScreen and copy the image.")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        try await ScreenshotIntentBridge.shared.triggerAreaCapture()
        return .result()
    }
}

@available(macOS 13.0, *)
struct CaptureFullScreenIntent: AppIntent {
    static var title: LocalizedStringResource = "Capture full screen"
    static var description = IntentDescription("Capture the full screen with PastScreen and copy the result.")
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
                phrases: ["Capture area with \(.applicationName)", "Selection with \(.applicationName)"],
                shortTitle: "Capture area",
                systemImageName: "selection.pin.in.out"
            ),
            AppShortcut(
                intent: CaptureFullScreenIntent(),
                phrases: ["Capture full screen with \(.applicationName)", "Full screen via \(.applicationName)"],
                shortTitle: "Full screen",
                systemImageName: "rectangle.inset.filled"
            )
        ]
    }
}
#endif
