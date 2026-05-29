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
//    1. 单例(MainActor)。第一次 show() lazy 创建 NSWindow。
//    2. 关闭(用户点 X 或调用 close())只是 orderOut,不释放窗口——
//       重复调 show() 直接 makeKeyAndOrderFront 复用,避免每次重建
//       OnboardingView 内的 ImageRenderer / 动画 task 状态。
//    3. OnboardingView 首次出现时写 UserDefaults 版本戳 = 当前 bundle
//       版本号。下次启动 AppDelegate 决定是否再次显示。
//
//  显示判定:
//    - 用户只要看到了本版本 onboarding,即使直接点 X 关闭,也视为本版本
//      已确认,下次启动不重复出现
//    - 只有版本号前进才会再次出现
//

import AppKit
import SwiftUI

@MainActor
final class OnboardingPresenter {
    static let shared = OnboardingPresenter()

    private var window: NSWindow?
    /// 持有 toolbar delegate 防止被 ARC 释放——NSToolbar 只 weak 引用 delegate。
    private var toolbarDelegate: OnboardingToolbarDelegate?

    private init() {}

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
    /// 同版本不重复触发——一次展示永久免打扰,直到下次升级。
    static var shouldShowOnLaunch: Bool {
        guard let last = lastAcknowledgedVersion else { return true }
        let current = currentVersion
        // numeric 比较把版本号串当成数字串解析,"1.10" > "1.9"。
        return current.compare(last, options: .numeric) == .orderedDescending
    }

    /// 标记当前版本 onboarding 已经展示过。只要用户看到了本版本 onboarding,
    /// 即使随后点 X 关闭,下次启动也不应重复打扰。
    static func markPresented() {
        UserDefaults.standard.set(currentVersion, forKey: acknowledgedVersionKey)
    }

    /// 显示 onboarding 窗口(创建 / 复用)。menu-bar app 必须显式 activate
    /// 才能让窗口拿到 key 状态。
    func show() {
        if let existing = window {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let hosting = NSHostingController(
            rootView: OnboardingView(onClose: { [weak self] in
                self?.close()
            })
            .environmentObject(AppSettings.shared.hotkey)
            .environmentObject(AppSettings.shared.capture)
        )

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
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

    /// 关闭窗口。不释放——下次 show() 复用同一个 window 实例,避免
    /// 每次重建内部 SwiftUI 状态(ImageRenderer / phase 动画)。
    func close() {
        window?.orderOut(nil)
    }
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
