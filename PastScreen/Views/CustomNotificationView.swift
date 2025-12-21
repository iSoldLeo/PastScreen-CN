//
//  CustomNotificationView.swift
//  PastScreen
//
//  Custom notification system that works with .accessory mode apps
//  Alternative to UNUserNotification which doesn't work for menu bar only apps
//

import SwiftUI
import AppKit

// MARK: - CustomNotificationManager

class CustomNotificationManager {
    static let shared = CustomNotificationManager()

    private var notificationPanel: NSPanel?
    private var dismissTimer: Timer?
    private let notificationDuration: TimeInterval = 4.0

    func show(title: String, message: String, filePath: String? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Dismiss any existing notification
            self.dismiss()

            // Create notification content
            let notificationView = CustomNotificationContentView(
                title: title,
                message: message,
                filePath: filePath,
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            )

            // Create hosting controller
            let hostingController = NSHostingController(rootView: notificationView)

            // Calculate notification position (top-right corner)
            let notificationWidth: CGFloat = 360
            let notificationHeight: CGFloat = 100
            let screenPadding: CGFloat = 20

            guard let screen = NSScreen.main else { return }

            let screenFrame = screen.visibleFrame
            let notificationRect = NSRect(
                x: screenFrame.maxX - notificationWidth - screenPadding,
                y: screenFrame.maxY - notificationHeight - screenPadding,
                width: notificationWidth,
                height: notificationHeight
            )

            // Create panel
            let panel = NSPanel(
                contentRect: notificationRect,
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )

            panel.contentViewController = hostingController
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false

            self.notificationPanel = panel

            // Show immediately without fade animation
            panel.alphaValue = 1
            panel.orderFrontRegardless()

            // Auto-dismiss after duration
            self.dismissTimer = Timer.scheduledTimer(withTimeInterval: self.notificationDuration, repeats: false) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil

        guard let panel = notificationPanel else { return }

        // Close immediately without fade animation
        panel.close()
        notificationPanel = nil
    }
}

// MARK: - CustomNotificationContentView

struct CustomNotificationContentView: View {
    let title: String
    let message: String
    let filePath: String?
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                Circle()
                    .fill(.thinMaterial)
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    }
                    .frame(width: 48, height: 48)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
            }

            // Content
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 8) {
                if filePath != nil {
                    Button(action: {
                        openInFinder()
                    }) {
                        Image(systemName: "folder")
                            .font(.system(size: 14))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .tint(.accentColor)
                    .help(NSLocalizedString("notification.reveal_in_finder", comment: ""))
                }

                Button(action: {
                    onDismiss()
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .tint(.secondary)
                .help(NSLocalizedString("notification.dismiss", comment: ""))
            }
        }
        .padding(16)
        .tint(.green)
        .glassContainer(material: isHovered ? .regularMaterial : .thinMaterial, cornerRadius: 14, borderOpacity: 0.18, shadowOpacity: 0.14)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            if filePath != nil {
                openInFinder()
            }
        }
    }

    private func openInFinder() {
        guard let path = filePath else { return }
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        onDismiss()
    }
}

// MARK: - Preview

struct CustomNotificationContentView_Previews: PreviewProvider {
    static var previews: some View {
        CustomNotificationContentView(
            title: NSLocalizedString("notification.screenshot_ready", comment: ""),
            message: NSLocalizedString("notification.click_to_reveal", comment: ""),
            filePath: "/tmp/test.png",
            onDismiss: {}
        )
        .frame(width: 360, height: 100)
        .previewLayout(.sizeThatFits)
    }
}
