import Foundation

@MainActor
final class ScreenshotIntentBridge {
    static let shared = ScreenshotIntentBridge()
    weak var appDelegate: AppDelegate?

    enum IntentError: LocalizedError {
        case appUnavailable

        var errorDescription: String? {
            switch self {
            case .appUnavailable:
                return NSLocalizedString("intent.error.app_unavailable", comment: "")
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
}
