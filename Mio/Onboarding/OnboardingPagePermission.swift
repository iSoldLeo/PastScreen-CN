//
//  OnboardingPagePermission.swift
//  Mio
//
//  Onboarding 第 1 页：Screen Recording 权限（M11 延后项，由模块 12 承接）。
//
//  截图能力的前提是 Screen Recording 授权，因此这是首个页面。本页消费模块 12 的
//  typed `PermissionManager`：
//    · 授权状态**观察** `permissionManager.screenCaptureDecision`（只读快照）；`.task`
//      在出现时只读刷新，01 在 app / 会话重新 active 时也会刷新——因此用户去系统设置
//      授权后返回，本页会自动更新为 ✓，无需页面自建 NSApplication observer（Review D2）。
//    · 「授予」→ `authorizeScreenCapture()`（同步系统调用；首次弹 TCC 对话框，直接用其
//      Bool 结果）。已授权显示 ✓。
//    · 若已被拒绝（系统不再弹窗），按钮切换为「打开系统设置」，走注入的
//      `openScreenRecordingSettings`（返回 typed Result；打开失败就地提示，不静默丢弃、
//      不转交 08）。
//    · `requestedOnce` 由 `OnboardingView` 持有并以 binding 注入，Back/Next 翻页不丢失
//      「已请求→打开设置」状态（Review D3）。
//    · 「Later」= 底栏「下一步」：不授予也能继续。
//

import SwiftUI

struct OnboardingPagePermission: View {
    @ObservedObject var permissionManager: PermissionManager
    let openScreenRecordingSettings: @MainActor () -> Result<Void, SystemSettingsOpenFailure>
    @Binding var requestedOnce: Bool

    @State private var openFailed = false

    private var isAuthorized: Bool {
        if case .authorized = permissionManager.screenCaptureDecision { return true }
        return false
    }

    var body: some View {
        OnboardingPageShell(
            title: "onboarding.permission.title",
            subtitle: "onboarding.permission.subtitle"
        ) {
            PermissionStage(isAuthorized: isAuthorized)
        } action: {
            actionControl
                .frame(minHeight: 32)
        }
        .task {
            // 只读刷新（出现时），不弹窗；不新建 NSApplication observer。
            permissionManager.refreshScreenCaptureDecision()
        }
    }

    @ViewBuilder
    private var actionControl: some View {
        if isAuthorized {
            Label("onboarding.permission.granted", systemImage: "checkmark.circle.fill")
                .font(.body.weight(.medium))
                .foregroundStyle(.green)
        } else if requestedOnce {
            // Requested once and still not authorized: the system won't re-prompt,
            // so route to System Settings. A failed open is shown inline (11-owned),
            // never silently dropped.
            VStack(spacing: 6) {
                Button("onboarding.permission.open_settings") {
                    if case .failure = openScreenRecordingSettings() {
                        openFailed = true
                    } else {
                        openFailed = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if openFailed {
                    Text("capture.feedback.open_settings_failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } else {
            Button("onboarding.permission.grant") {
                grant()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func grant() {
        // 同步系统调用（CGRequestScreenCaptureAccess），更新 manager 的只读快照；
        // requestedOnce 提升到 OnboardingView，翻页不丢失。
        _ = permissionManager.authorizeScreenCapture()
        requestedOnce = true
    }
}

// MARK: - Stage

private struct PermissionStage: View {
    let isAuthorized: Bool

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill((isAuthorized ? Color.green : Color.accentColor).opacity(0.14))
                    .frame(width: 96, height: 96)
                Image(systemName: isAuthorized ? "checkmark.shield.fill" : "display")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(isAuthorized ? Color.green : Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}
