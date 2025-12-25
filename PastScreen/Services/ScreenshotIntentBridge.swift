import Foundation

@MainActor
final class ScreenshotIntentBridge {
    static let shared = ScreenshotIntentBridge()
    weak var appDelegate: AppDelegate?

    enum AutomationReturnType: String, Codable, CaseIterable {
        case filePath
        case text
    }

    enum IntentError: LocalizedError {
        case appUnavailable
        case timeout
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .appUnavailable:
                return NSLocalizedString("intent.error.app_unavailable", value: "应用不可用", comment: "")
            case .timeout:
                return NSLocalizedString("intent.error.timeout", value: "截图超时", comment: "")
            case .failed(let message):
                return message
            }
        }
    }

    func triggerAreaCapture() async throws {
        guard let delegate = appDelegate else { throw IntentError.appUnavailable }
        delegate.performAreaCapture(source: .appIntent)
    }

    func triggerFullScreenCapture() async throws {
        guard let delegate = appDelegate else { throw IntentError.appUnavailable }
        delegate.performFullScreenCapture(source: .appIntent)
    }

    func captureArea(returnType: AutomationReturnType) async throws -> String {
        try await capture(kind: .area, returnType: returnType)
    }

    func captureFullScreen(returnType: AutomationReturnType) async throws -> String {
        try await capture(kind: .fullScreen, returnType: returnType)
    }

    func captureAdvancedArea(returnType: AutomationReturnType) async throws -> String {
        try await capture(kind: .advancedArea, returnType: returnType)
    }

    func captureOCR(returnType: AutomationReturnType) async throws -> String {
        try await capture(kind: .ocrArea, returnType: returnType)
    }

    func captureWindow(returnType: AutomationReturnType) async throws -> String {
        try await capture(kind: .windowUnderMouse, returnType: returnType)
    }

    private enum CaptureKind {
        case area
        case fullScreen
        case advancedArea
        case ocrArea
        case windowUnderMouse
    }

    private func capture(kind: CaptureKind, returnType: AutomationReturnType) async throws -> String {
        guard let delegate = appDelegate else { throw IntentError.appUnavailable }

        let requestID = UUID()

        switch kind {
        case .area:
            delegate.performAreaCaptureForAutomation(requestID: requestID, returnType: returnType)
        case .fullScreen:
            delegate.performFullScreenCaptureForAutomation(requestID: requestID, returnType: returnType)
        case .advancedArea:
            delegate.performAdvancedAreaCaptureForAutomation(requestID: requestID, returnType: returnType)
        case .ocrArea:
            delegate.performOCRCaptureForAutomation(requestID: requestID, returnType: returnType)
        case .windowUnderMouse:
            delegate.performWindowCaptureForAutomation(requestID: requestID, returnType: returnType)
        }

        let result = try await awaitAutomationResult(requestID: requestID)
        if let error = result.error, !error.isEmpty {
            throw IntentError.failed(error)
        }

        switch returnType {
        case .text:
            if let text = result.ocrText, !text.isEmpty { return text }
            if let filePath = result.filePath, !filePath.isEmpty { return filePath }
            throw IntentError.failed(NSLocalizedString("intent.error.no_result", value: "没有可返回的结果", comment: ""))
        case .filePath:
            if let filePath = result.filePath, !filePath.isEmpty { return filePath }
            throw IntentError.failed(NSLocalizedString("intent.error.no_file", value: "没有可返回的文件路径", comment: ""))
        }
    }

    private struct AutomationResult {
        var filePath: String?
        var ocrText: String?
        var error: String?
    }

    private func awaitAutomationResult(requestID: UUID, timeoutSeconds: TimeInterval = 90) async throws -> AutomationResult {
        try await withCheckedThrowingContinuation { continuation in
            var resolved = false
            var observer: NSObjectProtocol?

            func finish(_ result: Result<AutomationResult, Error>) {
                guard !resolved else { return }
                resolved = true
                if let observer {
                    NotificationCenter.default.removeObserver(observer)
                }
                switch result {
                case .success(let value):
                    continuation.resume(returning: value)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            observer = NotificationCenter.default.addObserver(
                forName: .automationCaptureCompleted,
                object: nil,
                queue: .main
            ) { note in
                guard
                    let userInfo = note.userInfo,
                    let idString = userInfo["requestID"] as? String,
                    idString == requestID.uuidString
                else { return }

                let filePath = userInfo["filePath"] as? String
                let ocrText = userInfo["ocrText"] as? String
                let error = userInfo["error"] as? String
                finish(.success(AutomationResult(filePath: filePath, ocrText: ocrText, error: error)))
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                finish(.failure(IntentError.timeout))
            }
        }
    }
}
