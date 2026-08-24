//
//  PermissionManager.swift
//  Mio
//
//  Module-12 Screen Recording 授权（M12-01 / M12-04）。
//
//  只负责 Screen Recording：Accessibility 分支已删——它不在 Carbon 截图主链上、
//  无任何消费者（M12-04）。
//
//  权限是一次尝试的 **typed 终态** `PermissionDecision`：
//    · `CGPreflightScreenCaptureAccess` / `CGRequestScreenCaptureAccess` 无法可靠
//      区分 notDetermined / denied / policy restriction，因此**不伪造** `.restricted`；
//      false 一律收敛为 `.denied(.openSystemSettings(.screenRecording))`。
//    · request 是同步系统调用（`CGRequestScreenCaptureAccess()` 直接返回 Bool，首次
//      调用弹 TCC 对话框）；不做固定 sleep、不包装成假异步。
//    · `screenCaptureDecision` 是**只读快照**：由 01 在 app 重新 active / wake 时调
//      `refreshScreenCaptureDecision()` 更新，供 UI（Onboarding 权限页）观察。刷新
//      只读 actual state，不请求权限、不改 desired state。
//    · 12 只决定权限；把 `PermissionRecovery` 映射成 08 feedback action 是 01 的事。
//

import Foundation
import CoreGraphics
import Combine

/// 一次 Screen Recording 授权尝试的 typed 终态（12-owned）。
nonisolated enum PermissionDecision: Sendable, Equatable {
    case authorized
    case denied(recovery: PermissionRecovery)
    case restricted(recovery: PermissionRecovery?)
    case failed(PermissionFailure)
}

/// presentation-independent 恢复意图；01 映射成 08-owned feedback action。
nonisolated enum PermissionRecovery: Sendable, Equatable {
    case openSystemSettings(SystemSettingsDestination)
}

/// System Settings 目标面板。Screen Recording opener 与 Login Item 共用。
nonisolated enum SystemSettingsDestination: Sendable, Equatable {
    case screenRecording
    case loginItems
}

/// 底层权限失败——只进 01/12 日志，不扩展 08 event（没有更精确分类时用 `.unknown`）。
nonisolated enum PermissionFailure: Sendable, Equatable {
    case unknown
}

@MainActor
final class PermissionManager: ObservableObject {
    /// 只读授权快照，供 UI 观察；由 `refreshScreenCaptureDecision()` / `authorizeScreenCapture()`
    /// 更新。它是 typed decision 的缓存，不是长驻二态 Bool。
    @Published private(set) var screenCaptureDecision: PermissionDecision

    init() {
        screenCaptureDecision = Self.readDecision()
    }

    /// 只读刷新（app-active / wake）：不弹窗，仅把快照对齐当前系统真相。
    func refreshScreenCaptureDecision() {
        screenCaptureDecision = Self.readDecision()
    }

    /// 只读当前授权（不弹窗），不改快照——per-command 路径用。
    func currentScreenCaptureDecision() -> PermissionDecision {
        Self.readDecision()
    }

    /// 授权一次截图：已授权直接返回；否则请求系统弹窗并**使用其直接 Bool 结果**
    /// （曾被拒绝的进程系统不再弹窗、直接 false → `.denied`）。同步系统调用，
    /// 完成后更新只读快照。
    @discardableResult
    func authorizeScreenCapture() -> PermissionDecision {
        let decision: PermissionDecision
        if CGPreflightScreenCaptureAccess() {
            decision = .authorized
        } else {
            decision = CGRequestScreenCaptureAccess()
                ? .authorized
                : .denied(recovery: .openSystemSettings(.screenRecording))
        }
        screenCaptureDecision = decision
        return decision
    }

    private static func readDecision() -> PermissionDecision {
        CGPreflightScreenCaptureAccess()
            ? .authorized
            : .denied(recovery: .openSystemSettings(.screenRecording))
    }
}
