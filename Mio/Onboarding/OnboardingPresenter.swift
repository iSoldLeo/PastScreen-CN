//
//  OnboardingPresenter.swift
//  Mio
//
//  AppKit 侧 onboarding 窗口管理。把 OnboardingView(SwiftUI) 装进
//  NSWindow + NSHostingController,由 AppDelegate 直接调用,不依赖
//  SwiftUI 的 openWindow / dismissWindow。
//
//  为什么不用 SwiftUI Window scene:
//    - LSUIElement = true(menu-bar accessory)启动时没有任何 SwiftUI
//      view 在场,@Environment(\.openWindow) 在 AppDelegate 不可达
//    - MenuBarExtra content 只在用户点击图标时实例化,不是稳定 host
//    - Settings scene 默认不创建窗口
//    - 通知 + helper view 模式需要常驻 host scene,本 app 不存在
//
//  这个 presenter 同时为 SettingsView 的"重新查看引导"入口提供统一
//  访问点,避免两套触发路径。
//
//  生命周期:
//    1. 由 AppServices 唯一持有(MainActor)。第一次 show() lazy 创建 NSWindow
//       并开一个 OnboardingSession。
//    2. 三个终态入口统一收敛：Done「开始使用」→ end(.finished)、native X →
//       windowShouldClose(.dismissed)、app stop → stop()(.appStopping)。都先
//       结束 session 的 page 资源(录制 host)再销毁窗口与 hosting tree；不缓存
//       隐藏的 SwiftUI 状态，避免迟到 completion 在窗口不可见后改写用户偏好。
//    3. 只有 end(.finished)(真正走完并点「开始使用」)写 UserDefaults 版本戳；
//       X / 程序化隐藏 / app 停止都不写。下次启动 AppDelegate 据此决定是否再显示。
//
//  显示判定:
//    - 只有真正完成(点「开始使用」)才算本版本已确认；中途点 X 关闭不写戳，
//      下次启动仍会再次出现，直到用户走完一次
//    - 只有版本号前进才会再次出现
//

import AppKit
import SwiftUI

