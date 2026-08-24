//
//  LaunchAtLoginManager.swift
//  Mio
//
//  Module-12 Login Item integration (M10-05 / M10-06 inherited debt).
//
//  `SMAppService.mainApp.status` 是开机启动的**唯一真相**：不再镜像 UserDefaults Bool，
//  也不再用 detached fire-and-forget 吞掉错误。
//    · 稳定态 1:1 映射 `SMAppService.Status`；`.unknown` 承载未来/未识别的平台状态
//      （**不伪装成 `.notRegistered`**）。`.changing`/`.failed` 携带当前稳定态，供 UI
//      投影——但 UI 不持久化/推断/覆盖它。
//    · `setEnabled` 单飞：`.changing` 期间 Settings 禁用 toggle。成功与失败后都重读
//      status；失败态 `.failed(current:)` 携带**重读到的当前系统状态**，`isOn` 与
//      approval 入口都从它派生，不会与系统真相相反。
//    · 打开官方「登录项」面板走注入的唯一 `SystemSettingsOpener`（Screen Recording
//      与 Login Item 共用一个 opener），controller 不直接调用 ServiceManagement 的
//      settings 入口。
//
//  部署下限 15.6 高于 `SMAppService` 所需的 macOS 13，因此不保留任何 `#available(macOS 13)`
//  fallback（在 15.6 下是不可达死分支）。
//

import Foundation
import ServiceManagement
import Combine

/// `SMAppService.Status` 的稳定态。`.unknown` = 未来/未识别值（typed，不伪装）。
nonisolated enum StableLaunchAtLoginState: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
}

/// Login Item 的完整可观察态：稳定态之外增加 in-flight `.changing` 与终态 `.failed`，
/// 两者都携带当前稳定态（`.failed` 用 `current` = 操作后重读值）。
nonisolated enum LaunchAtLoginState: Sendable, Equatable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unknown
    case changing(previous: StableLaunchAtLoginState, targetEnabled: Bool)
    case failed(current: StableLaunchAtLoginState, failure: LaunchAtLoginFailure)
}

/// 注册/注销的 typed 失败（不再吞错）。
nonisolated enum LaunchAtLoginFailure: Error, Sendable, Equatable {
    case registrationFailed
    case unregistrationFailed
}

extension StableLaunchAtLoginState {
    /// 稳定态提升为可观察态（同名五态）。
    var asState: LaunchAtLoginState {
        switch self {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .unknown: return .unknown
        }
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var state: LaunchAtLoginState
    private let settingsOpener: SystemSettingsOpener

    init(settingsOpener: SystemSettingsOpener) {
        self.settingsOpener = settingsOpener
        state = Self.readStatus().asState
    }

    /// toggle 是否显示为「开」。从**当前稳定态**派生（含 `.failed` 的 `current`），
    /// 因此永远与 `SMAppService.status` 一致，不会因失败态反转。
    var isOn: Bool {
        switch state {
        case .enabled: return true
        case .changing(_, let target): return target
        case .failed(let current, _): return current == .enabled
        case .notRegistered, .requiresApproval, .notFound, .unknown: return false
        }
    }

    /// 是否应展示官方「登录项」面板入口。从当前稳定态派生：顶层 `.requiresApproval`
    /// 或 `.failed(current: .requiresApproval)` 都需要。
    var showsApprovalAction: Bool {
        switch state {
        case .requiresApproval: return true
        case .failed(let current, _): return current == .requiresApproval
        case .changing, .enabled, .notRegistered, .notFound, .unknown: return false
        }
    }

    /// 上次操作是否以 typed 失败终态收敛（供 UI 显示可见提示）。
    var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    /// `.changing` 期间 UI 应禁用 toggle（单飞）。
    var isChanging: Bool {
        if case .changing = state { return true }
        return false
    }

    /// 只读刷新（app-active / wake）：把 `state` 对齐系统真相。不打断 in-flight 切换。
    func refresh() {
        guard !isChanging else { return }
        state = Self.readStatus().asState
    }

    /// 切换 Login Item。单飞：`.changing` 期间直接返回当前稳定态，不并发。register/
    /// unregister 的 launchd 往返在 utility detached task 内完成，成功/失败后都重读 status。
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Result<StableLaunchAtLoginState, LaunchAtLoginFailure> {
        if isChanging { return .success(Self.readStatus()) }
        let previous = Self.stable(from: state)
        state = .changing(previous: previous, targetEnabled: enabled)

        let outcome = await Self.performToggle(enabled: enabled)
        let reread = Self.readStatus()

        switch outcome {
        case .success:
            state = reread.asState
            return .success(reread)
        case .failure(let failure):
            // 失败态携带**重读到的当前系统状态**，UI 投影据此保持与真相一致。
            state = .failed(current: reread, failure: failure)
            return .failure(failure)
        }
    }

    /// 打开系统设置的「登录项」面板（经唯一 opener）。返回 typed result 供调用方处理。
    @discardableResult
    func openSystemSettings() -> Result<Void, SystemSettingsOpenFailure> {
        settingsOpener.open(.loginItems)
    }

    // MARK: - System truth

    private static func readStatus() -> StableLaunchAtLoginState {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .unknown
        }
    }

    private static func stable(from state: LaunchAtLoginState) -> StableLaunchAtLoginState {
        switch state {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .unknown: return .unknown
        case .changing(let previous, _): return previous
        case .failed(let current, _): return current
        }
    }

    /// launchd 往返在 utility detached task 内执行（阻塞调用），只捕获 Sendable `enabled`
    /// 与 typed 结果，不触碰 MainActor 状态。
    private static func performToggle(
        enabled: Bool
    ) async -> Result<Void, LaunchAtLoginFailure> {
        await Task.detached(priority: .utility) {
            let service = SMAppService.mainApp
            do {
                if enabled {
                    if service.status != .enabled { try service.register() }
                } else {
                    if service.status != .notRegistered { try service.unregister() }
                }
                return .success(())
            } catch {
                return .failure(enabled ? .registrationFailed : .unregistrationFailed)
            }
        }.value
    }
}