@MainActor
final class OnboardingPresenter: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    /// 当前展示 session（每次 show 新建，end/stop 后清空）。类型定义见文件底部。
    private var session: OnboardingSession?
    private weak var shortcutService: GlobalShortcutService?
    private let imageProcessor: ImageProcessor
    private let permissionManager: PermissionManager
    private let openScreenRecordingSettings: @MainActor () -> Result<Void, SystemSettingsOpenFailure>
    /// 持有 toolbar delegate 防止被 ARC 释放——NSToolbar 只 weak 引用 delegate。
    private var toolbarDelegate: OnboardingToolbarDelegate?

    init(
        imageProcessor: ImageProcessor,
        permissionManager: PermissionManager,
        openScreenRecordingSettings: @escaping @MainActor () -> Result<Void, SystemSettingsOpenFailure>
    ) {
        self.imageProcessor = imageProcessor
        self.permissionManager = permissionManager
        self.openScreenRecordingSettings = openScreenRecordingSettings
        super.init()
    }

    /// 当前 bundle 短版本号(如 "1.2.3")。"unknown" 仅作为防御性兜底,
    /// 正常路径下永远不会命中——CFBundleShortVersionString 是必填项。
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// 本机已展示 / 已确认过 onboarding 的版本号。保留旧 key 字符串是为
    /// 兼容已安装用户的 UserDefaults,避免升级后把已完成用户误判为新用户。
    private static let acknowledgedVersionKey = "onboardingCompletedAtVersion"

    /// 上次展示 / 确认 onboarding 时记录的版本号。nil = 从未见过(新用户)。
    static var lastAcknowledgedVersion: String? {
        UserDefaults.standard.string(forKey: acknowledgedVersionKey)
    }

    /// 是否需要触发 onboarding。判定规则:
    ///   1. 没有任何版本戳 → true(新用户)
    ///   2. 当前版本 > 已记录版本 (numeric 比较,正确处理 1.10 > 1.9)→ true
    ///   3. 当前版本 ≤ 已记录版本 → false(同版本或回退,后者罕见)
    ///
    /// 同版本不重复触发——一次完成永久免打扰,直到下次升级。
    static var shouldShowOnLaunch: Bool {
        guard let last = lastAcknowledgedVersion else { return true }
        let current = currentVersion
        // numeric 比较把版本号串当成数字串解析,"1.10" > "1.9"。
        return current.compare(last, options: .numeric) == .orderedDescending
    }

    /// 标记当前版本 onboarding 已真正完成(用户走完并点「开始使用」)。只由
    /// end(.finished) 调用——中途 X 关闭 / app 停止都不写，因此不会把未完成
    /// 用户误判为已完成。
    static func markPresented() {
        UserDefaults.standard.set(currentVersion, forKey: acknowledgedVersionKey)
    }

    /// 显示 onboarding 窗口(创建 / 复用)。menu-bar app 必须显式 activate
    /// 才能让窗口拿到 key 状态。
    func show(
        shortcutStore: ShortcutStore,
        shortcutService: GlobalShortcutService,
        shortcutFormatter: ShortcutLabelFormatter,
        captureSettings: CaptureSettings,
        saveFolderAccess: SaveFolderAccess
    ) {
        self.shortcutService = shortcutService
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        session = OnboardingSession()

        let hosting = NSHostingController(
            rootView: OnboardingView(onClose: { [weak self] in
                self?.end(reason: .finished)
            }, shortcutFormatter: shortcutFormatter, imageProcessor: imageProcessor, permissionManager: permissionManager, openScreenRecordingSettings: openScreenRecordingSettings)
            .environmentObject(shortcutStore)
            .environmentObject(shortcutService)
            .environmentObject(captureSettings)
            .environmentObject(saveFolderAccess)
        )

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // Presenter owns the window strongly and clears that reference on every
        // terminal. AppKit must not independently release it during close.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.collectionBehavior = [.fullScreenNone]
        window.setContentSize(NSSize(
            width: OnboardingLayout.windowWidth,
            height: OnboardingLayout.windowHeight
        ))
        window.center()
        // Tahoe 大圆角触发条件:窗口必须挂一个真实的 NSToolbar (unified style)。
        // 仅 .titled + 透明 titlebar 只能拿到 titlebar 高度等量的小圆角;
        // 挂上 toolbar 后 macOS 26 会按 unified toolbar 几何计算外轮廓圆角,
        // 与设置面板等系统级窗口一致。toolbar 只放一个"帮助"占位 item,内容
        // 仍由 SwiftUI 的 OnboardingFooter 自己处理。
        let toolbarDelegate = OnboardingToolbarDelegate()
        let toolbar = NSToolbar(identifier: "OnboardingToolbar")
        toolbar.delegate = toolbarDelegate
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        self.toolbarDelegate = toolbarDelegate

        window.title = ""

        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// 唯一终态入口（Done「开始使用」与 app stop 共用；native X 走
    /// `windowShouldClose`）。先结束当前 session 的 page 资源（录制 host），
    /// 仅 `.finished` 写本版本 completion 戳，再释放并关闭窗口。幂等：session
    /// 已结束时是 no-op。窗口 hosting tree 关闭会连带装卸各页：F5/F7/F6 动画随
    /// 其 `.task` 自动取消，frame 页额外在 `.onDisappear` 里 cancel/expire 自有 Task。
    func end(reason: OnboardingEndReason) {
        guard finishSession(reason: reason) else { return }
        guard let window else { return }
        window.delegate = nil
        self.window = nil
        toolbarDelegate = nil
        window.close()
    }

    /// app 生命周期停止入口：以 `.appStopping` 终态收敛（不写 completion）。
    func stop() {
        end(reason: .appStopping)
    }

    /// 结束当前 session 的 page 资源并按原因决定是否写 completion；返回 false
    /// 表示 session 已结束（幂等 no-op）。不触碰 window——由调用方决定关窗时机，
    /// 使 native X（AppKit 自行关窗）与程序化关闭复用同一收敛逻辑。
    @discardableResult
    private func finishSession(reason: OnboardingEndReason) -> Bool {
        guard session != nil else { return false }
        session = nil
        let recordingReason: RecordingEndReason = reason == .finished ? .hostCompleted : .hostHidden
        shortcutService?.endRecording(forHost: .onboarding, reason: recordingReason)
        if reason == .finished {
            OnboardingPresenter.markPresented()
        }
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // native X：AppKit 会自行关闭窗口，这里只收敛 session 并清强引用，
        // 不再调用 window.close()（否则重入）。X = dismissed，不写 completion。
        finishSession(reason: .dismissed)
        if window === sender {
            window = nil
            toolbarDelegate = nil
        }
        return true
    }
}

// MARK: - Onboarding session & terminal reason

/// 11-owned onboarding 展示 session 标识。每次 `show()` 新建一个；`end/stop`
/// 收敛后清空，使重复终态成为幂等 no-op。
nonisolated struct OnboardingSession: Sendable {
    let id = UUID()
}

/// 11-owned onboarding 终态原因。只有 `.finished`（真 Finish/「开始使用」）写
/// 本版本 completion 戳；`.dismissed`（native X / 程序化隐藏）与 `.appStopping`
/// （进程停止）都不写——「看到过」不再等于「完成设置」。
nonisolated enum OnboardingEndReason: Sendable {
    case finished
    case dismissed
    case appStopping
}

// MARK: - Toolbar delegate

/// onboarding 窗口的 toolbar delegate。原 SwiftUI 版本(MioApp 里被替换的
/// Window scene)挂了一个空的"帮助" toolbar item 做大圆角触发器,这里
/// 在 AppKit 路径下做 1:1 等价。
///
/// item 是预留入口:当前点击不绑动作,让 macOS 26 把窗口按 unified toolbar
/// 计算外轮廓即可——与设置面板、系统偏好设置外观一致。
@MainActor
private final class OnboardingToolbarDelegate: NSObject, NSToolbarDelegate {
    private static let helpItemID = NSToolbarItem.Identifier("OnboardingHelpItem")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.helpItemID]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.helpItemID]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard itemIdentifier == Self.helpItemID else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = NSLocalizedString("onboarding.help", comment: "Help button in onboarding toolbar")
        item.toolTip = item.label
        item.image = NSImage(systemSymbolName: "questionmark", accessibilityDescription: item.label)
        item.isBordered = true
        item.target = nil   // 预留:当前不绑动作,只触发 unified toolbar 几何
        item.action = nil
        return item
    }
}
